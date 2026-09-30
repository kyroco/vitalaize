defmodule Wallboard.Archive.Collector do
  @moduledoc """
  Saves this Mac's Claude sessions into the database, at set points rather
  than by rescanning everything.

  Every minute it looks at the size and change time of each transcript in
  the configured Claude folders (cheap: no file is opened). A session is
  saved when its files changed since it was last saved and then stayed
  quiet for `settle_seconds`, which is when a session has gone idle or
  ended. A busy session is saved again each time it settles.

  On the first run, with nothing saved yet for this machine, that same rule
  saves the last `backfill_days` of sessions. `refresh/0` saves them all
  again, for when the reading rules change.

  Sessions whose transcript has been deleted keep everything saved and are
  marked deleted.

  The work runs in a task, so a big backfill never holds up the board.
  After each round the board is told (`{:archive, counts}` on the board's
  PubSub topic) so an open Archive tab can reload.
  """

  use GenServer
  require Logger

  alias Wallboard.Archive.{CodexTranscript, Transcript}
  alias Wallboard.Sources.Claude
  alias Wallboard.Store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Saves every session in the backfill window again."
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @doc "Where the collector is: %{running: bool, done: n, total: n, last_at: DateTime | nil}."
  def progress do
    GenServer.call(__MODULE__, :progress, 2_000)
  catch
    :exit, _ -> %{running: false, done: 0, total: 0, last_at: nil}
  end

  @doc "This machine's name in the database."
  def machine(settings) do
    case settings.archive.machine do
      m when is_binary(m) and m != "" ->
        m

      _ ->
        {:ok, name} = :inet.gethostname()
        name |> to_string() |> String.replace_suffix(".local", "")
    end
  end

  # ---------------------------------------------------------------------------
  # Server

  @impl true
  def init(_opts) do
    send(self(), :round)

    {:ok,
     %{task: nil, force: false, progress: %{running: false, done: 0, total: 0, last_at: nil}}}
  end

  @impl true
  def handle_call(:progress, _from, state), do: {:reply, state.progress, state}

  @impl true
  def handle_cast(:refresh, %{task: nil} = state), do: {:noreply, start_round(state, true)}
  def handle_cast(:refresh, state), do: {:noreply, %{state | force: true}}

  @impl true
  def handle_info(:round, %{task: nil} = state), do: {:noreply, start_round(state, state.force)}
  def handle_info(:round, state), do: {:noreply, state}

  def handle_info({:progress, done, total}, state),
    do:
      {:noreply, %{state | progress: %{state.progress | running: true, done: done, total: total}}}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, saved} when saved > 0 -> Logger.info("Archive: saved #{saved} sessions")
      {:error, reason} -> Logger.error("Archive: " <> reason)
      _ -> :ok
    end

    announce()
    settings = Wallboard.Settings.get()
    Process.send_after(self(), :round, settings.archive.poll_seconds * 1000)

    progress = %{state.progress | running: false, last_at: DateTime.utc_now()}
    {:noreply, %{state | task: nil, progress: progress}}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("Archive: the save round crashed: #{inspect(reason)}")
    Process.send_after(self(), :round, 60_000)
    {:noreply, %{state | task: nil, progress: %{state.progress | running: false}}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp start_round(state, force) do
    me = self()
    settings = Wallboard.Settings.get()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    task =
      Task.Supervisor.async_nolink(Wallboard.TaskSupervisor, fn ->
        round(settings, now, force, fn done, total -> send(me, {:progress, done, total}) end)
      end)

    %{state | task: task, force: false}
  end

  defp announce do
    Phoenix.PubSub.broadcast(
      Wallboard.PubSub,
      Wallboard.Poller.topic(),
      {:archive, Store.counts()}
    )
  end

  # ---------------------------------------------------------------------------
  # One round

  @doc """
  Finds the sessions due for saving and saves them. Returns {:ok, saved}.
  `force` saves every session in the window whether it changed or not.
  """
  def round(settings, now, force, report \\ fn _, _ -> :ok end) do
    machine = machine(settings)
    captured = Store.captured(machine)

    # The first day the archive covers, so trends only compare periods it holds.
    if !Store.get_meta("claude_since") do
      since = now |> DateTime.to_date() |> Date.add(-settings.archive.backfill_days)
      Store.put_meta("claude_since", Date.to_iso8601(since))
    end

    found = sessions_on_disk(settings, now) ++ codex_on_disk(settings, now)
    titles = if Enum.any?(found, &(&1[:tool] == "codex")), do: codex_titles(settings), else: %{}
    now_s = DateTime.to_unix(now)

    due =
      Enum.filter(found, fn s ->
        settled = now_s - s.mtime >= settings.archive.settle_seconds
        changed = Map.get(captured, s.path) != {s.size, s.mtime}
        settled and (force or changed)
      end)

    total = length(due)

    saved =
      due
      |> Enum.with_index(1)
      |> Enum.count(fn {s, i} ->
        report.(i, total)
        save(s, settings, machine, now_s, titles)
      end)

    on_disk = MapSet.new(found, & &1.path)

    gone =
      for {path, _} <- captured,
          path,
          not MapSet.member?(on_disk, path),
          not File.exists?(path),
          do: path

    if gone != [] do
      Store.mark_deleted(machine, Enum.map(gone, &CodexTranscript.id_from_path/1), now_s)
    end

    {:ok, saved}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Every main transcript changed within the window, with its subagent files.
  # A session's size and time cover its subagents too, so a subagent still
  # at work keeps the session from counting as quiet.
  defp sessions_on_disk(settings, now) do
    cutoff = DateTime.to_unix(now) - settings.archive.backfill_days * 86_400

    for dir <- settings.claude.config_dirs,
        path <- Path.wildcard(Path.join([dir, "projects", "*", "*.jsonl"])),
        {:ok, %{size: size, mtime: mtime}} <- [File.stat(path, time: :posix)],
        subs = Path.wildcard(Path.join([Path.rootname(path), "subagents", "*.jsonl"])),
        stats = Enum.flat_map(subs, &stat/1),
        mtime = Enum.max([mtime | Enum.map(stats, &elem(&1, 1))]),
        mtime >= cutoff do
      %{
        path: path,
        dir: dir,
        subs: subs,
        size: size + Enum.sum(Enum.map(stats, &elem(&1, 0))),
        mtime: mtime
      }
    end
  end

  # Every Codex session changed within the window. A helper agent's thread
  # has its own file; it is saved with the session that started it, as its
  # subagent, not as a session of its own.
  defp codex_on_disk(%{codex: %{enabled: true, dirs: dirs}} = settings, now) do
    cutoff = DateTime.to_unix(now) - settings.archive.backfill_days * 86_400

    files =
      for dir <- dirs,
          path <- Path.wildcard(Path.join([dir, "sessions", "*", "*", "*", "rollout-*.jsonl"])),
          {:ok, %{size: size, mtime: mtime}} <- [File.stat(path, time: :posix)],
          {id, parent, nickname} <- [CodexTranscript.head(path)],
          do: %{
            path: path,
            dir: dir,
            id: id,
            parent: parent,
            nickname: nickname,
            size: size,
            mtime: mtime
          }

    {subs, mains} = Enum.split_with(files, & &1.parent)
    subs_by_parent = Enum.group_by(subs, & &1.parent)

    for m <- mains,
        kids = Map.get(subs_by_parent, m.id, []),
        mtime = Enum.max([m.mtime | Enum.map(kids, & &1.mtime)]),
        mtime >= cutoff do
      %{
        path: m.path,
        dir: m.dir,
        tool: "codex",
        session_id: m.id,
        subs: Enum.map(kids, &{&1.path, &1.nickname}),
        size: m.size + Enum.sum(Enum.map(kids, & &1.size)),
        mtime: mtime
      }
    end
  end

  defp codex_on_disk(_settings, _now), do: []

  @doc "Codex's own names for its threads, from each folder's session_index.jsonl."
  def codex_titles(settings) do
    for dir <- settings.codex.dirs,
        {:ok, text} <- [File.read(Path.join(dir, "session_index.jsonl"))],
        line <- String.split(text, "\n", trim: true),
        {:ok, %{"id" => id, "thread_name" => name}} <- [Jason.decode(line)],
        is_binary(name) and name != "",
        into: %{},
        do: {id, name}
  end

  defp stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{size: s, mtime: m}} -> [{s, m}]
      _ -> []
    end
  end

  defp save(%{tool: "codex"} = s, settings, machine, now_s, titles) do
    save_codex(s.path, s.subs, %{
      prices: settings.usage.prices,
      machine: machine,
      account: codex_account(s.dir),
      title: titles[s.session_id],
      size: s.size,
      mtime: s.mtime,
      now: now_s
    })
  end

  defp save(s, settings, machine, now_s, _titles) do
    save_session(s.path, s.subs, %{
      prices: settings.usage.prices,
      machine: machine,
      account: Claude.account_label(s.dir),
      size: s.size,
      mtime: s.mtime,
      now: now_s
    })
  end

  @doc """
  Reads one session's transcript and subagent files and saves it. Used for
  this Mac's own files and for transcripts other Macs send to this board.
  `ctx` holds prices, machine, account, size, mtime and now. Returns true
  when saved; a session where nothing happened is not kept.
  """
  def save_session(path, sub_paths, ctx) do
    main = Transcript.read_file(path)

    subs =
      Enum.map(sub_paths, fn p ->
        {Transcript.read_file(p), read_meta(String.replace_suffix(p, ".jsonl", ".meta.json"))}
      end)

    if main.requests == %{} and main.prompts == 0 do
      false
    else
      ctx = Map.merge(ctx, %{session_id: Path.basename(path, ".jsonl"), path: path})
      {session, requests} = Transcript.to_record(main, subs, ctx)
      Store.put_session(session, requests) == :ok
    end
  rescue
    e ->
      Logger.warning("Archive: could not read #{path}: " <> Exception.message(e))
      false
  end

  @doc """
  Reads one Codex session and its helper agents' files ({path, nickname}
  each) and saves it. `ctx` is as for `save_session/3`, plus an optional
  `title` from Codex's own thread names.
  """
  def save_codex(path, subs, ctx) do
    main = CodexTranscript.read_file(path)
    main = if ctx[:title], do: %{main | titles: Map.put(main.titles, :ai, ctx.title)}, else: main

    subs =
      Enum.map(subs, fn {p, nickname} ->
        {CodexTranscript.read_file(p), %{type: nickname, description: nil}}
      end)

    if main.requests == %{} and main.prompts == 0 do
      false
    else
      id = main.thread_id || CodexTranscript.id_from_path(path)
      ctx = Map.merge(ctx, %{session_id: id, path: path, tool: "codex"})
      {session, requests} = Transcript.to_record(main, subs, ctx)
      Store.put_session(session, requests) == :ok
    end
  rescue
    e ->
      Logger.warning("Archive: could not read #{path}: " <> Exception.message(e))
      false
  end

  @doc """
  The account label for a Codex folder: none for ~/.codex (the icon already
  says Codex); another folder is named by its own name.
  """
  def codex_account(dir) do
    case dir |> Path.basename() |> String.trim_leading(".") do
      "codex" -> nil
      other -> other
    end
  end

  defp read_meta(path) do
    with {:ok, text} <- File.read(path), {:ok, %{} = m} <- Jason.decode(text) do
      %{type: m["agentType"], description: m["description"]}
    else
      _ -> %{type: nil, description: nil}
    end
  end
end
