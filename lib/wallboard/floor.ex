defmodule Wallboard.Floor do
  @moduledoc """
  The rules of the Floor tab: the board's sessions drawn as little people
  in an office. Every rule about who someone is and what they are doing
  lives here, so the browser only draws (see priv/static/js/floor.js).

  Who is who:

    * A **foreman** is a session with the word "foreman" in its name or in
      its folder's name. `claude agents` does not say which session started
      which, so the name is all there is to go on. Everyone else is a
      **worker**.
    * A **crew** is everyone in the same project: the repository when the
      board knows it, else the project folder.

  What each one is doing, by the session's status:

    * needs you: `:needs`. It leaves its desk and comes to you. The longer
      it has waited, the louder it gets (`urgency/2`, 1 to 4).
    * working: `:working`, at its desk.
    * idle for less than a day: `:wandering`.
    * idle for one to seven days: `:asleep`. You forgot it.
    * idle for seven days or more: `:packed`. It sits by the campfire with
      its bag packed, ready to be archived.

  What the browser adds for fun says nothing about a session and has no
  rule here: the jokes and small talk, the shouting, the cat, the paper
  planes, ping pong for the idle, the water cooler that runs dry, and
  lunch, when a few of the idle walk out to the picnic table together.
  None of it hides a status: one who needs you drops the paddle or leaves
  the table at once, and one who is working takes the laptop along to
  lunch.
  """

  @day 86_400

  # Idle this many days: asleep. This many: packed and ready to archive.
  @asleep_days 1
  @packed_days 7

  # Waiting on you this many seconds moves a session up one step of
  # loudness: a wave at 2 minutes, a bullhorn at 10, a protest at 30.
  @urgency_steps [120, 600, 1800]

  # A bubble on the floor holds this many characters, and a name tag this many.
  @bubble_chars 90
  @tag_chars 20

  @doc "`:foreman` or `:worker`, by the word foreman in the name or the folder."
  def role(session) do
    if foreman_word?(session[:name]) or foreman_word?(session[:folder]),
      do: :foreman,
      else: :worker
  end

  # The word on its own: "Foreman billing" and "foreman-billing-b9914b"
  # count, "foremanual" does not.
  defp foreman_word?(text) when is_binary(text),
    do: Regex.match?(~r/(^|[^a-z])foreman([^a-z]|$)/i, text)

  defp foreman_word?(_), do: false

  @doc "What a session is doing on the floor (see the moduledoc)."
  def mood(%{status: :needs}, _now), do: :needs
  def mood(%{status: :working}, _now), do: :working

  def mood(session, now) do
    case quiet_seconds(session, now) do
      nil -> :wandering
      secs when secs >= @packed_days * @day -> :packed
      secs when secs >= @asleep_days * @day -> :asleep
      _ -> :wandering
    end
  end

  @doc """
  How loud a session that needs you has become, 1 to 4, by how long it has
  waited. 0 for a session that does not need you.
  """
  def urgency(%{status: :needs} = session, now) do
    waited = seconds_since(session[:since] || session[:waiting_since], now) || 0
    1 + Enum.count(@urgency_steps, &(waited >= &1))
  end

  def urgency(_session, _now), do: 0

  @doc "Whole days an idle session has been quiet, for the cobwebs. 0 when unknown."
  def quiet_days(session, now), do: div(quiet_seconds(session, now) || 0, @day)

  defp quiet_seconds(session, now),
    do: seconds_since(session[:updated_at] || session[:since] || session[:started_at], now)

  defp seconds_since(%DateTime{} = at, now), do: max(DateTime.diff(now, at, :second), 0)
  defp seconds_since(_, _now), do: nil

  @doc """
  The project a session belongs to: its repository's name, else the project
  folder its path is in. A worktree counts as its project, not as itself.
  """
  def crew(session) do
    cond do
      present?(session[:repo]) -> session.repo
      present?(session[:cwd]) -> project_folder(session.cwd)
      present?(session[:folder]) -> session.folder
      true -> "somewhere"
    end
  end

  # /x/kyroco-main/.claude/worktrees/eager-shirley -> kyroco-main
  defp project_folder(cwd) do
    cwd
    |> String.split("/.claude/worktrees/")
    |> hd()
    |> Path.basename()
  end

  @doc """
  What its speech bubble says: the question it asked when it needs you,
  what it is on when it works. Nothing for the rest; the browser fills the
  quiet with jokes of its own.
  """
  def says(%{status: :needs} = session),
    do: clip(session[:why] || "Waiting on you", @bubble_chars)

  def says(%{status: :working} = session) do
    if place_only?(session), do: nil, else: clip(session[:task], @bubble_chars)
  end

  def says(_session), do: nil

  # With no step to show, a card's task is only where the session runs:
  # its folder, or the last part of its path. That is not news.
  defp place_only?(%{task: task} = session) when is_binary(task) do
    task == session[:folder] or
      (is_binary(session[:cwd]) and String.ends_with?(session.cwd, "/" <> task))
  end

  defp place_only?(_session), do: true

  @doc """
  The short name under its feet: its issue when the board found one, else
  an issue its name starts with (`KOR-629 Dev seed` is `KOR-629`), else its
  name, cut short.
  """
  def tag(session) do
    name = session[:name] || "unnamed"

    cond do
      is_binary(session[:issue]) -> session.issue
      is_integer(session[:issue]) -> "##{session.issue}"
      found = Regex.run(~r/\A(#\d+|[A-Z][A-Z0-9]{1,9}-\d+)\b/, name) -> hd(found)
      true -> clip(name, @tag_chars)
    end
  end

  @doc """
  Everyone on the floor, as the plain maps the browser draws: needs-you
  first, loudest first, then each crew with its foreman ahead of its
  workers. `details` is the usage reader's facts by session id, for the
  helpers (subagents) running around a desk.
  """
  def cast(sessions, now, details \\ %{}) do
    sessions
    |> Enum.map(&member(&1, now, details))
    |> Enum.sort_by(&{-&1.urgency, &1.crew, if(&1.role == "foreman", do: 0, else: 1), &1.name})
  end

  defp member(session, now, details) do
    mood = mood(session, now)
    detail = session[:detail] || details[session[:session_id]]

    %{
      key: session[:key] || session[:session_id] || session[:name],
      name: session[:name] || "unnamed",
      tag: tag(session),
      role: Atom.to_string(role(session)),
      mood: Atom.to_string(mood),
      urgency: urgency(session, now),
      crew: crew(session),
      says: says(session) || helper_says(session, detail),
      tool: if(session[:tool] in [:codex, "codex"], do: "codex", else: "claude"),
      # Working past the long-running limit in settings: it sweats.
      long: session[:long?] == true,
      # Its machine's collector is not connected: it is drawn as a ghost.
      ghost: session[:stale] == true,
      days: if(mood in [:asleep, :packed], do: quiet_days(session, now), else: 0),
      helpers: detail |> running_helpers() |> length() |> min(3)
    }
  end

  # The helpers (subagents) running right now. Three at most are drawn.
  defp running_helpers(%{subagents: subs}) when is_list(subs),
    do: Enum.filter(subs, &(&1[:running] == true))

  defp running_helpers(_), do: []

  # A working session with no step of its own says what its helper is on.
  defp helper_says(%{status: :working}, detail) do
    case Enum.find(running_helpers(detail), &is_binary(&1[:description])) do
      nil -> nil
      helper -> clip("Helper: " <> helper.description, @bubble_chars)
    end
  end

  defp helper_says(_session, _detail), do: nil

  @doc """
  The words for the talk box: what it is doing and for how long, in plain
  English.
  """
  def status_line(session, now) do
    case mood(session, now) do
      :needs ->
        "Needs you. Waiting #{span(session[:since] || session[:waiting_since], now)}."

      :working ->
        "Working for #{span(session[:since], now)}."

      :wandering ->
        "Idle. Last heard from #{span(session[:updated_at], now)} ago."

      :asleep ->
        "Asleep. Nothing for #{days_word(quiet_days(session, now))}. Did you forget it?"

      :packed ->
        "Packed and ready to archive. Nothing for #{days_word(quiet_days(session, now))}."
    end
  end

  defp days_word(1), do: "1 day"
  defp days_word(n), do: "#{n} days"

  defp span(at, now) do
    case seconds_since(at, now) do
      nil -> "a while"
      s when s < 60 -> "#{s}s"
      s when s < 3600 -> "#{div(s, 60)}m"
      s when s < @day -> "#{div(s, 3600)}h #{rem(div(s, 60), 60)}m"
      s -> days_word(div(s, @day))
    end
  end

  @doc """
  A made-up floor with one of everything, for looking at every behavior
  without waiting for a real session to need you. The board shows it at
  /?floor=demo and never mixes it with real sessions.
  """
  def demo(now) do
    ago = fn secs -> DateTime.add(now, -secs, :second) end

    [
      demo_one("Foreman billing extraction", "kyroco-main", :working, ago.(1500),
        task: "Checking PR 3121 against the plan",
        folder: "foreman-billing-b9914b"
      ),
      demo_one("KOR-629 Dev seed in its own image", "kyroco-main", :working, ago.(400),
        task: "Running the tests again",
        issue: "KOR-629",
        detail: %{subagents: [%{running: true}, %{running: true}]}
      ),
      demo_one("KOR-630 Walk-throughs into dev tools", "kyroco-main", :needs, ago.(45),
        why: "May I delete the old seed files?",
        issue: "KOR-630"
      ),
      demo_one("KOR-566 Plan catalog into billing", "kyroco-main", :needs, ago.(400),
        why: "A permission prompt is waiting for your approval",
        issue: "KOR-566"
      ),
      demo_one("KOR-633 Browser walks of the extra apps", "kyroco-main", :working, ago.(9000),
        task: "Fixing the last failing browser walk",
        issue: "KOR-633",
        long?: true
      ),
      demo_one("KOR-634 Invites billing into billing", "kyroco-main", :idle, ago.(1200),
        issue: "KOR-634"
      ),
      demo_one("KOR-635 Front Desk billing actions", "kyroco-main", :idle, ago.(3 * @day),
        issue: "KOR-635"
      ),
      demo_one("Foreman of the board", "vitalaize", :needs, ago.(2400),
        why: "Two workers want the same file. Who goes first?"
      ),
      demo_one("Agent map animated tab", "vitalaize", :working, ago.(700),
        task: "Drawing tiny people",
        issue: 181
      ),
      demo_one("Codex: tidy the release script", "vitalaize", :working, ago.(200),
        task: "Reading macos/build.sh",
        tool: :codex
      ),
      demo_one("Old spike on components", "vitalaize", :idle, ago.(9 * @day), []),
      demo_one("Flaky test hunt", "vitalaize", :idle, ago.(12 * @day), tool: :codex),
      demo_one("Docs pass on another Mac", "korium-docs", :working, ago.(5000),
        task: "Rewriting the install page",
        stale: true
      ),
      demo_one("Home page copy", "korium-docs", :idle, ago.(300), [])
    ]
  end

  defp demo_one(name, repo, status, at, more) do
    Map.merge(
      %{
        key: "demo:" <> name,
        session_id: nil,
        name: name,
        short_id: "demo",
        account: nil,
        folder: repo,
        cwd: nil,
        repo: repo,
        status: status,
        task: nil,
        why: nil,
        since: at,
        updated_at: at,
        started_at: at,
        tool: :claude,
        demo: true
      },
      Map.new(more)
    )
  end

  defp clip(nil, _max), do: nil

  defp clip(text, max) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(text) > max,
      do: String.trim_trailing(String.slice(text, 0, max - 1)) <> "…",
      else: text
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
