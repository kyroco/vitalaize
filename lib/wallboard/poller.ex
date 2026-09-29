defmodule Wallboard.Poller do
  @moduledoc """
  Polls one data source on an interval and tells the board only when
  something changed.

  The fetch runs in its own supervised task, so a hung or crashing command
  never blocks or kills the poller. When a fetch fails, the last good data
  stays on the board, marked stale with the reason, and the next poll tries
  again.

  A source is a module with:

    * `poll(settings, prev_facts, memory, now)` returning
      `{:ok, facts, memory}` or `{:error, reason, memory}`
    * `fingerprint(facts)`, the part of the facts that counts as a change
  """

  use GenServer
  require Logger

  @topic "board"

  def topic, do: @topic

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  def child_spec(opts) do
    %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The latest facts and their age, or an empty snapshot if the poller is down."
  def snapshot(name) do
    GenServer.call(name, :snapshot, 2_000)
  catch
    :exit, _ -> %{facts: nil, meta: %{fetched_at: nil, error: "not running", interval: nil}}
  end

  @doc "True when two fact sets differ in a way the board shows. Tested directly."
  def changed?(source, old, new) do
    old == nil or source.fingerprint(old) != source.fingerprint(new)
  end

  @impl true
  def init(opts) do
    source = Keyword.fetch!(opts, :source)
    interval = Keyword.fetch!(opts, :interval_ms)

    state = %{
      name: Keyword.fetch!(opts, :name),
      source: source,
      interval: interval,
      timeout: Keyword.get(opts, :timeout_ms, max(interval * 3, 60_000)),
      facts: nil,
      memory: nil,
      fetched_at: nil,
      error: nil,
      task: nil
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{facts: state.facts, meta: meta(state)}, state}
  end

  @impl true
  def handle_info(:poll, %{task: nil} = state) do
    %{source: source, facts: facts, memory: memory} = state
    settings = Wallboard.Settings.get()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    task =
      Task.Supervisor.async_nolink(Wallboard.TaskSupervisor, fn ->
        source.poll(settings, facts, memory, now)
      end)

    Process.send_after(self(), {:timeout, task.ref}, state.timeout)
    {:noreply, %{state | task: task}}
  end

  # A poll is still running; skip this turn.
  def handle_info(:poll, state) do
    schedule(state)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    state =
      case result do
        {:ok, facts, memory} ->
          changed? = changed?(state.source, state.facts, facts)

          state = %{
            state
            | facts: facts,
              memory: memory,
              fetched_at: DateTime.utc_now(),
              error: nil
          }

          broadcast(state, changed?)
          state

        {:error, reason, memory} ->
          Logger.warning("#{inspect(state.name)} poll failed: #{reason}")
          state = %{state | memory: memory || state.memory, error: reason}
          broadcast(state, false)
          state
      end

    schedule(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning(
      "#{inspect(state.name)} poll crashed: #{Exception.format_exit(reason) |> String.slice(0, 300)}"
    )

    state = %{state | task: nil, error: "the last check crashed; retrying"}
    broadcast(state, false)
    schedule(state)
    {:noreply, state}
  end

  def handle_info({:timeout, ref}, %{task: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    state = %{state | task: nil, error: "the last check took too long; retrying"}
    broadcast(state, false)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Never print facts or memory in a crash report.
  @impl true
  def format_status(status),
    do: Map.update(status, :state, nil, &Map.take(&1, [:name, :error, :fetched_at]))

  defp schedule(state), do: Process.send_after(self(), :poll, state.interval)

  defp meta(state),
    do: %{fetched_at: state.fetched_at, error: state.error, interval: state.interval}

  # Every poll sends the small "how old is this" update; the facts go out
  # only when they changed.
  defp broadcast(state, changed?) do
    message =
      if changed?,
        do: {:source, state.name, state.facts, meta(state)},
        else: {:source_meta, state.name, meta(state)}

    Phoenix.PubSub.broadcast(Wallboard.PubSub, @topic, message)
  end
end
