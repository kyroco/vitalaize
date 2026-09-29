defmodule Wallboard.Sources.ClaudeTest do
  use ExUnit.Case, async: true

  alias Wallboard.Fixtures
  alias Wallboard.Sources.Claude

  defp agents!(file) do
    {:ok, agents} = Claude.parse_agents(Fixtures.read!(file))
    agents
  end

  defp job!(file) do
    {:ok, job} = Claude.parse_job_state(Fixtures.read!(file))
    job
  end

  describe "parse_agents/1 with real `claude agents --json` output" do
    test "reads every field of three busy background sessions" do
      agents = agents!("claude/agents_busy.json")

      assert Enum.map(agents, & &1.name) == ["planner", "shop-2057", "wallboard"]

      planner = hd(agents)
      assert planner.id == "4a662dec"
      assert planner.pid == 32714
      assert planner.kind == "background"
      assert planner.status == "busy"
      assert planner.state == "working"
      assert planner.cwd == "/Users/dev/projects/shop"
      # Matches the job's own createdAt (2026-09-25T21:18:03.641Z).
      assert planner.started_at == ~U[2026-09-25 21:18:04Z]
      assert Enum.all?(agents, &(Claude.classify(&1) == :working))
    end

    test "done and stopped sessions from --all have no status and count as idle" do
      agents = agents!("claude/agents_all.json")
      finished = Enum.filter(agents, &(&1.state in ["done", "stopped"]))

      assert length(finished) == 9
      assert Enum.all?(finished, &(&1.status == nil and &1.pid == nil))
      assert Enum.all?(finished, &(Claude.classify(&1) == :idle))
    end

    test "an account with no sessions gives an empty list" do
      assert Claude.parse_agents(Fixtures.read!("claude/agents_empty.json")) == {:ok, []}
    end

    test "output that is not a JSON list is an error, not a crash" do
      assert {:error, _} = Claude.parse_agents("Claude configuration file not found")
      assert {:error, _} = Claude.parse_agents(~s({"a": 1}))
    end
  end

  describe "parse_job_state/1 and parse_session_file/1 with real files" do
    test "reads the task text, tempo and update time of a working job" do
      job = job!("claude/job_state_planner.json")

      assert job.state == "working"
      assert job.tempo == "idle"
      assert job.detail == "PR #895 browser test failed; sent back to worker for fix"
      assert job.needs == nil
      assert job.updated_at == ~U[2026-09-28 22:01:24Z]
    end

    test "reads when the session's status last changed" do
      {:ok, file} = Claude.parse_session_file(Fixtures.read!("claude/session_file_planner.json"))
      assert %DateTime{} = file.status_since
    end

    test "a missing or reshaped file is simply absent" do
      assert {:error, :unreadable} = Claude.parse_job_state("not json")

      assert {:ok, %{detail: nil, state: nil}} =
               Claude.parse_job_state(~s({"somethingNew": true}))
    end
  end

  describe "needs you" do
    # No session was waiting while the fixtures were captured, so these take a
    # real busy session and set the field Claude Code sets when it waits.
    setup do
      planner = hd(agents!("claude/agents_busy.json"))
      blocked = Jason.decode!(Fixtures.read!("claude/timeline_blocked_record.json"))

      job = %{
        state: "blocked",
        tempo: "blocked",
        detail: blocked["detail"],
        needs: nil,
        updated_at: ~U[2026-09-28 21:53:25Z]
      }

      %{planner: planner, blocked_job: job}
    end

    test "a blocked background session needs you, with its own question as the reason",
         %{planner: planner, blocked_job: job} do
      agent = %{planner | status: "idle", state: "blocked"}
      session = Claude.build_session(agent, job, nil, "second-account")

      assert session.status == :needs

      assert session.why ==
               "Is that item your New Relic User API key, and okay for the wallboard to read?"

      assert session.waiting_since == ~U[2026-09-28 21:53:25Z]
      assert session.account == "second-account"
    end

    test "a permission prompt with no job file falls back to plain words", %{planner: planner} do
      agent = %{
        planner
        | status: "waiting",
          waiting_for: "permission prompt",
          kind: "interactive"
      }

      session = Claude.build_session(agent, nil, nil, nil)

      assert session.status == :needs
      assert session.why == "A permission prompt is waiting for your approval"
    end

    test "while waiting on a prompt, the prompt wins over the old task text",
         %{planner: planner} do
      job = job!("claude/job_state_planner.json")
      agent = %{planner | status: "waiting", waiting_for: "input needed"}

      assert Claude.why(agent, job) == "It asked you a question"
    end

    test "a label Claude adds later still shows", %{planner: planner} do
      agent = %{planner | status: "waiting", waiting_for: "brand new label"}
      assert Claude.why(agent, nil) == "Waiting on you: brand new label"
    end

    test "the job's needs text wins when Claude sets it", %{planner: planner, blocked_job: job} do
      agent = %{planner | status: "waiting", waiting_for: "dialog open"}
      assert Claude.why(agent, %{job | needs: "choose: allow or deny"}) == "choose: allow or deny"
    end
  end

  describe "track/3 (change over time)" do
    defp session(key, status, since \\ nil) do
      %{
        key: key,
        name: key,
        status: status,
        account: nil,
        why: "x",
        waiting_since: since,
        updated_at: since
      }
    end

    test "the first poll never counts as new, so a restart never re-sends a text" do
      {_s, _t, newly} = Claude.track([session("a", :needs)], nil, ~U[2026-09-28 22:00:00Z])
      assert newly == []
    end

    test "a session that starts needing you is new once, then not again" do
      t0 = ~U[2026-09-28 22:00:00Z]
      {_, tracking, []} = Claude.track([session("a", :working)], nil, t0)

      {[s], tracking, newly} = Claude.track([session("a", :needs)], tracking, DateTime.add(t0, 5))
      assert Enum.map(newly, & &1.key) == ["a"]
      assert s.since == DateTime.add(t0, 5)

      {[s2], tracking, newly} =
        Claude.track([session("a", :needs)], tracking, DateTime.add(t0, 10))

      assert newly == []
      assert s2.since == DateTime.add(t0, 5)

      # Back to work, then waiting again: that is a new needs-you.
      {_, tracking, []} = Claude.track([session("a", :working)], tracking, DateTime.add(t0, 15))
      {_, _, newly} = Claude.track([session("a", :needs)], tracking, DateTime.add(t0, 20))
      assert Enum.map(newly, & &1.key) == ["a"]
    end

    test "the wait is measured from the files' own timestamp when there is one" do
      t0 = ~U[2026-09-28 22:00:00Z]
      {_, tracking, _} = Claude.track([session("a", :working)], nil, t0)
      {[s], _, _} = Claude.track([session("a", :needs, ~U[2026-09-28 21:58:00Z])], tracking, t0)
      assert s.since == ~U[2026-09-28 21:58:00Z]
    end

    test "a session that disappears and comes back needing you is new" do
      t0 = ~U[2026-09-28 22:00:00Z]
      {_, tracking, _} = Claude.track([session("a", :working)], nil, t0)
      {_, tracking, _} = Claude.track([], tracking, t0)
      {_, _, newly} = Claude.track([session("a", :needs)], tracking, t0)
      assert length(newly) == 1
    end

    test "long_running? flags working sessions past the setting" do
      now = ~U[2026-09-28 22:00:00Z]
      assert Claude.long_running?(%{status: :working, since: ~U[2026-09-28 21:00:00Z]}, now, 45)
      refute Claude.long_running?(%{status: :working, since: ~U[2026-09-28 21:30:00Z]}, now, 45)
      refute Claude.long_running?(%{status: :idle, since: ~U[2026-09-28 20:00:00Z]}, now, 45)
    end
  end

  test "account labels read the way people say them" do
    assert Claude.account_label("/Users/dev/.claude") == "main"
    assert Claude.account_label("/Users/dev/.claude-second-account") == "second-account"
  end
end
