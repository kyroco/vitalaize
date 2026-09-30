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
  PermissionRequest, PostToolUse, UserPromptSubmit, Stop and SessionEnd, and
  it keeps the latest call for each session as vitalaize/<session id>.json,
  and for each helper agent in it as vitalaize/<session id>.<agent id>.json.
  A session needs you when one of those is

    * PermissionRequest: Codex is asking to run something, or
    * Stop, with a last message whose last paragraph ends in a question mark

  and nothing has moved on since (see `waiting/2`). A session with an
  approval request out stays on the board for up to 12 hours, past the idle
  window, since Codex writes nothing while it waits.

  The first poll reads each recent file in full; after that only the new
  lines at the end are read.
  """

  alias Wallboard.Archive.CodexTranscript

  @stale_turn_seconds 15 * 60
  @hook_folder "vitalaize"
  # A session's last hook call is kept this long, then removed.
  @mark_keep_seconds 7 * 24 * 3600
  # An approval request keeps its session on the board this long, past the
  # idle window: long enough to find it after a night away, short enough
  # that one left by a Codex that crashed does not stay for days.
  @asking_seconds 12 * 3600

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(settings, _prev, memory, now) do
    memory = memory || %{files: %{}, titles: {nil, %{}}, needs: nil, marks: %{}}

    if settings.codex.enabled do
      install_hook(settings)
      {marks, read} = marks(settings, now, memory[:marks] || %{})
      files = scan(settings, memory.files, now, asking(marks))
      titles = titles(settings, memory.titles)
      idle_cutoff = DateTime.add(now, -settings.codex.idle_minutes * 60)

      sessions =
        files
        |> sessions(elem(titles, 1), now, marks)
        |> Enum.filter(
          &(&1.status == :needs or DateTime.compare(&1.updated_at, idle_cutoff) != :lt)
        )

      {newly, needs} = newly_needing(sessions, memory[:needs])
      Wallboard.Alerts.needs_you(newly, settings)
      {:ok, %{sessions: sessions}, %{files: files, titles: titles, needs: needs, marks: read}}
    else
      {:ok, %{sessions: []}, memory}
    end
  rescue
    e -> {:error, "could not read Codex sessions: " <> Exception.message(e), memory}
  end

  def fingerprint(facts), do: facts

  # ---------------------------------------------------------------------------
  # Reading

  # `asking` holds the sessions with an approval request out: Codex writes
  # nothing while it waits, so those stay past the idle window.
  defp scan(settings, known, now, asking) do
    window = settings.codex.idle_minutes * 60
    cutoff = DateTime.to_unix(now) - window

    for dir <- settings.codex.dirs,
        path <- recent_files(dir, now),
        {:ok, %{size: size, mtime: mtime}} <- [File.stat(path, time: :posix)],
        mtime >= cutoff or CodexTranscript.id_from_path(path) in asking,
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
  # Never makes a Codex folder. Runs every poll, so a Codex folder made later
  # or a deleted copy is put right without a restart; it is one small read.
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

    :ok
  rescue
    _ -> :error
  end

  @doc """
  The latest hook calls for each session, as a list by session id: the JSON
  Codex handed the hook, plus `at`, when it came in. The hook keeps one file
  for the session and one for each helper agent working in it (its calls
  carry `agent_id`), so a helper's call never replaces the session's own.

  Leaves out approval requests older than two days and other calls older
  than the idle window; removes files older than a week, and any
  half-written file the hook left behind when it was stopped.

  Returns {marks, read}. `read` remembers each file by its time and size, so
  the next poll decodes only the files that changed; pass it back in.
  """
  def marks(settings, now, read \\ %{}) do
    now_s = DateTime.to_unix(now)
    idle_cutoff = now_s - settings.codex.idle_minutes * 60
    cutoff = min(idle_cutoff, now_s - @asking_seconds)

    for {path, name} <- hook_files(settings),
        String.starts_with?(name, ".hook."),
        {:ok, %{mtime: mtime}} <- [File.stat(path, time: :posix)],
        now_s - mtime > 3600,
        do: File.rm(path)

    found =
      for {path, name} <- hook_files(settings),
          name =~ ~r/^[0-9A-Za-z_-]+(\.[0-9A-Za-z_-]+)?\.json$/,
          {:ok, %{mtime: mtime, size: size}} <- [File.stat(path, time: :posix)],
          mtime >= cutoff or forget(path, mtime, now_s),
          mark = cached(read[path], {mtime, size}) || decode(path, mtime),
          do: {path, {{mtime, size}, mark}}

    marks =
      for {_path, {_, %{"session_id" => _, "at" => at} = mark}} <- found,
          at >= idle_cutoff or mark["hook_event_name"] == "PermissionRequest" do
        mark
      end
      |> Enum.group_by(& &1["session_id"])

    {marks, Map.new(found)}
  end

  @doc "The sessions with an approval request out, from `marks/3`."
  def asking(marks) do
    for {id, list} <- marks,
        Enum.any?(list, &(&1["hook_event_name"] == "PermissionRequest")),
        into: MapSet.new(),
        do: id
  end

  # The files in each <codex dir>/vitalaize, as {path, name}. Lists the
  # folder rather than matching a pattern, so a folder name in settings is
  # never read as one.
  defp hook_files(settings) do
    for dir <- settings.codex.dirs,
        folder = Path.join(dir, @hook_folder),
        {:ok, names} <- [File.ls(folder)],
        name <- names,
        do: {Path.join(folder, name), name}
  end

  defp cached({stamp, mark}, stamp), do: mark
  defp cached(_, _), do: nil

  # A file that does not decode is remembered as an empty map, so it is not
  # read again until it changes.
  defp decode(path, mtime) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"session_id" => id} = mark} when is_binary(id) <- Jason.decode(body) do
      Map.put(mark, "at", mtime)
    else
      _ -> %{}
    end
  end

  defp forget(path, mtime, now_s) do
    if now_s - mtime > @mark_keep_seconds, do: File.rm(path)
    false
  end

  @doc """
  Why a session is waiting on you, from one of its hook calls, or nil when it
  is not. A call is out of date when a turn started after it. An approval
  request is also over once the session writes anything later (the command
  ran, or was turned down) or its turn ends (it was interrupted). A turn that
  ended on a question counts only in a session a person started in Codex:
  one run by a script or by Claude has nobody at the keyboard.

  A helper agent's approval request (it carries `agent_id` and comes under
  the session's id) is judged on its own: the session's file says nothing
  about the helper, so only the helper's next hook call clears it.
  """
  def waiting(nil, _t), do: nil

  def waiting(%{"at" => at} = mark, t) do
    started = t.turn_started_at && DateTime.to_unix(t.turn_started_at)
    last = t.last_at && DateTime.to_unix(t.last_at)
    helper? = mark["agent_id"] not in [nil, ""]

    case mark["hook_event_name"] do
      "PermissionRequest" when helper? ->
        approval(mark)

      _ when started != nil and at < started ->
        nil

      "PermissionRequest" ->
        # Codex's own lines are stamped to the second and may land in the
        # same second as the request, so a line counts only from two seconds
        # after it.
        if t.running and not (last && last > at + 1), do: approval(mark)

      # Another Stop hook can send the turn on, so it counts once the turn
      # has really ended.
      "Stop" ->
        if not t.running and started_by(t.originator) == nil,
          do: question(mark["last_assistant_message"])

      _ ->
        nil
    end
  end

  def waiting(_, _t), do: nil

  # Only the program's name: the rest of a command can hold a password or a
  # token, and this text goes on the board and into a text message.
  defp approval(%{"tool_input" => %{"command" => command}} = mark)
       when is_binary(command) or is_list(command) do
    # A list is the program and its arguments already; a string is split the
    # way a shell would, so a quoted value with a space stays one word.
    words =
      if is_list(command),
        do: Enum.filter(command, &is_binary/1),
        else: OptionParser.split(command)

    case program(words) do
      nil -> approval(Map.delete(mark, "tool_input"))
      name -> "Asks to run " <> clip(name, 60)
    end
  end

  defp approval(%{"tool_name" => tool}) when is_binary(tool) and tool != "",
    do: "Asks for your approval to use " <> tool

  defp approval(_), do: "Asks for your approval"

  # The program a command runs, looking past a shell wrapper such as
  # `/bin/zsh -lc "git push"` and leading VAR=value settings.
  @shells ["sh", "bash", "zsh", "dash", "fish"]

  defp program([word | rest]) do
    cond do
      String.trim(word) == "" ->
        program(rest)

      word =~ ~r/^[A-Za-z_][A-Za-z0-9_]*=/ ->
        program(rest)

      Path.basename(word) in @shells and match?([<<"-", _::binary>>, _ | _], rest) ->
        [_flag, script | _] = rest
        program(OptionParser.split(script))

      true ->
        Path.basename(word)
    end
  end

  defp program([]), do: nil

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
      card(t, kids, titles[t.thread_id], now_s, marks)
    end)
    |> Enum.sort_by(&DateTime.to_unix(&1.started_at || now))
  end

  # The session, or one of its helper agents, waiting on you: {why, since}.
  # A helper's calls come under the session's id with its `agent_id`, or,
  # should Codex give them the helper's own thread id, under that. Only a
  # helper's approval requests reach the person; its questions go to the
  # session that started it.
  defp waiting_on(t, kids, marks) do
    own =
      for mark <- Map.get(marks, t.thread_id, []),
          mark["agent_id"] in [nil, ""] or approval?(mark),
          do: {t, mark}

    helpers =
      for k <- kids, mark <- Map.get(marks, k.thread_id, []), approval?(mark), do: {k, mark}

    Enum.find_value(own ++ helpers, {nil, nil}, fn {who, mark} ->
      if why = waiting(mark, who), do: {why, DateTime.from_unix!(mark["at"])}
    end)
  end

  defp approval?(mark), do: mark["hook_event_name"] == "PermissionRequest"

  @doc """
  One Codex session as the card the board shows, beside the Claude ones.
  `marks` holds the latest hook calls for each thread, by thread id, as
  `marks/3` returns them.
  """
  def card(t, kids, title, now_s, marks \\ %{}) do
    working? = t.running and now_s - t.mtime < @stale_turn_seconds
    {why, waiting_since} = waiting_on(t, kids, marks)
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
