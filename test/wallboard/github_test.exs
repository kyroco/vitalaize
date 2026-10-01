defmodule Wallboard.Sources.GitHubTest do
  use ExUnit.Case, async: true

  alias Wallboard.{Fixtures, Settings}
  alias Wallboard.Sources.GitHub

  # When the fixtures were captured.
  @now ~U[2026-09-28 21:52:00Z]

  defp runs!(file) do
    {:ok, runs} = GitHub.parse_runs(Fixtures.read!(file))
    runs
  end

  # The workflows in the fixtures, set here rather than taken from the
  # defaults, so the tests do not change when the defaults do.
  defp settings do
    Settings.merge(Settings.defaults(), %{
      github: %{
        repo: "acme/shop",
        gate_workflow: "ci.yml",
        gate_check: "ci",
        dev_deploy: "deploy-staging.yml",
        prod_deploy: "deploy-production.yml",
        deploy_workflows: [
          "deploy-staging.yml",
          "deploy-production.yml",
          "website-deploy.yml",
          "promote.yml"
        ],
        lanes: [
          %{label: "CI", workflows: ["ci.yml"]},
          %{label: "Staging", workflows: ["deploy-staging.yml"]},
          %{label: "Website", workflows: ["website-deploy.yml"]},
          %{label: "Maintenance", workflows: ["maintenance.yml"]},
          %{label: "Production", workflows: ["deploy-production.yml", "promote.yml"]}
        ]
      }
    })
  end

  defp facts do
    {:ok, repo} = GitHub.parse_graphql(Fixtures.read!("github/graphql.json"), "ci")

    deploys =
      ~w(deploy-staging.yml deploy-production.yml website-deploy.yml promote.yml)
      |> Enum.flat_map(&runs!("github/deploy_#{&1}.json"))

    %{
      runs: runs!("github/runs_24h.json"),
      deploys: deploys,
      deploys_checked_at: @now,
      queue: repo.queue,
      prs: repo.prs,
      jobs: %{}
    }
  end

  describe "parse_runs/1 with real REST output" do
    test "reads the last day of runs" do
      runs = runs!("github/runs_24h.json")
      assert length(runs) == 88
      assert Enum.all?(runs, &(&1.status == :completed))

      gate = Enum.find(runs, &(&1.id == 36_487_639_186))
      assert gate.name == "CI"
      assert gate.workflow == "ci.yml"
      assert gate.event == "pull_request"
      assert gate.pr == 895
      assert gate.sha == "3756165e5"
      assert gate.started_at == ~U[2026-09-28 21:40:16Z]
      assert gate.conclusion == "success"
    end

    test "a merge queue run gets its pull request number from the branch name" do
      run = Enum.find(runs!("github/runs_24h.json"), &(&1.id == 36_472_294_704))
      assert run.event == "merge_group"
      assert run.pr == 894
      assert GitHub.what(run) == "#894 in the merge queue"
    end

    test "long workflow names lose their parenthetical tail" do
      assert GitHub.short_name("Deploy Production (build -> apply -> roll)") ==
               "Deploy Production"

      assert GitHub.short_name("CI") == "CI"
    end

    test "an error body is an error, not a crash" do
      assert {:error, _} = GitHub.parse_runs(~s({"message": "Bad credentials"}))
      assert {:error, _} = GitHub.parse_runs("gh: not logged in")
    end
  end

  test "parse_jobs/1 counts finished jobs of a real run" do
    jobs = GitHub.parse_jobs(Fixtures.read!("github/jobs_completed.json"))
    assert jobs.total == 26
    assert jobs.done == 26
    assert jobs.current_job == nil
  end

  describe "parse_graphql/2 with real output" do
    test "reads the empty merge queue and the open pull request's gate" do
      {:ok, repo} = GitHub.parse_graphql(Fixtures.read!("github/graphql.json"), "ci")
      assert repo.queue == []
      assert [%{number: 895, gate: :passed, draft: false}] = repo.prs
    end

    test "a check name that is not there reads as no gate yet" do
      {:ok, repo} = GitHub.parse_graphql(Fixtures.read!("github/graphql.json"), "No Such Check")
      assert [%{gate: :none}] = repo.prs
    end

    test "a GraphQL error is passed on in words" do
      assert {:error, "GitHub GraphQL: Could not resolve"} =
               GitHub.parse_graphql(~s({"errors": [{"message": "Could not resolve"}]}), "gate")
    end
  end

  describe "summary/3 on the real day" do
    setup do
      %{s: GitHub.summary(facts(), settings().github, @now)}
    end

    test "main is green from the last merge queue gate", %{s: s} do
      assert s.main.conclusion == "success"
      assert s.main.event == "merge_group"
      assert s.last_merge.pr == 894
    end

    test "failures leave out pull request and Dependabot runs", %{s: s} do
      names = Enum.map(s.failures, & &1.name)
      assert names == ["Deploy Staging", "Scheduled Maintenance", "Deploy Staging", "CI"]
    end

    test "dev and prod come from the deploy workflows, even days old", %{s: s} do
      assert s.dev.last_success.sha == "a6235b93f"
      assert s.prod.last_success.sha == "09ced4fc9"
      assert s.prod.last_success.updated_at == ~U[2026-09-27 21:39:37Z]
    end

    test "the recent list is the six newest finished runs", %{s: s} do
      assert length(s.recent) == 6

      assert Enum.map(s.recent, & &1.updated_at) ==
               Enum.sort(Enum.map(s.recent, & &1.updated_at), {:desc, DateTime})
    end

    test "the timeline puts runs of the last 6 hours in their lanes", %{s: s} do
      lanes = Map.new(s.lanes, &{&1.label, &1.bars})
      assert [%{kind: :fail}] = lanes["Maintenance"]
      # A row is drawn for what ran: Production had no run in the window.
      refute Map.has_key?(lanes, "Production")
      assert Enum.all?(lanes["CI"], &(&1.start + &1.length > 0))
    end

    test "nothing is running in the captured data", %{s: s} do
      assert s.running == []
    end
  end

  test "a running run's progress uses how long that workflow usually takes" do
    run = %{
      id: 1,
      name: "CI",
      workflow: "ci.yml",
      title: "x",
      event: "pull_request",
      branch: "b",
      sha: "abc",
      status: :in_progress,
      conclusion: nil,
      started_at: DateTime.add(@now, -240),
      updated_at: @now,
      pr: 900,
      url: nil
    }

    done = %{
      run
      | id: 2,
        status: :completed,
        conclusion: "success",
        started_at: DateTime.add(@now, -3000),
        updated_at: DateTime.add(@now, -2520)
    }

    jobs = %{1 => %{total: 4, done: 2, current_job: "Tests / Tests 3", current_step: "Run tests"}}

    s =
      GitHub.summary(
        %{facts() | runs: [run, done], deploys: [], jobs: jobs},
        settings().github,
        @now
      )

    [r] = s.running
    assert r.progress == 50
    assert r.step == "Tests / Tests 3: Run tests, 2 of 4 jobs done"
  end
end
