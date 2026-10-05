defmodule Wallboard.RunnersTest do
  @moduledoc """
  Your own (self-hosted) runners: which jobs ran on them, each runner's
  state, the Git tab's marks and Trends' split.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Wallboard.Archive.{GitHubCollector, Trends}
  alias Wallboard.{Fixtures, Runners, Settings, Store}
  alias Wallboard.Sources.GitHub

  @now ~U[2026-10-05 17:05:00Z]

  describe "whose machine ran a job" do
    test "GitHub's group, the self-hosted label, another group, an old row's name" do
      assert Runners.kind(%{runner_group_name: "GitHub Actions"}) == :github
      assert Runners.kind(%{"labels" => ["self-hosted", "macOS"]}) == :own
      # As saved: labels joined by commas.
      assert Runners.kind(%{labels: "self-hosted,Linux"}) == :own
      assert Runners.kind(%{runner_group_name: "Default", labels: "kyroco-gate"}) == :own
      # Saved before the group was kept: GitHub's machines are known by name.
      assert Runners.kind(%{runner_name: "GitHub Actions 1000041223", labels: "ubuntu-latest"}) ==
               :github

      # Nothing that says either way is not guessed.
      assert Runners.kind(%{runner_name: "build-box", labels: "ubuntu-latest"}) == :unknown
      assert Runners.kind(%{runner_name: "GitHub Actions box"}) == :unknown
      assert Runners.kind(%{}) == :unknown
    end

    test "a run's jobs from GitHub: which of your runners ran them and what each runs now" do
      jobs = GitHub.parse_jobs(Fixtures.read!("github/jobs_runners.json"))

      assert jobs.own == ["acme-mini-1", "acme-mini-2"]
      assert jobs.busy == %{"acme-mini-2" => "Browser tests"}
      assert {jobs.total, jobs.done} == {4, 2}
    end

    test "a run GitHub alone ran has none of your runners" do
      jobs = GitHub.parse_jobs(Fixtures.read!("github/jobs_completed.json"))
      assert jobs.own == [] and jobs.busy == %{}
    end

    test "the archive saves each job's runner group and reads it back" do
      start_supervised!({Store, path: ":memory:"})

      jobs =
        GitHubCollector.parse_jobs(Fixtures.read!("github/jobs_runners.json"), "acme/shop", 1)

      assert Enum.map(jobs, & &1.runner_group_name) == [
               "GitHub Actions",
               "Default",
               "Default",
               nil
             ]

      :ok = Store.put_jobs("acme/shop", 36_500_000_001, jobs)
      since = DateTime.to_unix(~U[2026-10-05 00:00:00Z])
      rows = Store.job_runners("acme/shop", since)

      assert Enum.map(rows, &{&1.runner_name, &1.runner_group_name}) |> Enum.sort() == [
               {"GitHub Actions 1000041223", "GitHub Actions"},
               {"acme-mini-1", "Default"}
             ]

      assert Runners.own_names(rows) == ["acme-mini-1"]
    end
  end

  describe "each runner's state" do
    @listed [
      %{name: "acme-mini-1", status: "online", busy: false},
      %{name: "acme-mini-2", status: "online", busy: true},
      %{name: "acme-linux-1", status: "offline", busy: false}
    ]

    test "GitHub's list of runners, read from a real reply's shape" do
      assert {:ok, list} = GitHub.parse_runners(Fixtures.read!("github/runners.json"))
      assert Enum.map(list, &Map.take(&1, [:name, :status, :busy])) == @listed
      assert hd(list).labels == ["self-hosted", "macOS", "ARM64"]
      assert {:error, _} = GitHub.parse_runners(~s({"message":"Not Found"}))
    end

    test "from GitHub when it lists them, with the job a busy one runs" do
      states = Runners.states(@listed, %{}, ["acme-mini-2"], %{"acme-mini-2" => "Browser tests"})

      assert Enum.map(states, &{&1.name, &1.state, &1.job, &1.from}) == [
               {"acme-linux-1", :offline, nil, :github},
               {"acme-mini-1", :online, nil, :github},
               {"acme-mini-2", :busy, "Browser tests", :github}
             ]

      assert Runners.count_line(states) == "1 online, 1 busy, 1 offline"
    end

    test "from a collector when GitHub will not list them" do
      [state] = Runners.states(:hidden, %{"acme-mini-1" => :busy}, ["acme-mini-1"], %{})
      assert {state.state, state.from, state.why} == {:busy, :collector, nil}
    end

    test "when neither can tell, the state is not known, never made up, and says why" do
      [hidden] = Runners.states(:hidden, %{}, ["acme-mini-1"], %{"acme-mini-1" => "Build"})
      assert {hidden.state, hidden.from, hidden.job} == {:unknown, nil, nil}
      assert hidden.why =~ "Your GitHub login cannot list this repository's runners"

      # GitHub lists the repository's runners but not this one, which may be
      # the organization's.
      [_, _, _, org] = Runners.states(@listed, %{}, ["org-box"], %{})
      assert {org.name, org.state} == {"org-box", :unknown}
      assert org.why =~ "may belong to the organization"

      [unread] = Runners.states(nil, %{}, ["acme-mini-1"], %{})
      assert unread.state == :unknown and unread.why =~ "Not read from GitHub yet"
      assert Runners.count_line([unread]) == "1 not known"
    end
  end

  describe "the Git tab" do
    defp run(id, opts) do
      status = Keyword.get(opts, :status, :completed)
      ended = DateTime.add(@now, -Keyword.get(opts, :ago_min, 30) * 60)

      %{
        id: id,
        name: Keyword.get(opts, :name, "CI"),
        workflow: "ci.yml",
        title: "change #{id}",
        event: "push",
        branch: "main",
        sha: "abc#{id}",
        status: status,
        conclusion: if(status == :completed, do: "success"),
        started_at: DateTime.add(ended, -120),
        updated_at: ended,
        pr: nil,
        url: nil
      }
    end

    defp repo(runs, facts) do
      settings = Settings.merge(Settings.defaults(), %{github: %{repos: ["acme/shop"]}})

      base = %{
        runs: runs,
        deploys: [],
        deploys_checked_at: @now,
        queue: [],
        prs: [],
        jobs: %{}
      }

      [r] =
        GitHub.repos(
          %{repos: [%{repo: "acme/shop", facts: Map.merge(base, facts), error: nil}]},
          settings,
          @now
        )

      r
    end

    test "a run on your own runner is marked with its name, and one GitHub ran is not" do
      jobs = GitHub.parse_jobs(Fixtures.read!("github/jobs_runners.json"))

      r =
        repo(
          [
            run(1, status: :in_progress, ago_min: 0),
            run(2, name: "Nightly", ago_min: 20),
            run(3, name: "Docs", ago_min: 40)
          ],
          %{jobs: %{1 => jobs}, own_by_run: %{1 => jobs.own, 2 => ["acme-mini-1"]}}
        )

      [running] = r.s.running
      assert running.own == ["acme-mini-1", "acme-mini-2"]

      assert Enum.map(r.s.recent, &{&1.label, &1.own}) == [
               {"Nightly", ["acme-mini-1"]},
               {"Docs", []}
             ]

      html = render_component(&WallboardWeb.BoardLive.git_column/1, r: r, now: @now)
      assert html =~ "on acme-mini-1, acme-mini-2"
      assert html =~ "on acme-mini-1"

      # Only the two runs on your own machines carry a mark.
      assert html |> String.split("own-tag") |> length() == 3

      # The column counts the runners it saw; GitHub was not asked yet.
      assert html =~ "Runners"
      assert html =~ "2 not known"
    end

    test "a repository with no runners of its own looks as it did" do
      r = repo([run(3, name: "Docs")], %{})
      assert r.s.runners == []

      html = render_component(&WallboardWeb.BoardLive.git_column/1, r: r, now: @now)
      refute html =~ "own-tag"
      refute html =~ "Runners"
      assert render_component(&WallboardWeb.BoardLive.runners_table/1, runners: []) =~ ~r/\A\s*\z/
    end

    test "the repository panel lists each runner with its state and job, or why it is not known" do
      jobs = GitHub.parse_jobs(Fixtures.read!("github/jobs_runners.json"))
      {:ok, listed} = GitHub.parse_runners(Fixtures.read!("github/runners.json"))

      r =
        repo([run(1, status: :in_progress, ago_min: 0)], %{
          jobs: %{1 => jobs},
          own_by_run: %{1 => jobs.own},
          runners: listed
        })

      html = render_component(&WallboardWeb.BoardLive.runners_table/1, runners: r.s.runners)
      assert html =~ "Your runners"
      assert html =~ ~r/acme-mini-2.*busy.*Browser tests/s
      assert html =~ ~r/acme-mini-1.*online.*from GitHub/s
      assert html =~ ~r/acme-linux-1.*offline/s

      column = render_component(&WallboardWeb.BoardLive.git_column/1, r: r, now: @now)
      assert column =~ "1 online, 1 busy, 1 offline"

      hidden =
        repo([run(2, ago_min: 5)], %{own_by_run: %{2 => ["acme-mini-1"]}, runners: :hidden})

      html = render_component(&WallboardWeb.BoardLive.runners_table/1, runners: hidden.s.runners)
      assert html =~ "state not known"
      assert html =~ "cannot list this repository"
      refute html =~ "online"
    end
  end

  describe "Trends" do
    test "runner time is split into GitHub's and your own, with the paid minutes avoided" do
      start_supervised!({Store, path: ":memory:"})
      now = DateTime.utc_now()
      done = DateTime.to_unix(now) - 3600

      job = fn id, d, fields ->
        Map.merge(
          %{repo: "acme/shop", job_id: id, run_id: 1, completed_at: done, duration_s: d},
          fields
        )
      end

      :ok =
        Store.put_jobs("acme/shop", 1, [
          job.(1, 3600, %{runner_name: "GitHub Actions 1", runner_group_name: "GitHub Actions"}),
          # Saved before the group was kept: known by its name.
          job.(2, 1800, %{runner_name: "GitHub Actions 2", labels: "ubuntu-latest"}),
          # Your own: 61 seconds bills as 2 minutes, 120 as 2.
          job.(3, 61, %{runner_name: "acme-mini-1", labels: "self-hosted,macOS"}),
          job.(4, 120, %{runner_name: "acme-mini-1", runner_group_name: "Default"}),
          # Neither: counted apart, in no one's column.
          job.(5, 360, %{runner_name: "build-box", labels: "ubuntu-latest"})
        ])

      settings = Settings.merge(Settings.defaults(), %{github: %{repos: ["acme/shop"]}})
      t = Trends.build(settings, 7, now)
      card = fn key -> Enum.find(t.cards, &(&1.key == key)) end

      assert card.(:runner_hours).label == "Runner time on GitHub"
      assert card.(:runner_hours).value == 1.5
      assert card.(:runner_hours).sub == "2 jobs · 0.1 h not known"
      assert_in_delta card.(:own_runner_hours).value, 181 / 3600, 1.0e-9
      assert card.(:own_runner_hours).sub == "2 jobs · 0.1 h not known"
      assert card.(:minutes_avoided).value == 4
      assert card.(:minutes_avoided).sub == "2 jobs on your machines"
    end
  end
end
