defmodule Wallboard.Remote do
  @moduledoc """
  Claude sessions on other machines (collectors) that are waiting on you.

  A collector sends its transcripts only when a turn ends, which is too late
  to say a session is waiting. So the upload script also runs from Claude
  Code's Notification, PreToolUse (AskUserQuestion), PostToolUse and
  UserPromptSubmit hooks, and posts a small status to /ingest/status the
  moment a session starts or stops waiting. This keeps those statuses, puts
  the waiting ones on the board beside this machine's own sessions, and
  sends one alert on every channel when one starts waiting.

  What counts as waiting, matching the local board: a permission prompt, a
  question from AskUserQuestion, an MCP server asking for input, or a
  subagent that needs input. Claude's "idle for a minute" reminder is not,
  since a finished turn is idle on the local board too.

  The card shows as soon as the status arrives. The alert waits as long as
  the board's own session check does (claude.poll_seconds), and is not sent
  if the session moves on first, so a prompt answered at once never buzzes
  a phone, as on the local board.

  Each status carries the collector's clock time (`at`, milliseconds), and
  an older status never overrides a newer one: the hooks run in the
  background, so "waiting" and "done waiting" can reach the hub out of
  order. When both carry the same time, "done waiting" wins. A session
  that says nothing for a day is dropped, so a
  collector that went to sleep mid-wait does not leave a card up forever.
  Nothing is written to disk: after the hub restarts, a session shows again
  the next time it starts waiting.

  Anyone with the ingest key can post here, so what is kept has limits: at
  most 1,000 sessions (the least recently heard from go first), short
  texts, and at most 20 alerts in 10 minutes from other machines, with a
  log line for each alert left out.
  """

  use GenServer
  require Logger

  @max_age_ms 24 * 3600 * 1000
  @sweep_ms 60_000
  @why_max 240
  @text_bytes 1_000
  @max_entries 1000
  @alert_window_ms 10 * 60 * 1000
  @max_alerts 20

  @waiting_notices ~w(permission_prompt elicitation_dialog elicitation_url_dialog agent_needs_input)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Takes one status from a collector: the Claude hook's JSON (already
  decoded), the machine and account it came from, and the collector's
  time. Returns :ok, or {:error, reason} for a status it cannot read.
  """
  def report(hook, machine, account, at) do
    with {:ok, event} <- event(hook, machine, account, at) do
      event = %{event | received: System.os_time(:millisecond)}
      GenServer.call(__MODULE__, {:report, event}, 5_000)
    end
  catch
    :exit, _ -> {:error, "the board is not keeping statuses right now"}
  end

  @doc "The waiting sessions from other machines, shaped like the board's own."
  def sessions do
    GenServer.call(__MODULE__, :sessions, 2_000)
  catch
    :exit, _ -> []
  end

  # ---------------------------------------------------------------------------
  # Reading a hook (pure)

  @doc """
  Turns a hook's JSON into {:ok, %{key, machine, account, session_id, at,
  received, waiting?, why, folder}} or {:error, reason}. `waiting?` is nil
  for a hook that says nothing about waiting (such as Claude's idle
  reminder). `at` is the collector's clock, used only to order one
  session's statuses; `received` is this machine's clock, used for "waiting
  for" and for dropping old entries, so a collector whose clock is off
  still shows the right times.
  """
  def event(%{} = hook, machine, account, at) when is_integer(at) do
    with {:ok, sid} <- session_id(hook["session_id"]) do
      {waiting?, why} = waiting(hook)

      {:ok,
       %{
         key: Enum.join([machine, account, sid], ":"),
         machine: machine,
         account: account,
         session_id: sid,
         at: at,
         received: at,
         waiting?: waiting?,
         why: why && clip(why, @why_max),
         folder: folder(hook["cwd"])
       }}
    end
  end

  def event(_, _, _, _), do: {:error, "expected a JSON object and a time"}

  defp session_id(sid) when is_binary(sid) do
    if sid =~ ~r/\A[A-Za-z0-9-]{1,64}\z/, do: {:ok, sid}, else: {:error, "bad session_id"}
  end

  defp session_id(nil), do: {:error, "no session_id"}
  defp session_id(_), do: {:error, "bad session_id"}

  defp waiting(%{"hook_event_name" => "Notification"} = hook) do
    if hook["notification_type"] in @waiting_notices,
      do: {true, text(hook["message"]) || "Waiting on you"},
      else: {nil, nil}
  end

  defp waiting(%{"hook_event_name" => "PreToolUse", "tool_name" => "AskUserQuestion"} = hook),
    do: {true, question(hook["tool_input"]) || "It asked you a question"}

  defp waiting(%{"hook_event_name" => "PreToolUse"}), do: {nil, nil}

  defp waiting(%{"hook_event_name" => event})
       when event in ~w(PostToolUse UserPromptSubmit Stop SessionEnd),
       do: {false, nil}

  defp waiting(_), do: {nil, nil}

  defp question(%{"questions" => [%{"question" => q} | _]}), do: text(q)
  defp question(_), do: nil

  defp text(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      t -> t
    end
  end

  defp text(_), do: nil

  # Sender's text kept to one short line: no control characters (a newline
  # would forge a log line), at most `max` characters and @text_bytes bytes.
  defp clip(s, max) do
    s
    |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ")
    |> String.slice(0, max)
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn g, {acc, n} ->
      n = n + byte_size(g)
      if n > @text_bytes, do: {:halt, {acc, n}}, else: {:cont, {[g | acc], n}}
    end)
    |> then(fn {acc, _} -> acc |> Enum.reverse() |> IO.iodata_to_binary() end)
  end

  defp folder(cwd) when is_binary(cwd) and cwd != "" do
    case cwd |> Path.basename() |> clip(64) |> String.trim() do
      "" -> nil
      name -> name
    end
  end

  defp folder(_), do: nil

  # ---------------------------------------------------------------------------
  # Keeping them (pure)

  @doc """
  Applies one event to the state (%{key => entry}). Returns {state, what}:
  :started when a session newly waits (send an alert), :changed when the
  board should redraw, :same otherwise. `local?` is true when the session
  is this machine's own, which the board already watches.
  """
  def apply_event(state, event, local?) do
    prev = Map.get(state, event.key)

    cond do
      local? ->
        {state, :same}

      event.waiting? == nil ->
        {state, :same}

      prev && (prev.at > event.at or (prev.at == event.at and event.waiting?)) ->
        {state, :same}

      # Still waiting, perhaps on a new question: show its words, keep the
      # time the waiting began, and send no second alert.
      (event.waiting? and prev) && prev.waiting? ->
        entry = %{prev | at: event.at, received: event.received, why: event.why}
        {Map.put(state, event.key, entry), if(event.why == prev.why, do: :same, else: :changed)}

      event.waiting? ->
        {Map.put(state, event.key, Map.put(event, :since, event.received)), :started}

      prev && prev.waiting? ->
        {Map.put(state, event.key, %{
           prev
           | at: event.at,
             received: event.received,
             waiting?: false
         }), :changed}

      true ->
        # Kept only so an older "waiting" that arrives later is ignored.
        {Map.put(state, event.key, %{event | why: nil} |> Map.put(:since, nil)), :same}
    end
  end

  @doc "Drops entries not heard from within the day. Returns {state, changed?}."
  def sweep(state, now_ms) do
    kept = Map.reject(state, fn {_, e} -> now_ms - e.received > @max_age_ms end)
    {kept, Enum.any?(Map.keys(state) -- Map.keys(kept), &state[&1].waiting?)}
  end

  @doc "Keeps at most `max` entries, dropping the least recently heard from."
  def cap(state, max \\ @max_entries) do
    if map_size(state) <= max,
      do: state,
      else: state |> Enum.sort_by(fn {_, e} -> -e.received end) |> Enum.take(max) |> Map.new()
  end

  @doc """
  Whether another alert may go out at `now` given the times of the ones
  sent (newest first). Returns {ok?, times to keep}.
  """
  def alert_allowed?(sent, now, max \\ @max_alerts) do
    recent = Enum.take_while(sent, &(now - &1 < @alert_window_ms))
    if length(recent) < max, do: {true, [now | recent]}, else: {false, recent}
  end

  @doc "The waiting entries as board sessions, needs-you first by how long."
  def board_sessions(state) do
    for {_, e} <- state, e.waiting? do
      since = DateTime.from_unix!(e.since, :millisecond) |> DateTime.truncate(:second)

      where =
        if e.account in [nil, "", "main"], do: e.machine, else: "#{e.machine} · #{e.account}"

      %{
        key: "remote:" <> e.key,
        session_id: e.session_id,
        name: e.folder || String.slice(e.session_id, 0, 8),
        short_id: String.slice(e.session_id, 0, 8),
        account: where,
        machine: e.machine,
        kind: "remote",
        folder: nil,
        status: :needs,
        task: nil,
        why: e.why,
        waiting_since: since,
        since: since,
        updated_at: since,
        started_at: since,
        tool: :claude
      }
    end
    |> Enum.sort_by(&DateTime.to_unix(&1.since))
  end

  # ---------------------------------------------------------------------------
  # Server

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{entries: %{}, sent: []}}
  end

  @impl true
  def handle_call({:report, event}, _from, %{entries: entries} = state) do
    {entries, what} = apply_event(entries, event, event.waiting? != nil and local?(event))
    entries = cap(entries)

    if what == :started and Map.has_key?(entries, event.key) do
      delay = Wallboard.Settings.get().claude.poll_seconds * 1000
      Process.send_after(self(), {:alert, event.key, entries[event.key].since}, delay)
    end

    if what in [:started, :changed], do: broadcast(entries)
    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call(:sessions, _from, state), do: {:reply, board_sessions(state.entries), state}

  # The alert for a wait that began at `since`, sent only if that same wait
  # is still on.
  @impl true
  def handle_info({:alert, key, since}, state) do
    case state.entries[key] do
      %{waiting?: true, since: ^since} = entry ->
        {ok?, sent} = alert_allowed?(state.sent, System.os_time(:millisecond))
        [session] = board_sessions(%{key => entry})
        name = "#{session.name} on #{entry.machine}"

        if ok?,
          do: Wallboard.Alerts.needs_you([%{session | name: name}], Wallboard.Settings.get()),
          else: Logger.warning("Too many alerts from other machines; not sent: #{name} needs you")

        {:noreply, %{state | sent: sent}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:sweep, state) do
    {entries, changed?} = sweep(state.entries, System.os_time(:millisecond))
    if changed?, do: broadcast(entries)
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, %{state | entries: entries}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # Never print what sessions asked in a crash report.
  @impl true
  def format_status(status), do: Map.put(status, :state, :hidden)

  # This machine's own sessions come from `claude agents`, never from here:
  # by machine name, or by a session the local check already shows.
  defp local?(event) do
    settings = Wallboard.Settings.get()

    event.machine == Wallboard.Archive.Collector.machine(settings) or
      event.session_id in local_session_ids()
  end

  defp local_session_ids do
    case Wallboard.Poller.snapshot(:claude) do
      %{facts: %{sessions: sessions}} -> Enum.map(sessions, & &1.session_id)
      _ -> []
    end
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      Wallboard.PubSub,
      Wallboard.Poller.topic(),
      {:remote, board_sessions(state)}
    )
  end
end
