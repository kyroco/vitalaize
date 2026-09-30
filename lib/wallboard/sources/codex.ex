defmodule Wallboard.Sources.Codex do
  @moduledoc """
  Live Codex sessions, from the session files Codex writes as it works
  (see `Wallboard.Archive.CodexTranscript` for what they hold).

  Codex has no command that lists what is running, so a session's state
  comes from its file:

    * working: a turn started and has not finished, and the file changed in
      the last #{15} minutes (a turn whose file went quiet longer than that
      was cut off without saying so)
    * idle: its last turn finished; it stays on the board for
      `codex.idle_minutes` after its file last changed

  Codex writes nothing to that file while it waits on a person, so needing
  you comes from VitalAIze's Codex hook instead (priv/codex-hook.sh). The
  board keeps a copy at <codex dir>/vitalaize/hook.sh; once the person adds
  it to ~/.codex/hooks.json and approves it in Codex, Codex runs it on
  PermissionRequest, PostToolUse, UserPromptSubmit and Stop, and it keeps
  the latest call for each session as vitalaize/<session id>.json. A session
  needs you when that latest call is

    * PermissionRequest: Codex is asking to run something, or
    * Stop, with a last message whose last paragraph ends in a question mark

  Anything later (the tool ran, the person typed, the turn ended without a
  question) replaces it, so the card goes back to working or idle.

  The first poll reads each recent file in full; after that only the new
  lines at the end are read.
  """

  alias Wallboard.Archive.CodexTranscript

  @stale_turn_seconds 15 * 60
  @hook_folder "vitalaize"
  # A session's last hook call is kept this long, then removed.
  @mark_keep_seconds 7 * 24 * 3600

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(settings, _prev, memory, now) do
    memory = memory || %{files: %{}, titles: {nil, %{}}, needs: nil, hook: false}

    if settings.codex.enabled do
      hook = memory[:hook] || install_hook(settings)
      files = scan(settings, memory.files, now)
      titles = titles(settings, memory.titles)
      sessions = sessions(files, elem(titles, 1), now, marks(settings, now))
      {newly, needs} = newly_needing(sessions, memory[:needs])
      Wallboard.Alerts.needs_you(newly, settings)
      {:ok, %{sessions: sessions}, %{files: files, titles: titles, needs: needs, hook: hook}}
    else
      {:ok, %{sessions: []}, memory}
    end
  rescue
    e -> {:error, "could not read Codex sessions: " <> Exception.message(e), memory}
  end

  def fingerprint(facts), do: facts

  # ---------------------------------------------------------------------------
  # Reading

  defp scan(settings, known, now) do
    window = settings.codex.idle_minutes * 60
    cutoff = DateTime.to_unix(now) - window

    for dir <- settings.codex.dirs,
        path <- recent_files(dir, now),
        {:ok, %{size: size, mtime: mtime}} <- [File.stat(path, time: :posix)],
        mtime >= cutoff,
        into: %{} do
      state = Map.get(known, path) || %{offset: 0, mtime: 0, tally: CodexTranscript.empty()}
      {path, read_new(state, path, size, mtime)}
    end
  end

  # Session files sit in YYYY/MM/DD folders by the day they started; a
  # session that started yesterday can still be at work today.
  defp recent_files(dir, now) do
    for back <- 0..2,
        day = now |> DateTime.to_date() |> Date.add(-back),
        path <-
          Path.wildcard(
            Path.join([
              dir,
              "sessions",
              "#{day.year}",
              pad(day.month),
              pad(day.day),
              "rollout-*.jsonl"
            ])
          ),
        do: path
  end

  defp pad(n), do: String.pad_leading("#{n}", 2, "0")

  defp read_new(%{offset: offset} = state, _path, size, mtime) when size <= offset,
    do: %{state | mtime: mtime}

  defp read_new(state, path, size, mtime) do
    {:ok, io} = :file.open(path, [:read, :binary, :raw])

    try do
      {:ok, chunk} = :file.pread(io, state.offset, size - state.offset)

      case :binary.matches(chunk, "\n") do
        [] ->
          %{state | mtime: mtime}

        matches ->
          {last_nl, 1} = List.last(matches)
          tally = CodexTranscript.read_lines(state.tally, binary_part(chunk, 0, last_nl))
          %{state | tally: tally, offset: state.offset + last_nl + 1, mtime: mtime}
      end
    after
      :file.close(io)
    end
  end

  # Codex's own names for its threads. Read again only when the file changed.
  defp titles(settings, {stamp, titles}) do
    paths = Enum.map(settings.codex.dirs, &Path.join(&1, "session_index.jsonl"))

    now_stamp =
      Enum.map(paths, fn p ->
        case File.stat(p, time: :posix) do
          {:ok, s} -> {s.size, s.mtime}
          _ -> nil
        end
      end)

    if now_stamp == stamp do
      {stamp, titles}
    else
      {now_stamp, Wallboard.Archive.Collector.codex_titles(settings)}
    end
  end

  # ---------------------------------------------------------------------------
  # The hook

  @doc "The hook script VitalAIze ships, which Codex runs from hooks.json."
  def hook_script, do: File.read!(Application.app_dir(:wallboard, "priv/codex-hook.sh"))

  # Keeps <codex dir>/vitalaize/hook.sh the same as the one shipped, in each
  # Codex folder that exists, so the path in hooks.json survives an upgrade.
  # Never makes a Codex folder. True once done, so it runs once per start.
  defp install_hook(settings) do
    script = hook_script()

    for dir <- settings.codex.dirs, File.dir?(dir) do
      path = Path.join([dir, @hook_folder, "hook.sh"])

      if File.read(path) != {:ok, script} do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, script)
        File.chmod!(path, 0o755)
      end
    end

    true
  rescue
    _ -> false
  end

  @doc """
  The latest hook call for each session, by session id: the JSON Codex handed
  the hook, plus `at`, when it came in. Leaves out calls older than the idle
  window, and removes those older than a week.
  """
  def marks(settings, now) do
    now_s = DateTime.to_unix(now)
    cutoff = now_s - settings.codex.idle_minutes * 60

    for dir <- settings.codex.dirs,
        path <- Path.wildcard(Path.join([dir, @hook_folder, "*.json"])),
        {:ok, %{mtime: mtime}} <- [File.stat(path, time: :posix)],
        mtime >= cutoff or forget(path, mtime, now_s),
        {:ok, body} <- [File.read(path)],
        {:ok, %{"session_id" => id} = mark} when is_binary(id) <- [Jason.decode(body)],
        into: %{} do
      {id, Map.put(mark, "at", mtime)}
    end
  end

  defp forget(path, mtime, now_s) do
    if now_s - mtime > @mark_keep_seconds, do: File.rm(path)
    false
  end

  @doc """
  Why a session is waiting on you, from its latest hook call, or nil when it
  is not. A call from before its current turn started is out of date.
  """
  def waiting(nil, _t), do: nil

  def waiting(%{"at" => at} = mark, t) do
    started = t.turn_started_at && DateTime.to_unix(t.turn_started_at)

    cond do
      started && at < started -> nil
      mark["hook_event_name"] == "PermissionRequest" -> approval(mark)
      mark["hook_event_name"] == "Stop" -> question(mark["last_assistant_message"])
      true -> nil
    end
  end

  defp approval(%{"tool_input" => %{"command" => command}})
       when is_binary(command) or is_list(command) do
    command = if is_list(command), do: Enum.join(command, " "), else: command
    "Asks to run: " <> clip(one_line(command), 200)
  end

  defp approval(%{"tool_name" => tool}) when is_binary(tool) and tool != "",
    do: "Asks for your approval to use " <> tool

  defp approval(_), do: "Asks for your approval"

  @doc """
  The question a message ends on, or nil. A message ends on a question when
  its last paragraph ends in a question mark, allowing for closing quotes,
  brackets and markdown after it.
  """
  def question(text) when is_binary(text) do
    last =
      text
      |> String.trim()
      |> String.split(~r/\n\s*\n/)
      |> List.last()
      |> one_line()

    if Regex.match?(~r/\?[\s*_`"'”’)\]]*$/u, last), do: clip(last, 240), else: nil
  end

  def question(_), do: nil

  defp one_line(text), do: text |> String.split() |> Enum.join(" ")

  defp clip(s, n), do: if(String.length(s) > n, do: String.slice(s, 0, n) <> "…", else: s)

  @doc """
  The sessions that need you now but did not on the previous poll, and the
  keys of all that need you now. On the first poll (previous is nil) none is
  new, so restarting the board never re-sends a text.
  """
  def newly_needing(sessions, previous) do
    needing = Enum.filter(sessions, &(&1.status == :needs))
    keys = MapSet.new(needing, & &1[:key])
    newly = if previous, do: Enum.reject(needing, &MapSet.member?(previous, &1[:key])), else: []
    {newly, keys}
  end

  # ---------------------------------------------------------------------------
  # Building the cards (pure)

  @doc "The sessions to show, from each file's tally and each session's latest hook call."
  def sessions(files, titles, now, marks \\ %{}) do
    now_s = DateTime.to_unix(now)
    all = Enum.map(files, fn {path, s} -> Map.merge(s.tally, %{path: path, mtime: s.mtime}) end)
    {subs, mains} = Enum.split_with(all, & &1.parent_id)
    subs_by_parent = Enum.group_by(subs, & &1.parent_id)

    mains
    |> Enum.filter(& &1.thread_id)
    |> Enum.map(fn t ->
      kids = Map.get(subs_by_parent, t.thread_id, [])
      card(t, kids, titles[t.thread_id], now_s, marks[t.thread_id])
    end)
    |> Enum.sort_by(&DateTime.to_unix(&1.started_at || now))
  end

  @doc "One Codex session as the card the board shows, beside the Claude ones."
  def card(t, kids, title, now_s, mark \\ nil) do
    working? = t.running and now_s - t.mtime < @stale_turn_seconds
    why = waiting(mark, t)
    waiting_since = why && DateTime.from_unix!(mark["at"])
    updated = DateTime.from_unix!(t.mtime)

    status =
      cond do
        why -> :needs
        working? -> :working
        true -> :idle
      end

    reqs = Enum.flat_map([t | kids], &Map.values(&1.requests))

    %{
      tool: :codex,
      key: "codex:" <> t.thread_id,
      session_id: t.thread_id,
      name:
        title || short_prompt(t.first_prompt) || folder(t.cwd) || String.slice(t.thread_id, 0, 8),
      short_id: String.slice(t.thread_id, 0, 8),
      account: nil,
      kind: "codex",
      folder: folder(t.cwd),
      started_by: started_by(t.originator),
      status: status,
      task: short_prompt(t.last_prompt) || t.cwd,
      why: why,
      waiting_since: waiting_since,
      updated_at: updated,
      started_at: t.first_at,
      since:
        case status do
          :needs -> waiting_since
          :working -> t.turn_started_at || updated
          :idle -> updated
        end,
      detail: %{
        tokens: Enum.sum(Enum.map(reqs, &(&1.input + &1.cache_read + &1.output))),
        plan_used: t.plan_used,
        model_label: t.model,
        effort: t.effort,
        context_pct:
          t.last_context && t.context_window && t.context_window > 0 &&
            round(t.last_context * 100 / t.context_window),
        added: Enum.sum(Enum.map([t | kids], & &1.added)),
        removed: Enum.sum(Enum.map([t | kids], & &1.removed)),
        subagents:
          Enum.map(kids, fn k ->
            %{
              name: k.nickname || "helper",
              running: k.running and now_s - k.mtime < @stale_turn_seconds
            }
          end)
      }
    }
  end

  # Who started it, when it was not a person in Codex itself.
  defp started_by("Claude Code"), do: "Claude"
  defp started_by("codex_exec"), do: "a script"
  defp started_by(_), do: nil

  defp folder(nil), do: nil
  defp folder(cwd), do: Path.basename(cwd)

  defp short_prompt(nil), do: nil

  defp short_prompt(text) do
    line =
      text |> String.split("\n", trim: true) |> List.first() |> Kernel.||("") |> String.trim()

    cond do
      line == "" -> nil
      String.length(line) > 90 -> String.slice(line, 0, 90) <> "…"
      true -> line
    end
  end
end
