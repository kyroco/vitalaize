defmodule Wallboard.RunnerStatesTest do
  @moduledoc "What the hub keeps of the runners collectors report."
  # The hub's runner states are one named process.
  use ExUnit.Case, async: false

  alias Wallboard.Link.RunnerStates

  defp names(from, to), do: Map.new(from..to, &{"r-#{&1}", :online})

  # Stands in for Wallboard.Link.Hub, under its name: it holds one stream
  # for each machine, as the test says, and answers which one it holds.
  defmodule FakeHub do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: Wallboard.Link.Hub)
    def hold(machine, pid), do: GenServer.call(Wallboard.Link.Hub, {:hold, machine, pid})

    @impl true
    def init(streams), do: {:ok, streams}

    @impl true
    def handle_call({:hold, machine, pid}, _from, s), do: {:reply, :ok, Map.put(s, machine, pid)}

    def handle_call({:current?, machine, pid}, _from, s),
      do: {:reply, Map.get(s, machine) == pid, s}
  end

  defp stream, do: spawn(fn -> Process.sleep(:infinity) end)

  # Ends a stand-in stream, and waits until its end was seen.
  defp stop(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
  end

  test "the hub holds one stream for a machine: an older stream of it is not current" do
    old = stream()
    new = stream()
    s = %{streams: %{"air" => %{pid: new}}}

    assert {:reply, true, ^s} = Wallboard.Link.Hub.handle_call({:current?, "air", new}, nil, s)
    assert {:reply, false, ^s} = Wallboard.Link.Hub.handle_call({:current?, "air", old}, nil, s)
    assert {:reply, false, ^s} = Wallboard.Link.Hub.handle_call({:current?, "mini", new}, nil, s)
  end

  describe "with the hub" do
    setup do
      start_supervised!(FakeHub)
      start_supervised!(RunnerStates)
      :ok
    end

    test "a reconnect keeps the machine's runners: the old stream's end drops nothing" do
      old = stream()
      FakeHub.hold("air", old)
      RunnerStates.put("air", old, %{"air-1" => :busy})
      assert RunnerStates.states() == %{"air-1" => :busy}

      # The hub takes the machine's new stream and closes the old one,
      # which is not the machine going away: it says nothing of it.
      new = stream()
      FakeHub.hold("air", new)
      stop(old)
      assert RunnerStates.states() == %{"air-1" => :busy}

      RunnerStates.put("air", new, %{"air-1" => :online})
      assert RunnerStates.states() == %{"air-1" => :online}
    end

    test "a late list from the machine's old stream is not taken, and its end drops nothing" do
      old = stream()
      new = stream()
      FakeHub.hold("air", new)

      RunnerStates.put("air", new, %{"air-1" => :busy})
      RunnerStates.put("air", old, %{"air-2" => :online})
      assert RunnerStates.states() == %{"air-1" => :busy}

      stop(old)
      assert RunnerStates.states() == %{"air-1" => :busy}
    end

    test "the hub saying the machine went drops its runners, unless a newer stream spoke" do
      first = stream()
      FakeHub.hold("air", first)
      RunnerStates.put("air", first, %{"air-1" => :busy})

      # A newer stream came and spoke before word of the old one's end.
      second = stream()
      FakeHub.hold("air", second)
      RunnerStates.put("air", second, %{"air-1" => :online})
      Phoenix.PubSub.broadcast(Wallboard.PubSub, "link", {:link, :down, "air"})
      assert RunnerStates.states() == %{"air-1" => :online}

      # Now it is gone too.
      FakeHub.hold("air", nil)
      Phoenix.PubSub.broadcast(Wallboard.PubSub, "link", {:link, :down, "air"})
      assert RunnerStates.states() == %{}
    end
  end

  test "a collector that keeps naming new runners cannot grow the hub without end" do
    start_supervised!(RunnerStates)
    # Stands in for the collector's stream; it stays up the whole test.
    stream = spawn(fn -> Process.sleep(:infinity) end)

    # 50 lists of 100 names, each list new: every name it stops listing
    # would be kept as offline.
    for n <- 0..49, do: RunnerStates.put("air", stream, names(n * 100, n * 100 + 99))

    states = RunnerStates.states()
    # What it lists now is all there, online.
    assert Enum.all?(4900..4999, &(states["r-#{&1}"] == :online))
    # The ones it stopped listing are kept as offline, but only so many.
    offline = Enum.count(states, fn {_, s} -> s == :offline end)
    assert offline > 0 and offline <= 100
    assert map_size(states) <= 200
  end

  test "past the limit, the runners that stopped longest ago are the ones let go" do
    start_supervised!(RunnerStates)
    # Stands in for the collector's stream; it stays up the whole test.
    stream = spawn(fn -> Process.sleep(:infinity) end)

    # 100 runners made for one job each, a-000 to a-099, stop one by one.
    for n <- 0..99 do
      RunnerStates.put("air", stream, %{"a-#{String.pad_leading("#{n}", 3, "0")}" => :busy})
    end

    # Then two more stop, z-1 and then z-2.
    RunnerStates.put("air", stream, %{"z-1" => :busy})
    RunnerStates.put("air", stream, %{"z-2" => :busy})
    RunnerStates.put("air", stream, %{})

    states = RunnerStates.states()
    # The latest to stop are kept, whatever their names; the oldest went.
    assert states["z-1"] == :offline and states["z-2"] == :offline
    refute Map.has_key?(states, "a-000")
    refute Map.has_key?(states, "a-001")
    assert states["a-099"] == :offline
    assert map_size(states) == 100
  end

  test "a runner the collector stops listing shows offline" do
    start_supervised!(RunnerStates)
    # Stands in for the collector's stream; it stays up the whole test.
    stream = spawn(fn -> Process.sleep(:infinity) end)

    RunnerStates.put("air", stream, %{"air-1" => :busy, "air-2" => :online})
    RunnerStates.put("air", stream, %{"air-2" => :online})

    assert RunnerStates.states() == %{"air-1" => :offline, "air-2" => :online}
  end
end
