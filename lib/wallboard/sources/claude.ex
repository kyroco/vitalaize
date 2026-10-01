defmodule Wallboard.Sources.Claude do
  @moduledoc """
  Live Claude Code sessions, from `claude agents --json`.

  What that command reports (checked against Claude Code 2.1.284):

    * `status`: "busy", "idle" or "waiting". When "waiting" it adds
      `waitingFor`, a short label such as "permission prompt" or
      "input needed".
    * `state` (background sessions only): "working", "blocked", "done",
      "failed" or "stopped". "blocked" means the session stopped and is
      waiting on its person.

  A session needs you when its status is "waiting" or its state is "blocked".

  A row with no `pid` has no process behind it, so it is not a live session
  and is left out. A background job stopped with `claude stop` can stay in
  the list for hours as such a row, still saying `state: "working"`. Every
  session with a process has a `pid`, whether busy, idle or in a terminal
  (checked against Claude Code 2.1.285).

  The words for why it is waiting come from the background job's own file,
  <config dir>/jobs/<id>/state.json, whose `detail` holds the question it
  asked. That file is undocumented, so it is optional: when it is missing or
  its shape changes, the board falls back to the waitingFor label.
  """

  alias Wallboard.Cmd

  @waiting_words %{
    "permission prompt" => "A permission prompt is waiting for your approval",
    "input needed" => "It asked you a question",
    "dialog open" => "A dialog is open and waiting for you",
    "sandbox request" => "A command is asking for network access",
    "worker request" => "A helper is asking for your approval",
    "goal proposal" => "It proposed a goal for you to approve"
  }

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(settings, _prev, tracking, now) do
    case fetch(settings) do
      {:ok, sessions, problems} ->
        {annotated, tracking, newly} = track(sessions, tracking, now)
        Wallboard.Alerts.needs_you(newly, settings)
        {:ok, %{sessions: annotated, problems: problems}, tracking}

      {:error, reason} ->
        {:error, reason, tracking}
    end
  end

  def fingerprint(facts), do: facts

  # ---------------------------------------------------------------------------
  # Fetching

  @doc """
  Polls every configured Claude config dir. Returns {:ok, sessions, problems}
  where problems lists dirs that failed, or {:error, reason} if all failed.
  """
  def fetch(settings) do
    dirs = settings.claude.config_dirs
    multi? = length(dirs) > 1

    results =
      Enum.map(dirs, fn dir ->
        case Cmd.run("claude", ["agents", "--json"],
               env: [{"CLAUDE_CONFIG_DIR", dir}],
               timeout: 15_000
             ) do
          {:ok, out} ->
            with {:ok, agents} <- parse_agents(out) do
              account = if multi?, do: account_label(dir), else: nil
              {:ok, agents |> live() |> Enum.map(&enrich(&1, dir, account))}
            end

          {:error, reason} ->
            {:error, "#{account_label(dir)}: #{reason}"}
        end
      end)

    oks = for {:ok, sessions} <- results, do: sessions
    problems = for {:error, reason} <- results, do: reason

    if oks == [] and problems != [] do
      {:error, Enum.join(problems, "; ")}
    else
      {:ok, oks |> List.flatten() |> Enum.sort_by(& &1.started_at), problems}
    end
  end

  defp enrich(agent, dir, account) do
    job = if agent.kind == "background" and agent.id, do: read_job(dir, agent.id), else: nil
    file = if agent.pid, do: read_session_file(dir, agent.pid), else: nil
    build_session(agent, job, file, account)
  end

  defp read_job(dir, id) do
    with {:ok, text} <- File.read(Path.join([dir, "jobs", id, "state.json"])),
         {:ok, job} <- parse_job_state(text) do
      job
    else
      _ -> nil
    end
  end

  defp read_session_file(dir, pid) do
    with {:ok, text} <- File.read(Path.join([dir, "sessions", "#{pid}.json"])),
         {:ok, file} <- parse_session_file(text) do
      file
    else
      _ -> nil
    end
  end

  @doc "A short account name for a config dir: ~/.claude-second-account -> second-account."
  def account_label(dir) do
    case dir |> Path.basename() |> String.trim_leading(".") do
      "claude" -> "main"
      "claude-" <> rest -> rest
      other -> other
    end
  end

  # ---------------------------------------------------------------------------
  # Parsing (pure, tested against saved real output)

  @doc "Parses `claude agents --json` output into plain maps."
  def parse_agents(text) do
    case Jason.decode(text) do
      {:ok, list} when is_list(list) ->
        {:ok, list |> Enum.filter(&is_map/1) |> Enum.map(&agent/1)}

      {:ok, _} ->
        {:error, "claude agents --json did not return a list"}

      {:error, _} ->
        {:error, "claude agents --json returned something that is not JSON"}
    end
  end

  @doc """
  The agents that have a process. A row with no pid is a job that ended or
  was stopped, whatever its state says, so the board and a collector, which
  both read the list through `fetch/1`, never show or count it.
  """
  def live(agents), do: Enum.filter(agents, & &1.pid)

  defp agent(raw) do
    %{
      id: str(raw["id"]),
      pid: int(raw["pid"]),
      session_id: str(raw["sessionId"]),
      name: str(raw["name"]),
      kind: str(raw["kind"]) || "interactive",
      cwd: str(raw["cwd"]),
      status: str(raw["status"]),
      state: str(raw["state"]),
      waiting_for: str(raw["waitingFor"]),
      started_at: ms_to_datetime(raw["startedAt"])
    }
  end

  @doc "Parses a background job's state.json. Every field is optional."
  def parse_job_state(text) do
    case Jason.decode(text) do
      {:ok, %{} = raw} ->
        {:ok,
         %{
           state: str(raw["state"]),
           tempo: str(raw["tempo"]),
           detail: str(raw["detail"]),
           needs: str(raw["needs"]),
           updated_at: iso_to_datetime(raw["updatedAt"])
         }}

      _ ->
        {:error, :unreadable}
    end
  end

  @doc "Parses <config dir>/sessions/<pid>.json. Every field is optional."
  def parse_session_file(text) do
    case Jason.decode(text) do
      {:ok, %{} = raw} ->
        {:ok,
         %{
           status_since: ms_to_datetime(raw["statusUpdatedAt"]),
           updated_at: ms_to_datetime(raw["updatedAt"])
         }}

      _ ->
        {:error, :unreadable}
    end
  end

  @doc """
  Turns one agent, plus its optional job file and session file, into the
  session the board shows.
  """
  def build_session(agent, job, file, account) do
    status = classify(agent)

    %{
      key: Enum.join([account || "", agent.session_id || agent.id || "pid#{agent.pid}"], ":"),
      session_id: agent.session_id,
      name: agent.name || agent.id || short(agent.session_id) || "unnamed",
      short_id: agent.id || short(agent.session_id),
      account: account,
      kind: agent.kind,
      folder: agent.cwd && Path.basename(agent.cwd),
      cwd: agent.cwd,
      status: status,
      task: task(agent, job),
      why: if(status == :needs, do: why(agent, job), else: nil),
      # The kind of wait, as `claude agents` words it. A collector sends this
      # in place of the words above.
      waiting_for: if(status == :needs, do: agent.waiting_for, else: nil),
      # When the waiting started, as far as the files can tell.
      waiting_since: waiting_since(agent, job, file),
      updated_at: (job && job.updated_at) || (file && file.updated_at) || agent.started_at,
      started_at: agent.started_at
    }
  end

  @doc "needs, working or idle."
  def classify(%{status: "waiting"}), do: :needs
  def classify(%{state: "blocked"}), do: :needs
  def classify(%{status: "busy"}), do: :working
  def classify(%{status: nil, state: "working"}), do: :working
  def classify(_), do: :idle

  defp task(agent, job) do
    cond do
      job && job.detail && job.detail not in ["", "stopped", "done"] -> job.detail
      agent.cwd -> agent.cwd |> Path.split() |> Enum.take(-2) |> Path.join()
      true -> nil
    end
  end

  @doc "Plain words for why a session is waiting on you."
  def why(agent, job) do
    cond do
      job && present?(job.needs) ->
        job.needs

      job && job.tempo == "blocked" && present?(job.detail) ->
        job.detail

      agent.waiting_for ->
        Map.get(@waiting_words, agent.waiting_for, "Waiting on you: " <> agent.waiting_for)

      job && present?(job.detail) ->
        job.detail

      true ->
        "Waiting on you"
    end
  end

  defp waiting_since(agent, job, file) do
    cond do
      agent.status == "waiting" && file && file.status_since -> file.status_since
      job && job.updated_at -> job.updated_at
      file && file.status_since -> file.status_since
      true -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Tracking across polls (pure)

  @doc """
  Carries what can only be learned by watching over time: when each session
  started working, and when it started needing you. Returns
  {sessions_with_times, new_tracking, newly_needing}.

  `newly_needing` lists sessions that need you now but did not on the
  previous poll. On the very first poll (tracking is nil) nothing counts as
  new, so restarting the board never re-sends a text.
  """
  def track(sessions, tracking, now) do
    first_poll? = is_nil(tracking)
    tracking = tracking || %{}

    {annotated, new_tracking} =
      Enum.map_reduce(sessions, %{}, fn s, acc ->
        prev = Map.get(tracking, s.key)
        since = since_for(s, prev, now)
        {Map.put(s, :since, since), Map.put(acc, s.key, %{status: s.status, since: since})}
      end)

    newly =
      if first_poll? do
        []
      else
        Enum.filter(annotated, fn s ->
          s.status == :needs and (Map.get(tracking, s.key) || %{})[:status] != :needs
        end)
      end

    {annotated, new_tracking, newly}
  end

  # Same status as last poll: keep the time it began. New status: the files'
  # own timestamp when they have one, otherwise now.
  defp since_for(%{status: status} = s, %{status: status, since: since}, _now),
    do: since || s.waiting_since

  defp since_for(%{status: :needs} = s, _prev, now), do: s.waiting_since || now
  defp since_for(%{status: :working} = s, nil, now), do: s.updated_at || now
  defp since_for(_s, _prev, now), do: now

  @doc "True when a working session has been at it longer than the setting."
  def long_running?(%{status: :working, since: %DateTime{} = since}, now, minutes) do
    DateTime.diff(now, since, :second) > minutes * 60
  end

  def long_running?(_, _, _), do: false

  # ---------------------------------------------------------------------------

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
  defp short(nil), do: nil
  defp short(id), do: String.slice(id, 0, 8)
  defp str(v) when is_binary(v) and v != "", do: v
  defp str(_), do: nil
  defp int(v) when is_integer(v), do: v
  defp int(_), do: nil

  defp ms_to_datetime(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp ms_to_datetime(_), do: nil

  defp iso_to_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp iso_to_datetime(_), do: nil
end
