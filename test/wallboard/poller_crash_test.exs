defmodule Wallboard.PollerCrashTest do
  # A poller that crashes while it handles a poll's result must not write the
  # facts into the log: the GitHub facts hold issue text from private
  # repositories (issue #143).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wallboard.Poller

  defmodule Source do
    # The first result is taken as news without a look; comparing the second
    # with it calls fingerprint/1, which fails the way the test asks.
    def poll(_settings, _prev, _memory, _now),
      do: {:ok, %{body: "PLANTED issue body", how: :persistent_term.get({__MODULE__, :how})}, nil}

    def fingerprint(%{how: :raise}), do: raise("fingerprint failed")
    def fingerprint(%{how: :key} = facts), do: Map.fetch!(facts, :not_there)
  end

  defp crash_log(how) do
    :persistent_term.put({Source, :how}, how)

    capture_log(fn ->
      {:ok, pid} =
        GenServer.start(Poller, [name: nil, source: Source, interval_ms: 10], [])

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      # The crash report is written as the process ends.
      Process.sleep(100)
    end)
  end

  test "the message being handled is not in the crash report" do
    log = crash_log(:raise)
    assert log =~ "fingerprint failed"
    refute log =~ "PLANTED"
  end

  test "an error whose text holds the facts does not bring them into the log" do
    log = crash_log(:key)
    assert log =~ "KeyError"
    refute log =~ "PLANTED"
  end
end
