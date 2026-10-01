defmodule Wallboard.Collector.Watcher do
  @moduledoc """
  The collector: watches this machine's Claude Code and Codex sessions and
  puts what happens in the outbox (`Wallboard.Collector.Outbox`) for the
  link to send to the hub. It runs when the `role` setting is "collector",
  with no board, no web port and no database beside it.

  ## What it watches

  It uses no Claude Code hooks. It reads what the hub reads for its own
  sessions:

    * Claude session files, `<claude folder>/projects/*/<session>.jsonl`,
      and each session's helper agents under `<session>/subagents/`
    * Codex session files, `<codex folder>/sessions/<year>/<month>/<day>/`
    * `claude agents --json`, for each Claude session's live status
    * the small files the Codex hook keeps in `<codex folder>/vitalaize`,
      since Codex writes nothing to a session file while it waits

  Every session is reported, whatever folder or repository it works in.

  ## The folders

  The collector finds its own: `~/.claude` and every `~/.claude-something`
  that holds a `projects` folder or a `settings.json`, and `~/.codex` when
  it holds `sessions`. It looks again every few seconds, so a folder made
  later is found without a restart. `collector.claude_dirs` and
  `collector.codex_dirs` in the settings file replace the search. The hub
  is only told which folders (`hello/1`); it never sets them.

  ## Events

  New lines go through `Wallboard.Collector.Filter`, which alone decides
  what may leave, and each event carries its session, its file and the byte
  after its line. A status goes out when it changes: working, waiting (with
  the kind of wait) or idle. A session's end goes out when a Claude session
  leaves `claude agents`, when a Codex session quits or has been quiet for
  `codex.idle_minutes` (as it leaves the board's Live tab), and when a
  session's folder is no longer watched.

  A session's status can reach the outbox before its first line does: a
  Claude session shows in `claude agents` before it has a session file.

  ## Its place, and a restart

  The collector's place in each file, and the last status it sent for each
  session, are saved in the outbox with the events they belong to. After a
  restart it carries on from there and repeats nothing. A file with new
  lines is read again from its start, since the filter's totals need every
  line, and only the events past the saved place go out.

  On the very first start, sessions that changed in the last
  `collector.backfill_days` are reported from their first line. An older
  one is reported, whole, when it next changes.

  Session files only ever grow. One that got shorter, or whose first bytes
  changed, was replaced by another, so it is read as new.

  ## Staying small

  Only files that changed lately are kept in memory: a Claude file for 30
  minutes after its last line, a Codex file for `codex.idle_minutes` or
  while it has an approval request out (its live status is worked out from
  it). Events go to the outbox a couple of hundred at a time. When the
  outbox is full, or cannot be written, the collector stops reading and
  waits; the session files keep everything until then. A file with a
  single line longer than #{div(64_000_000, 1_000_000)} MB is left out.
  """

  use GenServer
  require Logger

  alias Wallboard.Archive.CodexTranscript
  alias Wallboard.Archive.Collector, as: Archive
  alias Wallboard.Collector.{Filter, Outbox, Proto}
  alias Wallboard.Sources.{Claude, Codex}

  # How much of a file is read at a time, and how many of its lines go
  # through the filter at a time. One line gives one event at most, so the
  # second number is also the most events held before they are saved.
  @chunk 1_000_000
  @lines 200
  # A line still without its end after this many bytes is not a session's.
  @line_max 64_000_000
  # How much of a Codex file is read to find its first line.
  @head_max 1_000_000
  # How often the folders are searched for files not seen before. Known
  # files that changed lately are checked every `collector.poll_seconds`.
  @search_ms 10_000
  @warm_seconds 30 * 60

  def start_link(opts) do
    # `name: nil` starts one without a name, for tests.
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Looks once, now: reads what is new in the files, then checks every
  session's status. Returns when both are in the outbox. The collector
  does this by itself on a timer; this is for tests.
  """
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, :infinity)

  @doc "The first message for the hub: this machine, and the folders watched."
  def hello(server \\ __MODULE__), do: GenServer.call(server, :hello, :infinity)

  @doc """
  The Claude and Codex folders a collector with these settings watches, as
  `%{claude: [folder], codex: [folder]}`: the ones in the settings, or the
  ones found under `home`.
  """
  def folders(settings, home \\ System.user_home!()) do
    c = settings.collector

    %{
      claude: Enum.filter(c.claude_dirs || claude_folders(home), &String.valid?/1),
      codex:
        if(settings.codex.enabled,
          do: Enum.filter(c.codex_dirs || codex_folders(home), &String.valid?/1),
          else: []
        )
    }
  end

  defp claude_folders(home) do
    names =
      case File.ls(home) do
        {:ok, names} -> names
        _ -> []
      end

    names
    |> Enum.filter(&(&1 == ".claude" or String.starts_with?(&1, ".claude-")))
    |> Enum.map(&Path.join(home, &1))
    |> Enum.filter(
      &(File.dir?(Path.join(&1, "projects")) or File.regular?(Path.join(&1, "settings.json")))
    )
    |> Enum.sort_by(&{Path.basename(&1) != ".claude", &1})
  end

  defp codex_folders(home) do
    dir = Path.join(home, ".codex")
    if File.dir?(Path.join(dir, "sessions")), do: [dir], else: []
  end

  # ---------------------------------------------------------------------------
  # Server

  @impl true
  def init(opts) do
    state = %{
      outbox: Keyword.get(opts, :outbox, Outbox),
      settings: Keyword.get(opts, :settings, &Wallboard.Settings.get/0),
      now: Keyword.get(opts, :now, fn -> DateTime.utc_now() |> DateTime.truncate(:second) end),
      claude: Keyword.get(opts, :claude, &claude_sessions/1),
      home: Keyword.get(opts, :home) || System.user_home!(),
      timer?: Keyword.get(opts, :timer, true),
      folders: %{claude: [], codex: []},
      # path => %{tool, dir, size, mtime}, for every session file in view
      seen: %{},
      # path => the byte after the last line whose events are saved or
      # waiting in `pending`
      offsets: %{},
      # path => [length, hash] of the file's first bytes, to tell a file
      # that was replaced by another
      heads: %{},
      # {tool, session id} => %{dir, state, why, tool}, the last status sent
      statuses: %{},
      # Events not in the outbox yet, newest first, and whether the place
      # above has changed since it was last saved.
      pending: [],
      unsaved?: false,
      # path => %{filter, fed}, the files kept in memory
      open: %{},
      # path => its size when it was last put away, or found not ready
      rested: %{},
      unready: %{},
      skip: MapSet.new(),
      titles: {nil, %{}},
      # The Codex hook's notes, and the sessions with an approval request out.
      notes: %{},
      notes_read: %{},
      asking: MapSet.new(),
      searched_at: nil,
      status_at: nil,
      # Whether the last look stopped early, and whether it read every file.
      full?: false,
      read?: false,
      # False until the saved place has been read from the outbox.
      placed?: false,
      task: nil,
      callers: []
    }

    state = place(state)
    found = folders(state.settings.(), state.home)

    Logger.info(
      "Collector is up. Watching " <>
        case found.claude ++ found.codex do
          [] -> "no Claude or Codex folder yet."
          dirs -> Enum.join(dirs, ", ")
        end
    )

    if state.timer?, do: send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:tick, from, state) do
    state = state |> read_files() |> start_status()
    {:noreply, %{state | callers: [from | state.callers]}}
  end

  def handle_call(:hello, _from, state) do
    settings = state.settings.()
    found = folders(settings, state.home)

    hello =
      Filter.hello(%{
        machine: Archive.machine(settings),
        os: os(),
        version: to_string(Application.spec(:wallboard, :vsn)),
        folders: found.claude ++ found.codex
      })

    {:reply, hello, state}
  end

  @impl true
  def handle_info(:tick, state) do
    settings = state.settings.()
    state = read_files(state)
    mono = System.monotonic_time(:millisecond)

    state =
      if state.status_at == nil or mono - state.status_at >= settings.claude.poll_seconds * 1000,
        do: start_status(%{state | status_at: mono}),
        else: state

    Process.send_after(self(), :tick, settings.collector.poll_seconds * 1000)
    # Gives back the memory a round used, so an idle collector stays small.
    {:noreply, state, :hibernate}
  end

  def handle_info({ref, results}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> statuses(results) |> done()}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, done(state)}

  def handle_info(_other, state), do: {:noreply, state}

  # Never print session data in a crash report: not the state, and not the
  # message being handled, which can hold sessions too.
  @impl true
  def format_status(status) do
    status
    |> Map.update(:state, nil, &Map.take(&1, [:folders]))
    |> Map.replace(:message, :not_shown)
    |> Map.replace(:log, [])
  end

  defp done(state) do
    for from <- state.callers, do: GenServer.reply(from, :ok)
    %{state | task: nil, callers: []}
  end

  defp os do
    name =
      case :os.type() do
        {:unix, :darwin} -> "macOS"
        {:unix, :linux} -> "Linux"
        {_, other} -> to_string(other)
      end

    arch = :system_architecture |> :erlang.system_info() |> to_string() |> String.split("-")
    name <> " " <> hd(arch)
  end

  # ---------------------------------------------------------------------------
  # The saved place

  # The collector's place, as the text the outbox saves with the events:
  # each file's byte offset and first bytes, and the last status sent for
  # each session.
  defp checkpoint(state) do
    statuses =
      for {{tool, id}, s} <- Enum.sort(state.statuses),
          do: [Atom.to_string(tool), id, s.dir, Atom.to_string(s.state), s.why, s.tool]

    Jason.encode!(%{
      "offsets" => state.offsets,
      "heads" => state.heads,
      "statuses" => statuses
    })
  end

  @tools %{"claude" => :claude, "codex" => :codex}
  @states %{"needs" => :needs, "working" => :working, "idle" => :idle}
  @whys ~w(WHY_UNKNOWN PERMISSION QUESTION DIALOG NETWORK HELPER GOAL OTHER)

  # Reads a saved place back. Anything not shaped as `checkpoint/1` writes
  # it is left out, so a damaged file costs a repeat, never a crash.
  defp restore(text) do
    empty = %{offsets: %{}, heads: %{}, statuses: %{}}

    with true <- is_binary(text),
         {:ok, %{"offsets" => %{} = offsets, "statuses" => statuses} = saved}
         when is_list(statuses) <- Jason.decode(text) do
      heads = if is_map(saved["heads"]), do: saved["heads"], else: %{}

      heads =
        for {path, [n, hash]} <- heads,
            is_integer(n) and n > 0 and is_binary(hash),
            into: %{},
            do: {path, [n, hash]}

      statuses =
        for [tool, id, dir, state, why, name] <- statuses,
            is_map_key(@tools, tool) and is_map_key(@states, state) and is_binary(id),
            is_nil(dir) or is_binary(dir),
            why in @whys and is_binary(name) and byte_size(name) <= 200,
            into: %{} do
          {{@tools[tool], id}, %{dir: dir, state: @states[state], why: why, tool: name}}
        end

      %{
        offsets: for({path, n} <- offsets, is_integer(n) and n >= 0, into: %{}, do: {path, n}),
        heads: heads,
        statuses: statuses
      }
    else
      _ -> empty
    end
  end

  # Puts the waiting events in the outbox and saves the place with them.
  defp flush(%{pending: [], unsaved?: false} = state), do: state

  defp flush(state) do
    case append(state) do
      {:error, reason} ->
        Logger.warning(
          "Collector: could not write to its outbox (#{inspect(reason)}). It will try again."
        )

        # Back to the last place that was saved: what was read since is
        # read again once the outbox can be written.
        state
        |> Map.merge(%{
          pending: [],
          unsaved?: false,
          open: %{},
          rested: %{},
          full?: true,
          read?: false
        })
        |> place()

      _seq ->
        state = %{state | pending: [], unsaved?: false}
        if room?(state), do: state, else: %{state | full?: true}
    end
  end

  # Takes the saved place from the outbox. While the outbox cannot read its
  # files there is no place to take, and the collector does nothing: to
  # start from nothing instead would send everything a second time.
  defp place(state) do
    case saved_place(state) do
      {:error, _} ->
        %{state | offsets: %{}, heads: %{}, statuses: %{}, placed?: false}

      text ->
        state |> Map.merge(restore(text)) |> Map.put(:placed?, true)
    end
  end

  defp saved_place(state) do
    Outbox.checkpoint(state.outbox)
  catch
    :exit, _ -> {:error, :outbox_stopped}
  end

  defp room?(state) do
    Outbox.room?(state.outbox)
  catch
    :exit, _ -> false
  end

  # An outbox that stopped mid-append is one that could not write. The exit
  # is caught here because its reason holds the append, events and all, and
  # would be printed if it took the watcher down too.
  defp append(state) do
    Outbox.append(state.outbox, Enum.reverse(state.pending), checkpoint(state))
  catch
    :exit, _ -> {:error, :outbox_stopped}
  end

  # ---------------------------------------------------------------------------
  # Session files

  defp read_files(%{placed?: false} = state) do
    case place(state) do
      %{placed?: true} = state -> read_files(state)
      state -> %{state | full?: true, read?: false}
    end
  end

  defp read_files(state) do
    settings = state.settings.()
    now = state.now.()
    now_s = DateTime.to_unix(now)

    state =
      %{look(state, settings, now_s) | full?: false, read?: false}
      |> notes(settings, now)

    state =
      if room?(state) do
        state =
          state.seen
          |> Map.keys()
          |> Enum.sort()
          |> Enum.reduce_while(state, fn path, s ->
            s = if due?(s, path, settings, now_s), do: follow(s, path, settings), else: s
            # A file cut off halfway stays in memory, to carry on from there.
            if s.full?, do: {:halt, s}, else: {:cont, put_away(s, path, settings, now_s)}
          end)

        state = flush(state)
        %{state | read?: not state.full?}
      else
        state
      end

    state
  end

  # Finds the session files. A full search every few seconds; in between,
  # only the files that changed lately are looked at again.
  defp look(state, settings, now) do
    mono = System.monotonic_time(:millisecond)

    if state.timer? and state.searched_at != nil and mono - state.searched_at < @search_ms do
      seen =
        Map.new(state.seen, fn {path, info} ->
          if Map.has_key?(state.open, path) or now - info.mtime < @warm_seconds,
            do: {path, restat(path, info)},
            else: {path, info}
        end)

      %{state | seen: seen}
    else
      search(%{state | searched_at: mono}, settings, now)
    end
  end

  defp restat(path, info) do
    case File.stat(path, time: :posix) do
      {:ok, %{size: size, mtime: mtime}} -> %{info | size: size, mtime: mtime}
      _ -> info
    end
  end

  defp search(state, settings, now) do
    found = folders(settings, state.home)
    cutoff = now - settings.collector.backfill_days * 86_400

    paths =
      for(
        dir <- found.claude,
        pattern <- ["*.jsonl", "*/subagents/*.jsonl"],
        path <- Path.wildcard(Path.join([dir, "projects", "*", pattern])),
        do: {path, :claude, dir}
      ) ++
        for dir <- found.codex,
            path <- Path.wildcard(Path.join([dir, "sessions", "*", "*", "*", "rollout-*.jsonl"])),
            do: {path, :codex, dir}

    seen =
      for {path, tool, dir} <- paths,
          String.valid?(path),
          {:ok, %{type: :regular, size: size, mtime: mtime}} <- [File.stat(path, time: :posix)],
          Map.has_key?(state.offsets, path) or mtime >= cutoff,
          into: %{},
          do: {path, %{tool: tool, dir: dir, size: size, mtime: mtime}}

    # A file that is gone is forgotten. One only out of view (its folder is
    # no longer watched) keeps its place.
    gone =
      for {path, _} <- state.offsets,
          not Map.has_key?(seen, path),
          not File.exists?(path),
          do: path

    paths = Map.keys(seen)

    %{
      state
      | folders: found,
        seen: seen,
        offsets: Map.drop(state.offsets, gone),
        heads: Map.drop(state.heads, gone),
        unsaved?: state.unsaved? or gone != [],
        open: Map.take(state.open, paths),
        rested: Map.take(state.rested, paths),
        unready: Map.take(state.unready, paths),
        skip: MapSet.intersection(state.skip, MapSet.new(paths)),
        titles: Codex.titles(%{codex: %{dirs: found.codex}}, state.titles)
    }
  end

  # The Codex hook's notes, read before the files: a session with an
  # approval request out keeps its file in memory however quiet it is.
  defp notes(%{folders: %{codex: []}} = state, _settings, _now),
    do: %{state | notes: %{}, asking: MapSet.new()}

  defp notes(state, settings, now) do
    codex = %{codex: %{settings.codex | dirs: state.folders.codex}}
    Codex.install_hook(codex)
    {notes, read} = Codex.marks(codex, now, state.notes_read)
    %{state | notes: notes, notes_read: read, asking: Codex.asking(notes)}
  rescue
    _ -> state
  end

  defp due?(state, path, settings, now) do
    info = state.seen[path]

    cond do
      MapSet.member?(state.skip, path) -> false
      state.unready[path] == info.size -> false
      entry = state.open[path] -> info.size != entry.fed
      # A Codex session's status comes from its file, so one that can show
      # on the hub is read into memory even with nothing new in it.
      info.tool == :codex and keep?(state, path, info, settings, now) -> true
      Map.has_key?(state.rested, path) -> info.size != state.rested[path]
      true -> info.size != Map.get(state.offsets, path, 0)
    end
  end

  # Whether a file stays in memory once read. A Codex file does for as long
  # as its session can show on the hub.
  defp keep?(state, path, %{tool: :codex, mtime: mtime}, settings, now) do
    now - mtime < settings.codex.idle_minutes * 60 or
      MapSet.member?(state.asking, CodexTranscript.id_from_path(path))
  end

  defp keep?(_state, _path, %{mtime: mtime}, _settings, now), do: now - mtime < @warm_seconds

  defp put_away(state, path, settings, now) do
    with %{fed: fed} <- state.open[path],
         false <- keep?(state, path, state.seen[path], settings, now) do
      %{state | open: Map.delete(state.open, path), rested: Map.put(state.rested, path, fed)}
    else
      _ -> state
    end
  end

  # Reads what is new in one file and queues its events for the outbox.
  defp follow(state, path, settings) do
    info = state.seen[path]
    entry = state.open[path]
    head = head(path, state.heads[path])

    replaced? =
      head == :changed or info.size < Map.get(state.offsets, path, 0) or
        (entry != nil and info.size < entry.fed)

    {state, entry, head} =
      if replaced? do
        Logger.info("Collector: a session file was replaced by another, so it is read as new.")

        state = %{
          state
          | offsets: Map.delete(state.offsets, path),
            heads: Map.delete(state.heads, path),
            open: Map.delete(state.open, path),
            unsaved?: true
        }

        {state, nil, head(path, nil)}
      else
        {state, entry, head}
      end

    state =
      case head do
        {:new, mark} -> %{state | heads: Map.put(state.heads, path, mark), unsaved?: true}
        _ -> state
      end

    case entry || open(state, path, info, settings) do
      # Not a session file yet (a Codex file with no first line). Looked at
      # again once it has grown.
      nil ->
        %{state | unready: Map.put(state.unready, path, info.size)}

      :skip ->
        %{state | skip: MapSet.put(state.skip, path)}

      entry ->
        state = %{state | open: Map.put(state.open, path, entry)}
        pump(state, path, info.size)
    end
  end

  # Compares a file's first bytes with the ones noted when it was first
  # read: :same, :changed, {:new, note} when there was no note, or :none.
  defp head(path, saved) do
    want =
      case saved do
        [n, _] -> n
        _ -> 256
      end

    with {:ok, io} <- :file.open(path, [:read, :binary, :raw]),
         read = :file.read(io, want),
         :ok <- :file.close(io),
         {:ok, data} <- read do
      hash = :sha256 |> :crypto.hash(data) |> Base.encode16() |> binary_part(0, 16)

      case saved do
        [n, ^hash] when n == byte_size(data) -> :same
        [_, _] -> :changed
        _ -> {:new, [byte_size(data), hash]}
      end
    else
      _ -> if saved, do: :changed, else: :none
    end
  end

  defp open(state, path, info, settings) do
    case context(state, path, info) do
      %{} = ctx ->
        ctx = Map.put(ctx, :prices, settings.usage.prices)
        %{filter: Filter.new(ctx), fed: 0}

      other ->
        other
    end
  rescue
    # A name that could not be sent as the hub's key for the file.
    ArgumentError -> :skip
  end

  defp context(_state, path, %{tool: :claude, dir: dir}) do
    base = %{tool: :claude, account: Claude.account_label(dir)}

    case path |> Path.relative_to(Path.join(dir, "projects")) |> Path.split() do
      [_project, name] ->
        Map.merge(base, %{session_id: Path.basename(name, ".jsonl"), file: name})

      [_project, id, "subagents", name] ->
        Map.merge(base, %{
          session_id: id,
          file: Path.join([id, "subagents", name]),
          subagent: true
        })

      _ ->
        :skip
    end
  end

  defp context(state, path, %{tool: :codex, dir: dir}) do
    case codex_head(path) do
      {id, parent, _nickname} when is_binary(id) and (is_nil(parent) or is_binary(parent)) ->
        %{
          tool: :codex,
          session_id: parent || id,
          file: Path.relative_to(path, Path.join(dir, "sessions")),
          subagent: parent != nil,
          account: Archive.codex_account(dir),
          title: if(parent, do: nil, else: elem(state.titles, 1)[id])
        }

      _ ->
        nil
    end
  end

  # A Codex file's first line, when it is whole and of a sane length.
  defp codex_head(path) do
    with {:ok, io} <- :file.open(path, [:read, :binary, :raw]),
         read = :file.read(io, @head_max),
         :ok <- :file.close(io),
         {:ok, data} <- read,
         true <- String.contains?(data, "\n") do
      CodexTranscript.head_of(data)
    else
      _ -> nil
    end
  end

  defp pump(state, path, size) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          chunks(state, path, size, io)
        after
          :file.close(io)
        end

      _ ->
        state
    end
  end

  defp chunks(state, path, size, io) do
    with %{fed: fed} when fed < size <- state.open[path],
         want = min(@chunk, size - fed),
         {:ok, data} <- :file.pread(io, fed, want) do
      state = data |> pieces() |> Enum.reduce_while(state, &piece(&1, &2, path))

      if state.full? or not Map.has_key?(state.open, path) or byte_size(data) < want,
        do: state,
        else: chunks(state, path, size, io)
    else
      _ -> state
    end
  end

  # A read cut into runs of whole lines, a couple of hundred at a time, and
  # what is left of a last line with no end yet.
  defp pieces(data) do
    {lines, [rest]} = data |> :binary.split("\n", [:global]) |> Enum.split(-1)

    lines
    |> Enum.chunk_every(@lines)
    |> Enum.map(&(Enum.join(&1, "\n") <> "\n"))
    |> Kernel.++(if rest == "", do: [], else: [rest])
  end

  defp piece(data, state, path) do
    entry = state.open[path]
    {events, filter} = Filter.read(entry.filter, data)
    entry = %{filter: filter, fed: entry.fed + byte_size(data)}
    saved = Map.get(state.offsets, path, 0)
    position = Filter.position(filter)
    # Reading a known file again from its start gives its old events too.
    # Those are in the outbox, or already at the hub.
    new = Enum.filter(events, &(&1.position > saved))
    state = %{state | open: Map.put(state.open, path, entry)}

    state =
      if position > saved do
        %{
          state
          | offsets: Map.put(state.offsets, path, position),
            pending: Enum.reverse(new) ++ state.pending,
            unsaved?: true
        }
      else
        state
      end

    cond do
      entry.fed - position > @line_max ->
        Logger.warning("Collector: a session file has a line too long to read. It is left out.")

        {:halt, %{state | open: Map.delete(state.open, path), skip: MapSet.put(state.skip, path)}}

      length(state.pending) >= @lines ->
        state = flush(state)
        if state.full?, do: {:halt, state}, else: {:cont, state}

      true ->
        {:cont, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Live status

  # Only what the status needs: a session's task and the words of what it
  # waits on stay out of the collector's memory.
  defp claude_sessions(dir) do
    case Claude.fetch(%{claude: %{config_dirs: [dir]}}) do
      {:ok, sessions, _problems} ->
        keys = [:session_id, :status, :waiting_for, :waiting_since, :updated_at]
        {:ok, Enum.map(sessions, &Map.take(&1, keys))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `claude agents` can take seconds, so it runs beside the collector and
  # the files are still read meanwhile.
  defp start_status(%{task: nil} = state) do
    dirs = state.folders.claude
    fetch = state.claude

    task =
      Task.Supervisor.async_nolink(Wallboard.TaskSupervisor, fn ->
        Enum.map(dirs, &{&1, fetch.(&1)})
      end)

    %{state | task: task}
  end

  defp start_status(state), do: state

  defp statuses(%{placed?: false} = state, _claude), do: state

  defp statuses(state, claude) do
    # A full outbox waits. The statuses then are sent when there is room.
    if room?(state) do
      settings = state.settings.()
      now = state.now.()

      {live, gone} =
        (claude_statuses(claude, state) ++ codex_statuses(state, settings, now))
        |> Enum.split_with(&match?({:live, _, _, _}, &1))

      # One session listed twice counts once, as it was listed first.
      {events, statuses} =
        live
        |> Enum.uniq_by(fn {:live, key, _, _} -> key end)
        |> Kernel.++(gone)
        |> Enum.reduce({[], state.statuses}, fn
          {:live, key, raw, since}, {events, statuses} ->
            old = statuses[key]

            with %Proto.Event{} = event <-
                   status_event(key, raw, since(old, raw, since, now), now),
                 new = sent(raw, event) do
              # The same status under another folder is not news, but the
              # folder is noted: the session ends when that one drops it.
              if old != nil and Map.delete(old, :dir) == Map.delete(new, :dir),
                do: {events, Map.put(statuses, key, new)},
                else: {[event | events], Map.put(statuses, key, new)}
            else
              _ -> {events, statuses}
            end

          {:gone, gone?}, {events, statuses} ->
            keys = for {key, old} <- Enum.sort(statuses), gone?.(key, old), do: key
            ended = for key <- keys, event = ended_event(key, now), do: event
            {Enum.reverse(ended) ++ events, Map.drop(statuses, keys)}
        end)

      flush(%{
        state
        | statuses: statuses,
          pending: events ++ state.pending,
          unsaved?: state.unsaved? or statuses != state.statuses
      })
    else
      state
    end
  end

  # What is remembered of a status: only what went into its event, so the
  # kind of wait is one of the filter's words and the tool's name has the
  # filter's shape.
  defp sent(raw, %Proto.Event{items: [%Proto.Item{body: {:status, status}}]}) do
    %{dir: raw.dir, state: raw.state, why: Atom.to_string(status.why), tool: status.tool}
  end

  # When the status began: the files' own time when they have one,
  # otherwise now. A session first seen at work began before it was seen.
  defp since(_old, %{state: :needs}, since, now), do: since || now
  defp since(nil, %{state: :working}, since, now), do: since || now
  defp since(_old, _raw, _since, now), do: now

  defp status_event({_tool, id}, raw, since, now) do
    Filter.status(%{session_id: id}, raw.state,
      why: raw.why,
      tool: raw.tool,
      since: since,
      at: now
    )
  rescue
    _ -> nil
  end

  defp ended_event({_tool, id}, now) do
    Filter.ended(%{session_id: id}, now)
  rescue
    _ -> nil
  end

  # For each folder `claude agents` answered for: its live sessions, then
  # the end of every session of that folder it no longer lists. A folder it
  # could not answer for is left as it was. Sessions of a folder that is no
  # longer watched have ended.
  defp claude_statuses(results, state) do
    watched = state.folders.claude

    unwatched =
      {:gone, fn key, old -> match?({:claude, _}, key) and old.dir not in watched end}

    [unwatched] ++
      Enum.flat_map(results, fn
        {dir, {:ok, sessions}} ->
          live =
            for s <- sessions, is_binary(s.session_id), s.status in [:needs, :working, :idle] do
              raw = %{
                dir: dir,
                state: s.status,
                # A background session can be blocked with no kind given.
                why: if(s.status == :needs, do: s[:waiting_for] || "other"),
                tool: nil
              }

              since = if s.status == :needs, do: s[:waiting_since], else: s[:updated_at]
              {:live, {:claude, s.session_id}, raw, since}
            end

          ids = MapSet.new(live, fn {:live, key, _, _} -> key end)

          live ++
            [
              {:gone,
               fn key, old ->
                 match?({:claude, _}, key) and old.dir == dir and not MapSet.member?(ids, key)
               end}
            ]

        _ ->
          []
      end)
  end

  # Codex has no list of what runs, so its sessions' statuses come from
  # their files and the hook's notes, as on the board.
  defp codex_statuses(%{folders: %{codex: []}}, _settings, _now),
    do: [{:gone, fn key, _old -> match?({:codex, _}, key) end}]

  # The last look did not get through the files (the outbox was full), so
  # which sessions are live is not known. Nothing is said until it is.
  defp codex_statuses(%{read?: false}, _settings, _now), do: []

  defp codex_statuses(state, settings, now) do
    files =
      for {path, %{filter: filter}} <- state.open,
          %{tool: :codex, mtime: mtime} <- [state.seen[path]],
          do: {path, %{tally: Filter.tally(filter), mtime: mtime}}

    {helpers, sessions} = Enum.split_with(files, fn {_, f} -> f.tally[:parent_id] != nil end)
    cutoff = DateTime.add(now, -settings.codex.idle_minutes * 60)

    live =
      for session <- sessions,
          card <- cards([session | own(helpers, session)], now, state.notes),
          card.status == :needs or DateTime.compare(card.updated_at, cutoff) != :lt,
          not quit?(state.notes[card.session_id]) do
        # The kind of wait, in the words `claude agents` uses for it.
        why =
          case card.waiting_kind do
            :permission -> "permission prompt"
            :question -> "input needed"
            nil -> nil
          end

        raw = %{dir: nil, state: card.status, why: why, tool: card.waiting_tool}
        {:live, {:codex, card.session_id}, raw, card.since}
      end

    ids = MapSet.new(live, fn {:live, key, _, _} -> key end)

    live ++
      [{:gone, fn key, _old -> match?({:codex, _}, key) and not MapSet.member?(ids, key) end}]
  end

  defp own(helpers, {_path, %{tally: tally}}),
    do: Enum.filter(helpers, fn {_, f} -> f.tally[:parent_id] == tally[:thread_id] end)

  # One session's card. A file with a line the board's code cannot take
  # costs that session its status, not every session theirs.
  defp cards(files, now, notes) do
    Codex.sessions(Map.new(files), %{}, now, notes)
  rescue
    _ -> []
  end

  # The hook keeps a session's latest call, so a quit that still stands
  # means nothing has happened in the session since.
  defp quit?(notes) do
    Enum.any?(List.wrap(notes), fn note ->
      note["hook_event_name"] == "SessionEnd" and note["agent_id"] in [nil, ""]
    end)
  end
end
