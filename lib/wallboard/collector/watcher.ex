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
  leaves `claude agents`, and when a Codex session quits or has been quiet
  for `codex.idle_minutes`, as it leaves the board's Live tab.

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

  ## Staying small

  Only files that changed lately are kept in memory: a Claude file for 30
  minutes after its last line, a Codex file for `codex.idle_minutes` (its
  live status is worked out from it). When the outbox is full the collector
  stops reading and waits; the session files keep everything until then.

  A session file that got shorter was replaced, so it is read as new.
  """

  use GenServer
  require Logger

  alias Wallboard.Archive.CodexTranscript
  alias Wallboard.Archive.Collector, as: Archive
  alias Wallboard.Collector.{Filter, Outbox}
  alias Wallboard.Sources.{Claude, Codex}

  # How much of a file is read at a time.
  @chunk 1_000_000
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
  def hello(server \\ __MODULE__), do: GenServer.call(server, :hello, 60_000)

  @doc """
  The Claude and Codex folders a collector with these settings watches, as
  `%{claude: [folder], codex: [folder]}`: the ones in the settings, or the
  ones found under `home`.
  """
  def folders(settings, home \\ System.user_home!()) do
    c = settings.collector

    %{
      claude: c.claude_dirs || claude_folders(home),
      codex: if(settings.codex.enabled, do: c.codex_dirs || codex_folders(home), else: [])
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
      # path => the byte after the last line whose events are in the outbox
      offsets: %{},
      # {tool, session id} => %{dir, state, why, tool}, the last status sent
      statuses: %{},
      # path => %{filter, fed}, the files kept in memory
      open: %{},
      # path => its size when it was last put away
      rested: %{},
      skip: MapSet.new(),
      titles: {nil, %{}},
      marks: %{},
      asking: MapSet.new(),
      searched_at: nil,
      status_at: nil,
      full?: false,
      task: nil,
      callers: []
    }

    state = Map.merge(state, restore(Outbox.checkpoint(state.outbox)))
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

    Process.send_after(self(), :tick, max(settings.collector.poll_seconds, 1) * 1000)
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

  # Never print session data in a crash report.
  @impl true
  def format_status(status), do: Map.update(status, :state, nil, &Map.take(&1, [:folders]))

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
  # Session files

  defp read_files(state) do
    settings = state.settings.()
    now = DateTime.to_unix(state.now.())
    places = map_size(state.offsets)
    state = %{look(state, settings, now) | full?: false}
    forgot? = map_size(state.offsets) != places

    state =
      if Outbox.room?(state.outbox) do
        state.seen
        |> Map.keys()
        |> Enum.sort()
        |> Enum.reduce_while(state, fn path, s ->
          s = if due?(s, path, settings, now), do: follow(s, path, settings), else: s
          s = put_away(s, path, settings, now)
          if s.full?, do: {:halt, s}, else: {:cont, s}
        end)
      else
        state
      end

    # Saves what changed without an event: the place of a file that is gone.
    if forgot?, do: Outbox.append(state.outbox, [], checkpoint(state))
    state
  end

  # The collector's place, as the text the outbox saves with the events:
  # each file's byte offset and the last status sent for each session.
  defp checkpoint(state) do
    statuses =
      for {{tool, id}, s} <- Enum.sort(state.statuses),
          do: [Atom.to_string(tool), id, s.dir, Atom.to_string(s.state), s.why, s.tool]

    Jason.encode!(%{"offsets" => state.offsets, "statuses" => statuses})
  end

  @tools %{"claude" => :claude, "codex" => :codex}
  @states %{"needs" => :needs, "working" => :working, "idle" => :idle}

  # Reads a saved place back. Anything not shaped as `checkpoint/1` writes
  # it is left out, so a damaged file costs a repeat, never a crash.
  defp restore(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{"offsets" => %{} = offsets, "statuses" => statuses}} when is_list(statuses) ->
        %{
          offsets: for({path, n} <- offsets, is_integer(n) and n >= 0, into: %{}, do: {path, n}),
          statuses:
            for [tool, id, dir, state, why, name] <- statuses,
                is_map_key(@tools, tool) and is_map_key(@states, state) and is_binary(id),
                is_nil(dir) or is_binary(dir),
                is_nil(why) or is_binary(why),
                is_nil(name) or is_binary(name),
                into: %{} do
              {{@tools[tool], id}, %{dir: dir, state: @states[state], why: why, tool: name}}
            end
        }

      _ ->
        %{}
    end
  end

  defp restore(_), do: %{}

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

    %{
      state
      | folders: found,
        seen: seen,
        offsets: Map.drop(state.offsets, gone),
        open: Map.take(state.open, Map.keys(seen)),
        rested: Map.take(state.rested, Map.keys(seen)),
        titles: titles(found.codex, state.titles)
    }
  end

  # Codex's own names for its threads. Read again only when a file changed.
  defp titles(dirs, {stamp, titles}) do
    now_stamp =
      Enum.map(dirs, fn dir ->
        case File.stat(Path.join(dir, "session_index.jsonl"), time: :posix) do
          {:ok, s} -> {dir, s.size, s.mtime}
          _ -> dir
        end
      end)

    if now_stamp == stamp,
      do: {stamp, titles},
      else: {now_stamp, Archive.codex_titles(%{codex: %{dirs: dirs}})}
  end

  defp due?(state, path, settings, now) do
    info = state.seen[path]

    cond do
      MapSet.member?(state.skip, path) -> false
      entry = state.open[path] -> info.size != entry.fed
      Map.has_key?(state.rested, path) -> info.size != state.rested[path]
      info.size != Map.get(state.offsets, path, 0) -> true
      true -> keep?(state, path, info, settings, now)
    end
  end

  # Whether a file stays in memory once read. A Codex file does for as long
  # as its session can show on the hub, since its status comes from it.
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

  # Reads what is new in one file and puts its events in the outbox.
  defp follow(state, path, settings) do
    info = state.seen[path]
    entry = state.open[path]

    shorter? =
      info.size < Map.get(state.offsets, path, 0) or (entry != nil and info.size < entry.fed)

    {state, entry} =
      if shorter? do
        Logger.info("Collector: a session file got shorter, so it is read as new.")
        {%{state | offsets: Map.delete(state.offsets, path)}, nil}
      else
        {state, entry}
      end

    case entry || open(state, path, info, settings) do
      # Not a session file yet (a Codex file with no first line).
      nil -> state
      :skip -> %{state | skip: MapSet.put(state.skip, path)}
      entry -> pump(state, path, entry, info.size)
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
    case CodexTranscript.head(path) do
      {id, parent, _nickname} when is_binary(id) ->
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

  defp pump(state, path, entry, size) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          chunks(state, path, entry, size, io)
        after
          :file.close(io)
        end

      _ ->
        state
    end
  end

  defp chunks(state, path, %{fed: fed} = entry, size, _io) when fed >= size,
    do: %{state | open: Map.put(state.open, path, entry)}

  defp chunks(state, path, entry, size, io) do
    want = min(@chunk, size - entry.fed)

    case :file.pread(io, entry.fed, want) do
      {:ok, data} ->
        {events, filter} = Filter.read(entry.filter, data)
        entry = %{filter: filter, fed: entry.fed + byte_size(data)}
        saved = Map.get(state.offsets, path, 0)
        # Reading a known file again from its start gives its old events
        # too. Those are in the outbox, or already at the hub.
        new = Enum.filter(events, &(&1.position > saved))
        state = %{state | open: Map.put(state.open, path, entry)}

        state =
          if Filter.position(filter) > saved do
            state = %{state | offsets: Map.put(state.offsets, path, Filter.position(filter))}
            Outbox.append(state.outbox, new, checkpoint(state))
            state
          else
            state
          end

        cond do
          byte_size(data) < want -> state
          new != [] and not Outbox.room?(state.outbox) -> %{state | full?: true}
          true -> chunks(state, path, entry, size, io)
        end

      _ ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Live status

  defp claude_sessions(dir) do
    case Claude.fetch(%{claude: %{config_dirs: [dir]}}) do
      {:ok, sessions, _problems} -> {:ok, sessions}
      {:error, reason} -> {:error, reason}
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

  defp statuses(state, claude) do
    # A full outbox waits. The statuses then are sent when there is room.
    if Outbox.room?(state.outbox) do
      settings = state.settings.()
      now = state.now.()
      {codex, state} = codex_statuses(state, settings, now)

      {events, statuses} =
        Enum.reduce(claude_statuses(claude, now) ++ codex, {[], state.statuses}, fn
          {:live, key, new, since}, {events, statuses} ->
            old = statuses[key]

            with false <- old != nil and same?(old, new),
                 %{} = event <- status_event(key, new, since(old, new, since, now), now) do
              {[event | events], Map.put(statuses, key, new)}
            else
              _ -> {events, statuses}
            end

          {:gone, gone?}, {events, statuses} ->
            keys = for {key, old} <- Enum.sort(statuses), gone?.(key, old), do: key
            ended = for key <- keys, event = ended_event(key, now), do: event
            {Enum.reverse(ended) ++ events, Map.drop(statuses, keys)}
        end)

      state = %{state | statuses: statuses}
      Outbox.append(state.outbox, Enum.reverse(events), checkpoint(state))
      state
    else
      state
    end
  end

  defp same?(old, new),
    do: Map.take(old, [:state, :why, :tool]) == Map.take(new, [:state, :why, :tool])

  # When the status began: the files' own time when they have one,
  # otherwise now. A session first seen at work began before it was seen.
  defp since(_old, %{state: :needs}, since, now), do: since || now
  defp since(nil, %{state: :working}, since, now), do: since || now
  defp since(_old, _new, _since, now), do: now

  defp status_event({_tool, id}, new, since, now) do
    Filter.status(%{session_id: id}, new.state,
      why: new.why,
      tool: new.tool,
      since: since,
      at: now
    )
  rescue
    ArgumentError -> nil
  end

  defp ended_event({_tool, id}, now) do
    Filter.ended(%{session_id: id}, now)
  rescue
    ArgumentError -> nil
  end

  # For each folder `claude agents` answered for: its live sessions, then
  # the end of every session of that folder it no longer lists. A folder it
  # could not answer for is left as it was.
  defp claude_statuses(results, _now) do
    Enum.flat_map(results, fn
      {dir, {:ok, sessions}} ->
        live =
          for s <- sessions, is_binary(s.session_id) do
            new = %{
              dir: dir,
              state: s.status,
              # A background session can be blocked with no kind given.
              why: if(s.status == :needs, do: s[:waiting_for] || "other"),
              tool: nil
            }

            since = if s.status == :needs, do: s.waiting_since, else: s.updated_at
            {:live, {:claude, s.session_id}, new, since}
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
  defp codex_statuses(%{folders: %{codex: []}} = state, _settings, _now), do: {[], state}

  defp codex_statuses(state, settings, now) do
    codex = %{codex: %{settings.codex | dirs: state.folders.codex}}
    Codex.install_hook(codex)
    {marks, read} = Codex.marks(codex, now, state.marks)

    files =
      for {path, %{filter: filter}} <- state.open,
          %{tool: :codex, mtime: mtime} <- [state.seen[path]],
          into: %{},
          do: {path, %{tally: Filter.tally(filter), mtime: mtime}}

    cutoff = DateTime.add(now, -settings.codex.idle_minutes * 60)

    live =
      for card <- Codex.sessions(files, %{}, now, marks),
          card.status == :needs or DateTime.compare(card.updated_at, cutoff) != :lt,
          not quit?(marks[card.session_id]) do
        # The kind of wait, in the words `claude agents` uses for it.
        why =
          case card.waiting_kind do
            :permission -> "permission prompt"
            :question -> "input needed"
            nil -> nil
          end

        new = %{dir: nil, state: card.status, why: why, tool: card.waiting_tool}
        {:live, {:codex, card.session_id}, new, card.since}
      end

    ids = MapSet.new(live, fn {:live, key, _, _} -> key end)
    gone = {:gone, fn key, _old -> match?({:codex, _}, key) and not MapSet.member?(ids, key) end}
    {live ++ [gone], %{state | marks: read, asking: Codex.asking(marks)}}
  rescue
    e ->
      Logger.warning("Collector: could not read Codex's status: " <> Exception.message(e))
      {[], state}
  end

  # The hook keeps a session's latest call, so a quit that still stands
  # means nothing has happened in the session since.
  defp quit?(marks) do
    Enum.any?(List.wrap(marks), fn mark ->
      mark["hook_event_name"] == "SessionEnd" and mark["agent_id"] in [nil, ""]
    end)
  end
end
