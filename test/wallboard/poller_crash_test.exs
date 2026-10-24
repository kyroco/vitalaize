defmodule Wallboard.PollerCrashTest do
  # A poller that fails while it takes in a poll's result must not write the
  # facts into the log: the GitHub facts hold issue text from private
  # repositories (issue #143).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wallboard.Poller

  defmodule Source do
    # The first result is taken as news without a look; comparing the second
    # with it calls fingerprint/1, which fails the way the test asks.
    def poll(_settings, _prev, _memory, _now) do
      facts = %{body: "PLANTED issue body", how: :persistent_term.get({__MODULE__, :how})}

      # A raise inside the check itself, with the facts in its text.
      if facts.how == :poll_raises, do: Map.fetch!(facts, :not_there)
      {:ok, facts, "PLANTED memory"}
    end

    def fingerprint(%{how: :raise}), do: raise("fingerprint failed")
    def fingerprint(%{how: :key} = facts), do: Map.fetch!(facts, :not_there)
    def fingerprint(facts), do: facts
  end

  defp failing_log(how) do
    :persistent_term.put({Source, :how}, how)

    capture_log(fn ->
      {:ok, pid} = GenServer.start(Poller, [name: nil, source: Source, interval_ms: 10], [])

      # Long enough for several polls, each failing the same way.
      Process.sleep(200)
      assert Process.alive?(pid), "the poller crashed"
      assert %{facts: %{body: _}, meta: %{error: error}} = GenServer.call(pid, :snapshot)
      assert error =~ "could not be read"
      GenServer.stop(pid)
    end)
  end

  test "an error while taking in the facts is logged by its kind alone" do
    log = failing_log(:raise)
    assert log =~ "could not take in a poll result: RuntimeError"
    refute log =~ "PLANTED"
    refute log =~ "Last message"
  end

  test "an error whose text holds the facts does not bring them into the log" do
    log = failing_log(:key)
    assert log =~ "could not take in a poll result: KeyError"
    refute log =~ "PLANTED"
  end

  test "a crash report from anywhere else holds neither the facts, the message nor the error's text" do
    status = %{
      state: %{
        name: :github,
        facts: %{body: "PLANTED"},
        memory: "PLANTED",
        error: nil,
        fetched_at: nil
      },
      message: {make_ref(), {:ok, %{body: "PLANTED"}, nil}},
      reason: %KeyError{key: :x, term: %{body: "PLANTED"}},
      log: [{:in, %{body: "PLANTED"}}]
    }

    shown = Poller.format_status(status)
    refute inspect(shown) =~ "PLANTED"
    assert Exception.message(shown.reason) =~ "KeyError"
    assert shown.state == %{name: :github, error: nil, fetched_at: nil}
  end

  test "a crash in the poller's own callbacks prints no facts or memory, even in the stack's arguments" do
    :persistent_term.put({Source, :how}, :fine)

    log =
      capture_log(fn ->
        {:ok, pid} = GenServer.start(Poller, [name: nil, source: Source, interval_ms: 10], [])
        Process.sleep(100)
        assert %{facts: %{body: _}} = GenServer.call(pid, :snapshot)

        # A call the poller has no clause for: the error's text lists the
        # call's arguments, the poller's state among them.
        ref = Process.monitor(pid)
        catch_exit(GenServer.call(pid, :not_a_call))
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
        Process.sleep(100)
      end)

    assert log =~ "FunctionClauseError"
    refute log =~ "PLANTED"
  end

  test "a raise inside a source's check is logged once, by its kind alone" do
    :persistent_term.put({Source, :how}, :poll_raises)

    log =
      capture_log(fn ->
        {:ok, pid} = GenServer.start(Poller, [name: nil, source: Source, interval_ms: 1_000], [])
        # One check, which raises.
        Process.sleep(200)
        assert Process.alive?(pid)
        GenServer.stop(pid)
      end)

    refute log =~ "PLANTED"
    assert [_] = Regex.scan(~r/KeyError/, log)
    refute log =~ "terminating"
  end
end
