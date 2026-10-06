defmodule Wallboard.GitHubFetchTest do
  # A stand-in gh on the PATH answers, and keeps what it was asked. One at
  # a time: the PATH is this whole test run's.
  use ExUnit.Case, async: false

  alias Wallboard.{Fixtures, Settings, Store}
  alias Wallboard.Archive.GitHubCollector
  alias Wallboard.Sources.GitHub

  @now ~U[2026-09-30 18:00:00Z]

  setup do
    dir = Fixtures.tmp_path("wallboard-gh")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "gh"), """
    #!/bin/sh
    echo "$2" >> "$WALLBOARD_TEST_GH/asked"
    case "$2" in
      graphql)
        echo '{"data":{"repository":{"mergeQueue":{"entries":{"nodes":[]}},"pullRequests":{"nodes":[]}}}}' ;;
      *"/actions/workflows?"*)
        if [ -f "$WALLBOARD_TEST_GH/workflows.json" ]; then cat "$WALLBOARD_TEST_GH/workflows.json"
        else echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi ;;
      *"/actions/runs?"*)
        if [ -f "$WALLBOARD_TEST_GH/runs.json" ]; then cat "$WALLBOARD_TEST_GH/runs.json"
        else echo '{"workflow_runs":[]}'; fi ;;
      *"/actions/runs/"*"/jobs"*)
        if [ -f "$WALLBOARD_TEST_GH/jobs.json" ]; then cat "$WALLBOARD_TEST_GH/jobs.json"
        else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
      *"/actions/workflows/"*)
        echo '{"workflow_runs":[]}' ;;
      *"/actions/runners?"*)
        if [ -f "$WALLBOARD_TEST_GH/runners.json" ]; then cat "$WALLBOARD_TEST_GH/runners.json"
        elif [ -f "$WALLBOARD_TEST_GH/runners_refused" ]; then
          echo "gh: Must have admin rights to Repository. (HTTP 403)" >&2; exit 1
        else echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi ;;
      *)
        echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac
    """)

    File.chmod!(Path.join(dir, "gh"), 0o755)

    old = {System.get_env("PATH"), System.get_env("WALLBOARD_TEST_GH")}
    System.put_env("PATH", dir <> ":" <> elem(old, 0))
    System.put_env("WALLBOARD_TEST_GH", dir)

    on_exit(fn ->
      System.put_env("PATH", elem(old, 0))

      if elem(old, 1),
        do: System.put_env("WALLBOARD_TEST_GH", elem(old, 1)),
        else: System.delete_env("WALLBOARD_TEST_GH")

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp repos(github),
    do: Settings.github_repos(Settings.merge(Settings.defaults(), %{github: github}))

  defp lists(dir, files, total \\ nil) do
    File.write!(
      Path.join(dir, "workflows.json"),
      Jason.encode!(%{
        total_count: total || length(files),
        workflows: Enum.map(files, &%{path: ".github/workflows/" <> &1})
      })
    )
  end

  # What gh was asked since the last look, without the repository part.
  defp asked(dir) do
    file = Path.join(dir, "asked")
    lines = file |> File.read!() |> String.split("\n", trim: true)
    File.rm!(file)
    Enum.map(lines, &String.replace(&1, ~r{^repos/[\w.-]+/[\w.-]+/actions/}, ""))
  end

  @rockets %{
    repos: ["acme/rockets", "acme/boosters"],
    gate_workflow: "gate.yml",
    deploy_workflows: ["dev-deploy.yml", "prod-deploy.yml"]
  }

  test "the workflow files are read, and a deploy file the repo does not have is not asked for",
       %{dir: dir} do
    lists(dir, ["ci.yml", "dev-deploy.yml"])
    [rockets, _] = repos(@rockets)

    assert {:ok, facts} = GitHub.fetch(rockets, nil, @now)
    assert facts.workflows == ["ci.yml", "dev-deploy.yml"]

    calls = asked(dir)
    assert "workflows?per_page=100" in calls
    assert "workflows/dev-deploy.yml/runs?per_page=10" in calls
    refute "workflows/prod-deploy.yml/runs?per_page=10" in calls

    # gate.yml is not one of its files, so main comes from its runs.
    assert GitHub.summary(facts, rockets, @now).main_from == :runs

    # Between deploy checks the list is kept and not asked for again.
    assert {:ok, again} = GitHub.fetch(rockets, facts, DateTime.add(@now, 30))
    assert again.workflows == facts.workflows
    refute Enum.any?(asked(dir), &String.starts_with?(&1, "workflows"))
  end

  test "when the list cannot be read, settings are taken at their word and the last list is kept",
       %{dir: dir} do
    [rockets, _] = repos(@rockets)

    assert {:ok, facts} = GitHub.fetch(rockets, nil, @now)
    assert facts.workflows == nil
    assert "workflows/prod-deploy.yml/runs?per_page=10" in asked(dir)
    assert GitHub.summary(facts, rockets, @now).main_from == :gate

    # A list read earlier stays through a failed read.
    prev = %{facts | workflows: ["gate.yml"], deploys_checked_at: DateTime.add(@now, -600)}
    assert {:ok, %{workflows: ["gate.yml"]}} = GitHub.fetch(rockets, prev, @now)
  end

  test "a list that is only the first page of more is not trusted", %{dir: dir} do
    lists(dir, ["ci.yml"], 130)
    [rockets, _] = repos(@rockets)

    assert {:ok, %{workflows: nil} = facts} = GitHub.fetch(rockets, nil, @now)
    assert GitHub.summary(facts, rockets, @now).main_from == :gate
  end

  test "a repo that names no workflows costs no extra call, and keeps no old deploys", %{dir: dir} do
    lists(dir, ["ci.yml"])
    [_, boosters] = repos(@rockets)

    old_deploy = %{id: 9, workflow: "ship.yml", status: :completed}

    prev = %{
      runs: [],
      deploys: [old_deploy],
      deploys_checked_at: DateTime.add(@now, -600),
      queue: [],
      prs: [],
      jobs: %{}
    }

    assert {:ok, facts} = GitHub.fetch(boosters, prev, @now)
    assert facts.workflows == nil and facts.deploys == []
    refute Enum.any?(asked(dir), &String.starts_with?(&1, "workflows"))
  end

  describe "which of your runners ran each run" do
    defp runs(dir, runs) do
      File.write!(
        Path.join(dir, "runs.json"),
        Jason.encode!(%{
          workflow_runs:
            for {id, status} <- runs do
              %{
                id: id,
                name: "CI",
                path: ".github/workflows/ci.yml",
                event: "push",
                head_branch: "main",
                head_sha: "abc#{id}",
                status: status,
                conclusion: if(status == "completed", do: "success"),
                created_at: "2026-09-30T17:00:00Z",
                run_started_at: "2026-09-30T17:00:00Z",
                updated_at: "2026-09-30T17:30:00Z"
              }
            end
        })
      )
    end

    test "a run keeps its runners after it finishes, until it leaves the last day's list",
         %{dir: dir} do
      [rockets, _] = repos(@rockets)
      File.write!(Path.join(dir, "jobs.json"), Fixtures.read!("github/jobs_runners.json"))

      # While it runs, its jobs say which runners it is on.
      runs(dir, [{1, "in_progress"}])
      assert {:ok, first} = GitHub.fetch(rockets, nil, @now)
      assert first.own_by_run == %{1 => ["acme-mini-1", "acme-mini-2"]}
      assert "runs/1/jobs?per_page=100" in asked(dir)

      # Finished: its jobs are no longer asked for, and it keeps them.
      runs(dir, [{1, "completed"}])
      assert {:ok, done} = GitHub.fetch(rockets, first, DateTime.add(@now, 30))
      refute Enum.any?(asked(dir), &(&1 =~ "/jobs"))
      assert done.own_by_run == %{1 => ["acme-mini-1", "acme-mini-2"]}

      # Out of the last day's list: forgotten.
      runs(dir, [{2, "completed"}])
      assert {:ok, later} = GitHub.fetch(rockets, done, DateTime.add(@now, 60))
      assert later.own_by_run == %{}
    end

    test "a job without the self-hosted label is yours when GitHub lists its runner",
         %{dir: dir} do
      [rockets, _] = repos(@rockets)

      # As a workflow with `runs-on: acme-mac` asks: the jobs on acme-mini-1
      # and acme-mini-2 carry only their own label.
      jobs =
        "github/jobs_runners.json"
        |> Fixtures.read!()
        |> Jason.decode!()
        |> update_in(["jobs", Access.all(), "labels"], fn labels ->
          if "self-hosted" in labels, do: ["acme-mac"], else: labels
        end)

      File.write!(Path.join(dir, "jobs.json"), Jason.encode!(jobs))
      runs(dir, [{1, "in_progress"}])

      # GitHub will not list the runners: nothing says they are yours.
      File.write!(Path.join(dir, "runners_refused"), "")
      assert {:ok, hidden} = GitHub.fetch(rockets, nil, @now)
      assert hidden.own_by_run == %{}
      assert GitHub.summary(hidden, rockets, @now).runners == []

      # GitHub lists them: the run is marked, and the busy one shows its job.
      File.rm!(Path.join(dir, "runners_refused"))
      File.write!(Path.join(dir, "runners.json"), Fixtures.read!("github/runners.json"))
      assert {:ok, listed} = GitHub.fetch(rockets, nil, @now)
      assert listed.own_by_run == %{1 => ["acme-mini-1", "acme-mini-2"]}

      busy = Enum.find(GitHub.summary(listed, rockets, @now).runners, &(&1.name == "acme-mini-2"))
      assert {busy.state, busy.job} == {:busy, "Browser tests"}
    end

    test "a run that started and finished between polls gets its runners from the archive",
         %{dir: dir} do
      start_supervised!({Store, path: ":memory:"})
      [rockets, _] = repos(@rockets)

      jobs =
        GitHubCollector.parse_jobs(Fixtures.read!("github/jobs_runners.json"), "acme/rockets", 7)

      :ok = Store.put_jobs("acme/rockets", 7, Enum.map(jobs, &%{&1 | run_id: 7}))

      runs(dir, [{7, "completed"}, {8, "completed"}])
      assert {:ok, facts} = GitHub.fetch(rockets, nil, DateTime.add(@now, 5 * 86_400))
      # Only the finished jobs are saved: the one on acme-mini-1.
      assert facts.own_by_run == %{7 => ["acme-mini-1"]}
    end
  end

  describe "the repository's own runners" do
    test "are read with the deploys, and a failed read keeps the last list", %{dir: dir} do
      File.write!(Path.join(dir, "runners.json"), Fixtures.read!("github/runners.json"))
      [rockets, _] = repos(@rockets)

      assert {:ok, facts} = GitHub.fetch(rockets, nil, @now)
      assert Enum.map(facts.runners, & &1.name) == ["acme-mini-1", "acme-mini-2", "acme-linux-1"]
      assert "runners?per_page=100" in asked(dir)

      # Not asked again before the deploys are.
      assert {:ok, _} = GitHub.fetch(rockets, facts, DateTime.add(@now, 30))
      refute "runners?per_page=100" in asked(dir)

      # GitHub fails for another reason: the list read before stays.
      File.rm!(Path.join(dir, "runners.json"))
      later = DateTime.add(@now, rockets.deploy_poll_seconds)
      assert {:ok, kept} = GitHub.fetch(rockets, facts, later)
      assert "runners?per_page=100" in asked(dir)
      assert kept.runners == facts.runners
    end

    test "that GitHub refuses to list are not asked for again within the hour", %{dir: dir} do
      File.write!(Path.join(dir, "runners_refused"), "")
      [rockets, _] = repos(@rockets)

      assert {:ok, facts} = GitHub.fetch(rockets, nil, @now)
      assert facts.runners == :hidden
      assert "runners?per_page=100" in asked(dir)

      # Past the deploys' turn, but not an hour: still not asked.
      assert {:ok, facts} = GitHub.fetch(rockets, facts, DateTime.add(@now, 1800))
      assert facts.runners == :hidden
      refute "runners?per_page=100" in asked(dir)

      assert {:ok, _} = GitHub.fetch(rockets, facts, DateTime.add(@now, 3600))
      assert "runners?per_page=100" in asked(dir)
    end
  end
end
