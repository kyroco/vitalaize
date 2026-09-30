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

  Codex writes nothing when it waits on a person, so a Codex session never
  shows as needing you.

  The first poll reads each recent file in full; after that only the new
  lines at the end are read.
  """

  alias Wallboard.Archive.CodexTranscript

  @stale_turn_seconds 15 * 60

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(settings, _prev, memory, now) do
    memory = memory || %{files: %{}, titles: {nil, %{}}}

    if settings.codex.enabled do
      files = scan(settings, memory.files, now)
      titles = titles(settings, memory.titles)
      sessions = sessions(files, elem(titles, 1), now)
      {:ok, %{sessions: sessions}, %{files: files, titles: titles}}
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
  # Building the cards (pure)

  @doc "The sessions to show, from each file's tally."
  def sessions(files, titles, now) do
    now_s = DateTime.to_unix(now)
    all = Enum.map(files, fn {path, s} -> Map.merge(s.tally, %{path: path, mtime: s.mtime}) end)
    {subs, mains} = Enum.split_with(all, & &1.parent_id)
    subs_by_parent = Enum.group_by(subs, & &1.parent_id)

    mains
    |> Enum.filter(& &1.thread_id)
    |> Enum.map(fn t ->
      kids = Map.get(subs_by_parent, t.thread_id, [])
      card(t, kids, titles[t.thread_id], now_s)
    end)
    |> Enum.sort_by(&DateTime.to_unix(&1.started_at || now))
  end

  @doc "One Codex session as the card the board shows, beside the Claude ones."
  def card(t, kids, title, now_s) do
    working? = t.running and now_s - t.mtime < @stale_turn_seconds
    updated = DateTime.from_unix!(t.mtime)
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
      cwd: t.cwd,
      started_by: started_by(t.originator),
      status: if(working?, do: :working, else: :idle),
      task: short_prompt(t.last_prompt) || t.cwd,
      why: nil,
      waiting_since: nil,
      updated_at: updated,
      started_at: t.first_at,
      since: if(working?, do: t.turn_started_at || updated, else: updated),
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
