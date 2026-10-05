defmodule Wallboard.CiMinutesTest do
  use ExUnit.Case, async: false

  alias Wallboard.Archive.{CiMinutes, GitHubCollector, Trends}
  alias Wallboard.Store

  @repo "acme/shop"
  @t0 1_790_000_000

  setup do
    start_supervised!({Store, path: ":memory:"})
    :ok
  end

  describe "minutes as GitHub bills them" do
    test "each job rounds up to a whole minute, Windows counts 2, macOS 10, own machines apart" do
      run(1, pr: 7)

      jobs(1, [
        job(1, 61, "ubuntu-latest"),
        job(2, 1, "ubuntu-latest"),
        job(3, 60, "windows-latest"),
        job(4, 90, "macos-14"),
        job(5, 125, "self-hosted,Linux,ARM64,kyroco-gate"),
        # Skipped: never started, so nothing billed.
        job(6, nil, "ubuntu-latest")
      ])

      # 2 + 1 + 2 * 1 + 10 * 2 on GitHub's runners; 3 on our own.
      assert %{paid: 25, free: 0, own: 3, runs: 1, failed: 0} = CiMinutes.for_pr(@repo, 7)
    end

    test "a public repository's minutes on GitHub's runners are free, not paid" do
      public!(@repo)
      run(1, pr: 7)
      jobs(1, [job(1, 600, "ubuntu-latest"), job(2, 60, "self-hosted")])

      assert %{paid: 0, free: 10, own: 1} = CiMinutes.for_pr(@repo, 7)
    end

    test "a repository whose visibility is not read yet counts as paid" do
      run(1, pr: 7)
      jobs(1, [job(1, 600, "ubuntu-latest")])
      assert %{paid: 10, free: 0} = CiMinutes.for_pr(@repo, 7)
    end
  end

  describe "a session's minutes" do
    test "a run on its branch while it worked counts; main, another branch or later does not" do
      s = session("s1", "robert/41-sign-in", @t0, @t0 + 3600)

      run(1, branch: "robert/41-sign-in", created_at: @t0 + 600)
      run(2, branch: "robert/41-sign-in", created_at: @t0 + 3600 + 120)
      run(3, branch: "main", created_at: @t0 + 600, event: "push")
      run(4, branch: "robert/other", created_at: @t0 + 600)
      run(5, branch: "robert/41-sign-in", created_at: @t0 + 3600 + 900)
      run(6, branch: "robert/41-sign-in", created_at: @t0 - 60)

      for id <- 1..6, do: jobs(id, [job(id * 10, 120, "ubuntu-latest", conclusion(id))])

      # Run 2 began two minutes after the session's last activity: its push.
      assert %{paid: 4, runs: 2, failed: 1} = CiMinutes.for_session(s)
    end

    test "the repository's default branch, scheduled and merge queue runs are never a session's" do
      put_facts(@repo, %{private: true, default_branch: "trunk"})
      s = session("s1", "trunk", @t0, @t0 + 3600)
      run(1, branch: "trunk", created_at: @t0 + 60)
      jobs(1, [job(1, 60, "ubuntu-latest")])
      assert %{runs: 0} = CiMinutes.for_session(s)

      s = session("s2", "feature", @t0, @t0 + 3600)
      run(2, branch: "feature", created_at: @t0 + 60, event: "schedule")
      run(3, branch: "feature", created_at: @t0 + 60, event: "merge_group")
      jobs(2, [job(2, 60, "ubuntu-latest")])
      jobs(3, [job(3, 60, "ubuntu-latest")])
      assert %{runs: 0} = CiMinutes.for_session(s)
    end

    test "two sessions on one branch: the one that started last gets the run, once" do
      early = session("early", "feature", @t0, @t0 + 7200)
      late = session("late", "feature", @t0 + 1800, @t0 + 3600)

      run(1, branch: "feature", created_at: @t0 + 600)
      run(2, branch: "feature", created_at: @t0 + 2400)
      jobs(1, [job(1, 60, "ubuntu-latest")])
      jobs(2, [job(2, 120, "ubuntu-latest")])

      assert %{paid: 1, runs: 1} = CiMinutes.for_session(early)
      assert %{paid: 2, runs: 1} = CiMinutes.for_session(late)
    end

    test "a rerun counts again, at the time it was asked for" do
      s = session("s1", "feature", @t0, @t0 + 3600)
      run(1, branch: "feature", created_at: @t0 + 600, attempt: 3, pr: 41)

      jobs(1, [
        job(1, 60, "ubuntu-latest", "failure", attempt: 1, created_at: @t0 + 610),
        # Rerun by the session itself.
        job(2, 120, "ubuntu-latest", "success", attempt: 2, created_at: @t0 + 1200),
        # Rerun by someone the next day.
        job(3, 180, "ubuntu-latest", "success", attempt: 3, created_at: @t0 + 86_400)
      ])

      assert %{paid: 3, runs: 2, failed: 1} = CiMinutes.for_session(s)
      assert %{paid: 6, runs: 3} = CiMinutes.for_pr(@repo, 41)
    end

    test "a session with no branch or times has none" do
      assert %{paid: 0, runs: 0} = CiMinutes.for_session(%{git_branch: nil})
    end
  end

  test "a session in another repository does not take the run" do
    a = %{repo: "acme/shop", branch: "feature", event: "push", at: 100, default: nil}

    s = fn id, repo ->
      %{
        machine: "m",
        session_id: id,
        tool: "claude",
        repo: repo,
        branch: "feature",
        started_at: 0,
        ended_at: 200
      }
    end

    assert [] = CiMinutes.link([a], [s.("other", "acme/web")])
    assert [{^a, %{session_id: "same"}}] = CiMinutes.link([a], [s.("same", "Acme/Shop")])
    assert [{^a, %{session_id: "unknown"}}] = CiMinutes.link([a], [s.("unknown", nil)])
  end

  test "a pull request counts its own runs, push runs on its branch and its merge queue runs" do
    run(1, pr: 41, branch: "robert/41-sign-in", event: "pull_request")
    run(2, branch: "robert/41-sign-in", event: "push")
    run(3, branch: "gh-readonly-queue/main/pr-41-abc123", event: "merge_group")
    run(4, branch: "gh-readonly-queue/main/pr-410-abc123", event: "merge_group")
    # A fork's pull request can come from its main: GitHub's tag counts.
    run(5, branch: "main", event: "pull_request", pr: 41)
    # But main is never matched by branch alone.
    run(6, branch: "main", event: "push")
    for id <- 1..6, do: jobs(id, [job(id, 60 * id, "ubuntu-latest")])

    assert %{paid: 11, runs: 4} = CiMinutes.for_pr("Acme/Shop", 41)
  end

  test "every attempt's jobs are kept when saved, and a repository's facts are read" do
    reply =
      Jason.encode!(%{
        "jobs" => [
          %{"id" => 1, "run_id" => 9, "run_attempt" => 1, "labels" => ["ubuntu-latest"]},
          %{"id" => 2, "run_id" => 9, "run_attempt" => 2, "labels" => ["ubuntu-latest"]}
        ]
      })

    :ok = Store.put_jobs(@repo, 9, GitHubCollector.parse_jobs(reply, @repo, 9))

    assert [%{attempt: 1}, %{attempt: 2}] =
             Store.query("SELECT attempt FROM gh_jobs ORDER BY attempt", [])

    assert {:ok, %{private: false, default_branch: "trunk"}} =
             GitHubCollector.parse_repo(~s({"private": false, "default_branch": "trunk"}))

    assert {:error, _} = GitHubCollector.parse_repo(~s({"message": "Not Found"}))
  end

  test "Trends shows CI minutes, the part agents caused, and each tool's" do
    now = DateTime.from_unix!(@t0 + 7200)
    session("c", "claude-branch", @t0, @t0 + 3600, "claude")
    session("x", "codex-branch", @t0, @t0 + 3600, "codex")

    run(1, branch: "claude-branch", created_at: @t0 + 60)
    run(2, branch: "codex-branch", created_at: @t0 + 60)
    run(3, branch: "main", created_at: @t0 + 60, event: "push")
    jobs(1, [job(1, 600, "ubuntu-latest")])
    jobs(2, [job(2, 300, "ubuntu-latest"), job(4, 600, "self-hosted")])
    jobs(3, [job(3, 120, "ubuntu-latest")])

    t = Trends.build(Wallboard.Settings.merge(settings(), %{}), 7, now)
    card = Enum.find(t.cards, &(&1.key == :ci_minutes))

    assert card.value == 17
    assert card.group == :github
    assert card.sub == "15 from agent sessions · 10 on your own machines"

    # Requests give both tools something to compare.
    assert %{claude: 10, codex: 5} = Enum.find(t.compare, &(&1.key == :ci_minutes))
  end

  test "the session detail's note says the runs and what uses up no plan" do
    alias WallboardWeb.BoardLive

    assert BoardLive.ci_note(%{runs: 0}) == "no runs"

    assert BoardLive.ci_note(%{runs: 4, failed: 1, free: 0, own: 0, paid: 18}) ==
             "4 runs, 1 failed"

    assert BoardLive.ci_note(%{runs: 1, failed: 0, free: 12, own: 3, paid: 0}) ==
             "1 run · 12 free on a public repository · 3 on your own machines"
  end

  # ---------------------------------------------------------------------------

  defp settings do
    %{
      archive: %{backfill_days: 14},
      codex: %{enabled: true},
      github: %{
        repo: @repo,
        gate_workflow: "ci.yml",
        dev_deploy: "deploy-staging.yml",
        prod_deploy: "deploy-production.yml"
      }
    }
  end

  defp run(id, opts) do
    :ok =
      Store.put_runs([
        %{
          repo: @repo,
          run_id: id,
          attempt: opts[:attempt] || 1,
          workflow: "ci.yml",
          event: opts[:event] || "pull_request",
          branch: opts[:branch],
          status: "completed",
          conclusion: "success",
          created_at: opts[:created_at] || @t0,
          pr: opts[:pr]
        }
      ])
  end

  defp jobs(run_id, jobs) do
    :ok = Store.put_jobs(@repo, run_id, Enum.map(jobs, &Map.put(&1, :run_id, run_id)))
  end

  defp job(id, seconds, labels, conclusion \\ "success", opts \\ []) do
    %{
      repo: @repo,
      job_id: id,
      attempt: opts[:attempt] || 1,
      conclusion: conclusion,
      created_at: opts[:created_at],
      duration_s: seconds,
      labels: labels
    }
  end

  defp conclusion(2), do: "failure"
  defp conclusion(_), do: "success"

  # A session streamed from another machine, so no folder is read for its
  # repository. Each has one request, so Trends has spending for its tool.
  defp session(id, branch, started_at, ended_at, tool \\ "claude") do
    s = %{
      machine: "m",
      session_id: id,
      source: "stream",
      tool: tool,
      git_branch: branch,
      started_at: started_at,
      ended_at: ended_at,
      prompts: 1
    }

    :ok =
      Store.put_session(s, [
        %{
          machine: "m",
          session_id: id,
          request_id: "r-" <> id,
          at: ended_at,
          cost: 1.0,
          input_tokens: 10,
          output_tokens: 10,
          cache_read_tokens: 0,
          cache_write_tokens: 0
        }
      ])

    s
  end

  defp public!(repo), do: put_facts(repo, %{private: false, default_branch: "main"})

  defp put_facts(repo, facts),
    do: Store.put_meta(CiMinutes.meta_key(repo), Jason.encode!(Map.put(facts, :day, "x")))
end
