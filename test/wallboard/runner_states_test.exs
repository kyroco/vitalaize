defmodule Wallboard.RunnerStatesTest do
  @moduledoc "What the hub keeps of the runners collectors report."
  # The hub's runner states are one named process.
  use ExUnit.Case, async: false

  alias Wallboard.Link.RunnerStates

  defp names(from, to), do: Map.new(from..to, &{"r-#{&1}", :online})

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
