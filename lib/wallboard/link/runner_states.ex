defmodule Wallboard.Link.RunnerStates do
  @moduledoc """
  What collectors say about the GitHub Actions runners on their machines
  (see `Wallboard.Collector.Runners`), held in memory on the hub as
  `%{machine => %{name => :online | :busy | :offline}}`. Nothing of it is
  saved: only the latest word counts.

  Each collector sends its whole list when it changes and once after each
  connect. A runner that a connected collector listed before and lists no
  more has stopped, so it shows offline; each machine keeps at most 100 of
  those, the latest to stop first. When the collector's stream
  closes, its runners are dropped: the hub no longer knows, and the board
  says "state not known" unless GitHub says otherwise.

  The board hears the merged `%{name => state}` as `{:runners, states}` on
  its topic (`Wallboard.Poller.topic/0`), and asks for it with `states/0`
  when a page opens. The same name on two machines shows the busiest
  state. It goes to `Wallboard.Sources.GitHub.repos/4`, where GitHub's own
  list wins for a runner it lists.
  """

  use GenServer

  @busiest [:busy, :online, :offline]
  # The most runners a machine keeps shown offline, besides the at most 100
  # it lists (Wallboard.Collector.Filter caps a list).
  @offline_max 100

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  What a collector's stream said: `machine`'s runners now, `%{name =>
  :online | :busy}`. `stream` is the stream's process; when it ends, the
  machine's runners are dropped. Returns at once.
  """
  def put(machine, stream, runners) when is_map(runners),
    do: GenServer.cast(__MODULE__, {:put, machine, stream, runners})

  @doc "Every runner a connected collector reports, `%{name => state}`."
  def states do
    GenServer.call(__MODULE__, :states, 2_000)
  catch
    :exit, _ -> %{}
  end

  @doc """
  The runners of every machine as one map. A name on more than one machine
  takes the busiest state: busy, then online, then offline.
  """
  def merge(by_machine) do
    by_machine
    |> Map.values()
    |> Enum.reduce(%{}, fn runners, acc ->
      Map.merge(acc, runners, fn _name, a, b -> busiest(a, b) end)
    end)
  end

  defp busiest(a, b),
    do: Enum.find(@busiest, &(&1 in [a, b])) || a

  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # machine => %{stream: pid, ref: monitor, runners: %{name => state},
    #             stopped: the offline names, the latest to stop first}
    {:ok, %{machines: %{}}}
  end

  @impl true
  def handle_cast({:put, machine, stream, runners}, s) do
    {before, stopped} =
      case s.machines[machine] do
        # The same stream: what it listed before and lists no more is off.
        %{stream: ^stream, runners: before, stopped: stopped} ->
          {before, stopped}

        # A newer stream of the machine: it starts from what it says now.
        %{ref: ref} ->
          Process.demonitor(ref, [:flush])
          {%{}, []}

        nil ->
          {%{}, []}
      end

    ref =
      case s.machines[machine] do
        %{stream: ^stream, ref: ref} -> ref
        _ -> Process.monitor(stream)
      end

    # The stopped runners, the latest to stop first: what it stopped
    # listing now, then those already off that it still does not list.
    # Only so many are kept, the oldest let go first: a collector that keeps
    # naming new runners must not grow the hub without end.
    now_gone =
      for {name, state} <- before,
          state != :offline,
          not Map.has_key?(runners, name),
          do: name

    stopped =
      (Enum.sort(now_gone) ++ Enum.reject(stopped, &Map.has_key?(runners, &1)))
      |> Enum.take(@offline_max)

    entry = %{
      stream: stream,
      ref: ref,
      stopped: stopped,
      runners: Map.merge(Map.new(stopped, &{&1, :offline}), runners)
    }

    {:noreply, publish(s, put_in(s.machines[machine], entry))}
  end

  @impl true
  def handle_call(:states, _from, s), do: {:reply, merge(runners(s)), s}

  # The stream closed: the hub no longer knows these runners.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) do
    case Enum.find(s.machines, fn {_, entry} -> entry.ref == ref end) do
      {machine, _} -> {:noreply, publish(s, %{s | machines: Map.delete(s.machines, machine)})}
      nil -> {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp runners(s), do: Map.new(s.machines, fn {machine, e} -> {machine, e.runners} end)

  # Only a change is told to the board.
  defp publish(old, new) do
    states = merge(runners(new))

    if states != merge(runners(old)),
      do: Phoenix.PubSub.broadcast(Wallboard.PubSub, Wallboard.Poller.topic(), {:runners, states})

    new
  end
end
