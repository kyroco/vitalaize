defmodule Wallboard.Link.Sessions do
  @moduledoc """
  What the hub does with the events collectors stream to it (see
  `Wallboard.Link`): it shows each remote session live on the board, and
  saves it in the archive.

  `Wallboard.Link.Hub` saves every event as it arrives and says so on the
  `"link"` topic. This process hears that, and keeps one
  `Wallboard.Link.Session` for each session it has heard from lately.

  ## Live

  A session that has said how it is doing, and has not ended, has a card on
  the Live tab like the hub's own sessions: working, waiting or idle, with
  its context, model, cost, lines and its machine's name. The cards go to
  the board as `{:stream, cards}` on the board's topic.

  When a session starts waiting on its person, one alert goes out on every
  channel that is set up. Like the board's own check, the alert waits
  `claude.poll_seconds` and is not sent if the session moved on first.
  Each wait alerts once, told apart by when it began. At most 20 alerts go
  out in 10 minutes from other machines.

  A machine whose stream is closed keeps its cards, marked stale, with the
  status they had: the hub does not know what happened since, and says so.
  They are live again when the machine is back. A machine gone for a day
  has its cards taken down.

  A collector says every live session's status again each time it
  connects. So a hub that restarted or lost its data has its cards back
  once the machine is.

  Only a collector ends a session. The hub never guesses that one is
  over: a session whose collector lost its own place, and so never said
  it ended, keeps its card until that machine has been disconnected for a
  day.

  A wait's alert is sent even if its machine's stream has closed by the
  time the alert is due. A machine that also runs the old upload hooks
  has those stand aside while its stream is open (`live?/1`); should the
  stream close in the moment between, both can alert for the one wait.

  ## Saved

  Every few seconds, each session that changed is saved as the same rows
  the transcript reader builds (`sessions` and `requests`), under the
  machine named by the collector's certificate, and each status change as
  a row in `status_events`. So Archive and Trends count a remote session
  like a local one. Saving a session removes the copies of it that came as
  uploaded transcripts, and the upload path leaves a streamed session
  alone, so a session that arrives both ways is counted once.

  ## A restart

  Nothing here is the only copy: the events are in the database. On start
  the sessions heard from in the last 12 hours are read back and saved
  again, so a hub that stopped between an event and its save catches up.
  No alert is sent for what is read back.
  """

  use GenServer
  require Logger

  alias Wallboard.Collector.Proto
  alias Wallboard.Link.Session
  alias Wallboard.Store

  @topic "link"
  @save_ms 3_000
  @publish_ms 200
  @load_seconds 12 * 3600
  # A session that is not live leaves memory this long after its last event.
  @keep_seconds 10 * 60
  # A stale card comes down after this long.
  @stale_seconds 24 * 3600

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The live cards of sessions on other machines, for the board."
  def cards do
    GenServer.call(__MODULE__, :cards, 2_000)
  catch
    :exit, _ -> []
  end

  @doc "True when a collector's stream reports this session as live."
  def live?(session_id) do
    GenServer.call(__MODULE__, {:live?, session_id}, 2_000)
  catch
    :exit, _ -> false
  end

  @doc "Saves every session that changed, now. It happens by itself every few seconds."
  def save, do: GenServer.call(__MODULE__, :save, 60_000)

  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Wallboard.PubSub, @topic)
    now = System.os_time(:second)

    state = %{
      # {machine, session id} => %{s: session, dirty?: bool, heard: seconds}
      # `heard` is when any event last came.
      sessions: %{},
      connected: connected(),
      # machine => when its stream closed
      down: %{},
      started: now,
      # {machine, session id} => the start of the wait an alert was last
      # asked for, so no wait alerts twice
      alerted: %{},
      sent: [],
      publish: nil,
      save_ms: Keyword.get(opts, :save_ms, @save_ms),
      alerts: Keyword.get(opts, :alerts, &Wallboard.Alerts.needs_you/2)
    }

    Process.send_after(self(), :save, state.save_ms)
    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    now = System.os_time(:second)

    sessions =
      for %{machine: machine, session_id: id} <- Store.collector_sessions(now - @load_seconds),
          into: %{} do
        {{machine, id}, %{s: read(machine, id), dirty?: true, heard: now}}
      end

    # A wait that was on before the hub stopped has had its alert.
    alerted =
      for {key, %{s: s}} <- sessions, Session.waiting?(s), into: %{}, do: {key, Session.since(s)}

    {:noreply, publish(%{state | sessions: sessions, alerted: alerted})}
  rescue
    e ->
      Logger.warning("Link: could not read saved events back: " <> Exception.message(e))
      {:noreply, state}
  catch
    :exit, _ ->
      Logger.warning("Link: could not read saved events back: the database did not answer")
      {:noreply, state}
  end

  @impl true
  def handle_call(:cards, _from, state), do: {:reply, build_cards(state), state}

  # Live, and its machine's stream open: a collector that is cut off
  # reports nothing, so its word no longer stands in for anyone else's.
  def handle_call({:live?, id}, _from, state) do
    live? =
      Enum.any?(state.sessions, fn {{machine, sid}, e} ->
        sid == id and Session.live?(e.s) and MapSet.member?(state.connected, machine)
      end)

    {:reply, live?, state}
  end

  def handle_call(:save, _from, state), do: {:reply, :ok, save_changed(state)}

  @impl true
  def handle_info({:link, :events, machine, rows}, state) do
    now = System.os_time(:second)
    events = Enum.flat_map(rows, &decode/1)

    state =
      events
      |> Enum.group_by(& &1.session_id)
      |> Enum.reduce(state, fn {id, events}, state ->
        key = {machine, id}
        # A session not in memory is read from the database, which already
        # holds these events.
        entry = state.sessions[key] || %{s: read(machine, id)}
        s = Enum.reduce(events, entry.s, &take(&2, &1))
        record_statuses(s, events)
        state = maybe_alert(state, key, s)
        put_in(state.sessions[key], %{s: s, dirty?: true, heard: now})
      end)

    {:noreply, publish(state)}
  end

  def handle_info({:link, :up, machine}, state) do
    state = %{state | connected: MapSet.put(state.connected, machine)}
    {:noreply, publish(state)}
  end

  def handle_info({:link, :down, machine}, state) do
    state = %{
      state
      | connected: MapSet.delete(state.connected, machine),
        down: Map.put(state.down, machine, System.os_time(:second))
    }

    {:noreply, publish(state)}
  end

  def handle_info(:publish, state) do
    Phoenix.PubSub.broadcast(
      Wallboard.PubSub,
      Wallboard.Poller.topic(),
      {:stream, build_cards(state)}
    )

    {:noreply, %{state | publish: nil}}
  end

  def handle_info(:save, state) do
    Process.send_after(self(), :save, state.save_ms)
    {:noreply, state |> save_changed() |> tidy()}
  end

  # The alert for a wait that began at `since`, sent only if that same wait
  # is still on, whether or not its machine's stream is still open.
  def handle_info({:alert, key, since}, state) do
    {machine, _} = key

    with %{s: s} <- state.sessions[key],
         true <- Session.waiting?(s) and Session.since(s) == since do
      {ok?, sent} =
        Wallboard.Remote.alert_allowed?(state.sent, System.os_time(:millisecond))

      name = "#{Session.name(s)} on #{machine}"

      if ok? do
        card = Session.card(s, true, %{})
        state.alerts.([%{card | name: name}], Wallboard.Settings.get())
      else
        Logger.warning("Too many alerts from other machines; not sent: #{name} needs you")
      end

      {:noreply, %{state | sent: sent}}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  # Never print sessions in a crash report: they hold prompts and titles.
  @impl true
  def format_status(status) do
    status
    |> Map.update(:state, nil, &Map.take(&1, [:connected]))
    |> Map.replace(:message, :not_shown)
    |> Map.replace(:log, [])
  end

  # ---------------------------------------------------------------------------

  defp connected do
    Wallboard.Link.Hub.connected() |> Map.keys() |> MapSet.new()
  catch
    :exit, _ -> MapSet.new()
  end

  defp decode(%{event: event}) do
    [Proto.Event.decode(event)]
  rescue
    _ -> []
  end

  defp read(machine, id) do
    machine
    |> Store.collector_events(id)
    |> Enum.flat_map(&decode/1)
    |> Enum.reduce(Session.new(machine, id), &take(&2, &1))
  end

  # Each status a collector sent, and each end, as the archive words them.
  # A row sent again lands on the one already there.
  defp record_statuses(s, events) do
    name = Session.name(s)

    for %Proto.Event{file: ""} = event <- events, %Proto.Item{body: body} <- event.items do
      case body do
        {:status, %Proto.Status{state: state}} ->
          word =
            case state do
              :WAITING -> :needs
              :WORKING -> :working
              _ -> :idle
            end

          Store.put_status(s.machine, s.session_id, name, word, event.at)

        {:ended, _} ->
          Store.put_status(s.machine, s.session_id, name, :gone, event.at)

        _ ->
          :ok
      end
    end
  end

  # One alert for each wait: asked for when a session waits and no alert
  # was asked for that wait yet (a wait is known by when it began), and
  # sent a little later if that same wait is still on.
  defp maybe_alert(state, key, s) do
    since = Session.waiting?(s) && Session.since(s)

    if since && state.alerted[key] != since do
      delay = Wallboard.Settings.get().claude.poll_seconds * 1000
      Process.send_after(self(), {:alert, key, since}, delay)
      %{state | alerted: Map.put(state.alerted, key, since)}
    else
      state
    end
  end

  # One event that cannot be taken in costs that event, not the hub.
  defp take(s, event) do
    Session.apply(s, event)
  rescue
    _ -> s
  end

  defp publish(%{publish: nil} = state),
    do: %{state | publish: Process.send_after(self(), :publish, @publish_ms)}

  defp publish(state), do: state

  defp build_cards(state) do
    prices = Wallboard.Settings.get().usage.prices
    now = System.os_time(:second)

    state.sessions
    |> Enum.flat_map(fn {{machine, _}, %{s: s}} ->
      connected? = MapSet.member?(state.connected, machine)
      down = gone_since(state, machine, s)

      # A machine gone for a day has its cards taken down.
      if connected? or now - down < @stale_seconds,
        do: card(s, connected?, prices, down),
        else: []
    end)
    |> Enum.sort_by(& &1.key)
  end

  # When the hub last had word from a machine that is not connected: when
  # its stream closed, or, for one not seen since the hub started, the
  # time of the last thing its session said.
  defp gone_since(state, machine, s),
    do: Map.get(state.down, machine) || Session.last_at(s) || state.started

  defp card(s, connected?, prices, down) do
    List.wrap(Session.card(s, connected?, prices, down))
  rescue
    _ -> []
  end

  defp save_changed(state) do
    prices = Wallboard.Settings.get().usage.prices
    now = System.os_time(:second)

    {sessions, saved} =
      Enum.reduce(state.sessions, {state.sessions, 0}, fn
        {key, %{dirty?: true, s: s} = entry}, {sessions, saved} ->
          case record(s, prices, now) do
            nil ->
              {Map.put(sessions, key, %{entry | dirty?: false}), saved}

            {session, requests} ->
              # A save the database refused is tried again next time.
              if Store.put_session(session, requests) == :ok,
                do: {Map.put(sessions, key, %{entry | dirty?: false}), saved + 1},
                else: {sessions, saved}
          end

        _, acc ->
          acc
      end)

    if saved > 0 do
      Phoenix.PubSub.broadcast(Wallboard.PubSub, Wallboard.Poller.topic(), {:archive, :stream})
    end

    %{state | sessions: sessions}
  end

  defp record(s, prices, now) do
    Session.record(s, prices, now)
  rescue
    e ->
      Logger.warning("Link: could not save a session: " <> Exception.message(e))
      nil
  end

  # Sessions that are saved and no longer live leave memory after a while.
  # They are read back from the database if their collector says more. A
  # session whose machine has been gone a day leaves too.
  defp tidy(state) do
    now = System.os_time(:second)

    sessions =
      Map.reject(state.sessions, fn {{machine, _}, e} ->
        gone? =
          not MapSet.member?(state.connected, machine) and
            now - gone_since(state, machine, e.s) >= @stale_seconds

        not e.dirty? and now - e.heard >= @keep_seconds and (gone? or not Session.live?(e.s))
      end)

    %{state | sessions: sessions, alerted: Map.take(state.alerted, Map.keys(sessions))}
  end
end
