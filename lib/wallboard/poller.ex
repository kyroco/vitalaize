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

  # The poller's state. It never prints its facts or memory: a crash report
  # lists a failed call's arguments, the state among them, and the facts
  # can hold issue text.
  @derive {Inspect, except: [:facts, :memory]}
  defstruct [:name, :source, :interval, :timeout, :facts, :memory, :fetched_at, :error, :task]

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

    state = %__MODULE__{
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
    %{name: name, source: source, facts: facts, memory: memory} = state
    settings = Wallboard.Settings.get()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    task =
      Task.Supervisor.async_nolink(Wallboard.TaskSupervisor, fn ->
        checked(name, source, settings, facts, memory, now)
      end)

    Process.send_after(self(), {:timeout, task.ref}, timeout_ms(state.timeout, settings))
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
    state = take(state, result)
    schedule(state)
    {:noreply, state}
  end

  # An exit's value can hold what the check read, so only its kind is logged.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("#{inspect(state.name)} poll crashed (#{exit_kind(reason)})")

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

  # Runs a source's check. A raise, throw or exit is caught here rather than
  # left to crash the task, whose crash report prints the error's text or
  # value, and that can hold what the check read (a timed-out call carries
  # its arguments). It becomes a failed check in plain words for the panel;
  # the log names only the error's kind.
  defp checked(name, source, settings, facts, memory, now) do
    source.poll(settings, facts, memory, now)
  rescue
    e ->
      Logger.error("The #{label(name)} check hit an error: #{inspect(e.__struct__)}")
      {:error, "the check hit an error", memory}
  catch
    kind, _ ->
      Logger.error("The #{label(name)} check stopped early (#{kind})")
      {:error, "the check stopped early", memory}
  end

  # "session issues" for :session_issues.
  defp label(name), do: name |> to_string() |> String.replace("_", " ")

  # Takes in a poll's result. An error here is caught rather than left to
  # crash the poller, because a crash report prints the error's text and its
  # stack's arguments, and both can hold the facts (a KeyError prints the
  # whole map). The log says only what kind of error it was; the last good
  # facts stay.
  defp take(state, result) do
    take!(state, result)
  rescue
    e ->
      Logger.error(
        "The #{label(state.name)} check could not use its new result: #{inspect(e.__struct__)}"
      )

      state = %{state | error: "the last check could not be read; retrying"}
      broadcast(state, false)
      state
  end

  defp take!(state, result) do
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
  end

  # Never print facts or memory in a crash report: not in the state, not in
  # the message being handled (a poll's result), and not in the error's
  # text, which can hold them (a KeyError prints the whole map).
  @impl true
  def format_status(status) do
    status
    |> Map.update(:state, nil, &Map.take(&1, [:name, :error, :fetched_at]))
    |> Map.replace(:message, :hidden)
    |> Map.replace(:log, [])
    |> Map.replace_lazy(:reason, &bare_reason/1)
  end

  # What kind of error it was, without its text.
  defp bare_reason(%{__exception__: true} = e),
    do: %RuntimeError{message: "#{inspect(e.__struct__)} (details hidden)"}

  defp bare_reason(reason) when is_atom(reason), do: reason
  defp bare_reason(_), do: :hidden

  defp schedule(state), do: Process.send_after(self(), :poll, state.interval)

  # A fixed time, or one worked out from the settings of each poll.
  defp timeout_ms(fun, settings) when is_function(fun, 1), do: fun.(settings)
  defp timeout_ms(ms, _settings), do: ms

  defp meta(state),
    do: %{fetched_at: state.fetched_at, error: state.error, interval: state.interval}

  # Every poll sends the small "how old is this" update; the facts go out
  # only when they changed.
  # :killed for :killed, :read for {:read, ...}, else "exit".
  defp exit_kind(reason) when is_atom(reason), do: inspect(reason)

  defp exit_kind(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: inspect(elem(reason, 0))

  defp exit_kind(_reason), do: "exit"

  defp broadcast(state, changed?) do
    message =
      if changed?,
        do: {:source, state.name, state.facts, meta(state)},
        else: {:source_meta, state.name, meta(state)}

    Phoenix.PubSub.broadcast(Wallboard.PubSub, @topic, message)
  end
end
