defmodule Wallboard.Archive.StatusRecorder do
  @moduledoc """
  Saves each Claude session's status history: when it started working,
  needed you, went idle, and left `claude agents` ("gone"). Transcripts do
  not record waiting on a person, so this is the only place that history
  comes from.

  It listens to the board's own session checks, so it adds no polling.
  """

  use GenServer

  alias Wallboard.Archive.Collector
  alias Wallboard.Store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Wallboard.PubSub, Wallboard.Poller.topic())
    {:ok, %{last: nil, machine: Collector.machine(Wallboard.Settings.get())}}
  end

  @impl true
  def handle_info({:source, :claude, %{sessions: sessions}, _meta}, state) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    {events, current} = changes(state.last || %{}, sessions)

    Enum.each(events, fn {id, name, status} ->
      Store.put_status(state.machine, id, name, status, now)
    end)

    {:noreply, %{state | last: current}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @doc """
  Compares the last statuses (%{session_id => {name, status}}) with the
  sessions seen now. Returns {[{id, name, status}], current}.
  """
  def changes(last, sessions) do
    current =
      for s <- sessions, s.session_id, into: %{}, do: {s.session_id, {s.name, s.status}}

    changed =
      for {id, {name, status}} <- current,
          last[id] == nil or elem(last[id], 1) != status,
          do: {id, name, status}

    gone = for {id, {name, _}} <- last, not Map.has_key?(current, id), do: {id, name, :gone}

    {changed ++ gone, current}
  end
end
