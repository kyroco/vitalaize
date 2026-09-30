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

  Each status carries the collector's clock time (`at`, milliseconds), and
  an older status never overrides a newer one: the hooks run in the
  background, so "waiting" and "done waiting" can reach the hub out of
  order. A session that says nothing for a day is dropped, so a
  collector that went to sleep mid-wait does not leave a card up forever.
  Nothing is written to disk: after the hub restarts, a session shows again
  the next time it starts waiting.
  """

  use GenServer

  @max_age_ms 24 * 3600 * 1000
  @sweep_ms 60_000
  @why_max 240

  @waiting_notices ~w(permission_prompt elicitation_dialog elicitation_url_dialog agent_needs_input)
  @done_notices ~w(elicitation_complete elicitation_response)

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
    with sid when is_binary(sid) <- hook["session_id"] || {:error, "no session_id"},
         true <- sid =~ ~r/^[A-Za-z0-9-]{1,64}$/ || {:error, "bad session_id"} do
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
         why: why && String.slice(why, 0, @why_max),
         folder: folder(hook["cwd"])
       }}
    end
  end

  def event(_, _, _, _), do: {:error, "expected a JSON object and a time"}

  defp waiting(%{"hook_event_name" => "Notification"} = hook) do
    case hook["notification_type"] do
      type when type in @waiting_notices -> {true, text(hook["message"]) || "Waiting on you"}
      type when type in @done_notices -> {false, nil}
      _ -> {nil, nil}
    end
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

  defp folder(cwd) when is_binary(cwd) and cwd != "", do: Path.basename(cwd)
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

      prev && prev.at > event.at ->
        {state, :same}

      (event.waiting? and prev) && prev.waiting? ->
        {Map.put(state, event.key, %{prev | at: event.at, received: event.received}), :same}

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
    {:ok, %{}}
  end

  @impl true
  def handle_call({:report, event}, _from, state) do
    {state, what} = apply_event(state, event, local?(event))

    if what == :started do
      [session] = board_sessions(%{event.key => state[event.key]})
      settings = Wallboard.Settings.get()

      Wallboard.Alerts.needs_you(
        [%{session | name: "#{session.name} on #{event.machine}"}],
        settings
      )
    end

    if what in [:started, :changed], do: broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:sessions, _from, state), do: {:reply, board_sessions(state), state}

  @impl true
  def handle_info(:sweep, state) do
    {state, changed?} = sweep(state, System.os_time(:millisecond))
    if changed?, do: broadcast(state)
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
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
