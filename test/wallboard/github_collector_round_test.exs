defmodule Wallboard.GitHubCollectorRoundTest do
  # A stand-in gh on the PATH answers like GitHub, and keeps what it was
  # asked. One at a time: the PATH is this whole test run's.
  use ExUnit.Case, async: false

  alias Wallboard.Archive.{CiMinutes, GitHubCollector, Trends}
  alias Wallboard.{Fixtures, Settings, Store}

  setup do
    start_supervised!({Store, path: ":memory:"})
    dir = Fixtures.tmp_path("wallboard-gh-round")
    File.mkdir_p!(dir)

    job = fn id, attempt ->
      ~s({"id": #{id}, "run_id": 1, "run_attempt": #{attempt}, "labels": ["ubuntu-latest"],) <>
        ~s( "started_at": "2026-09-30T17:00:00Z", "completed_at": "2026-09-30T17:02:00Z"})
    end

    # Like GitHub: without filter=all, only the latest attempt's jobs.
    File.write!(Path.join(dir, "gh"), """
    #!/bin/sh
    echo "$2" >> "$WALLBOARD_TEST_GH/asked"
    case "$2" in
      *"/actions/runs/1/jobs?filter=all"*"page=2"*)
        if [ -f "$WALLBOARD_TEST_GH/page_2_down" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1
        elif [ -f "$WALLBOARD_TEST_GH/jobs_2.json" ]; then cat "$WALLBOARD_TEST_GH/jobs_2.json"
        else echo '{"jobs": []}'; fi ;;
      *"/actions/runs/1/jobs?filter=all"*)
        if [ -f "$WALLBOARD_TEST_GH/jobs_1.json" ]; then cat "$WALLBOARD_TEST_GH/jobs_1.json"; exit 0; fi
        echo '{"jobs": [#{job.(11, 1)}, #{job.(12, 2)}]}' ;;
      *"/actions/runs/1/jobs"*)
        echo '{"jobs": [#{job.(12, 2)}]}' ;;
      *"/pulls?"*)
        if [ -f "$WALLBOARD_TEST_GH/pulls_down" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
        if [ -f "$WALLBOARD_TEST_GH/pulls_forbidden" ]; then
          echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; exit 1
        fi
        if [ -f "$WALLBOARD_TEST_GH/pulls_not_found" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
        # Pages of pull requests from files, pulls_page_<n>.json, then none;
        # or the same full page for every page asked.
        page=$(echo "$2" | sed -n 's/.*[?&]page=\\([0-9]*\\).*/\\1/p')
        if [ -f "$WALLBOARD_TEST_GH/pulls_every_page.json" ]; then cat "$WALLBOARD_TEST_GH/pulls_every_page.json"; exit 0; fi
        if [ -f "$WALLBOARD_TEST_GH/pulls_page_$page.json" ]; then cat "$WALLBOARD_TEST_GH/pulls_page_$page.json"; exit 0; fi
        echo '[]' ;;
      *"/actions/runs?"*)
        if [ -f "$WALLBOARD_TEST_GH/runs_down" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
        case "$2" in
          *"created=2026-10-03"*)
            echo '{"total_count": 1, "workflow_runs": [{"id": 2, "run_attempt": 1, "status": "completed", "conclusion": "failure", "head_branch": "feature", "created_at": "2026-10-03T16:00:00Z"}]}'
            exit 0 ;;
        esac
        echo '{"total_count": 1, "workflow_runs": [{"id": 1, "run_attempt": 2, "status": "completed", "conclusion": "success", "head_branch": "feature", "created_at": "2026-09-30T16:59:00Z"}]}' ;;
      repos/acme/shop)
        if [ -f "$WALLBOARD_TEST_GH/down" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
        echo '{"private": false, "default_branch": "trunk"}' ;;
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

    settings =
      Settings.merge(Settings.defaults(), %{
        github: %{repo: "acme/shop"},
        archive: %{backfill_days: 0}
      })

    %{dir: dir, settings: settings}
  end

  # What gh was asked since the last look.
  defp asked(dir) do
    file = Path.join(dir, "asked")

    if File.exists?(file) do
      lines = file |> File.read!() |> String.split("\n", trim: true)
      File.rm!(file)
      lines
    else
      []
    end
  end

  # The days whose runs gh was asked for since the last look.
  defp days_read(dir) do
    for line <- asked(dir), [_, day] <- [Regex.run(~r/created=([0-9-]+)/, line)], do: day
  end

  test "a run created while the board was off for a weekend is saved on the next round",
       %{dir: dir, settings: settings} do
    # The last good round began Friday 5:55 PM Eastern; the Mac was then
    # closed until Monday 9:00 AM Eastern. A run failed Saturday at noon.
    settings = put_in(settings.archive.backfill_days, 14)
    Store.put_meta("github_backfill:acme/shop", "2026-09-20")
    friday = DateTime.to_unix(~U[2026-10-02 21:55:00Z])
    Store.put_meta("github_runs_through:acme/shop", Integer.to_string(friday))
    monday = ~U[2026-10-05 13:00:00Z]

    assert {:ok, _, _} = GitHubCollector.round(settings, monday)
    assert days_read(dir) == ["2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05"]
    assert [%{conclusion: "failure"}] = Store.query("SELECT * FROM gh_runs WHERE run_id = 2", [])

    assert Store.get_meta("github_runs_through:acme/shop") ==
             Integer.to_string(DateTime.to_unix(monday))

    # The round after that reads yesterday and today again, not the weekend.
    assert {:ok, _, _} = GitHubCollector.round(settings, DateTime.add(monday, 300))
    assert days_read(dir) == ["2026-10-04", "2026-10-05"]
  end

  test "a last round in the first hour of a day reads the day before it too",
       %{dir: dir, settings: settings} do
    # The last good round began Friday 8:30 PM Eastern, half an hour into
    # GitHub's Saturday: a run created just before may still have been going.
    settings = put_in(settings.archive.backfill_days, 14)
    Store.put_meta("github_backfill:acme/shop", "2026-09-20")
    friday = DateTime.to_unix(~U[2026-10-03 00:30:00Z])
    Store.put_meta("github_runs_through:acme/shop", Integer.to_string(friday))

    assert {:ok, _, _} = GitHubCollector.round(settings, ~U[2026-10-05 13:00:00Z])
    assert days_read(dir) == ["2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05"]
  end

  test "a board upgraded with no record of its last round reads yesterday and today",
       %{dir: dir, settings: settings} do
    settings = put_in(settings.archive.backfill_days, 14)
    Store.put_meta("github_backfill:acme/shop", "2026-09-20")
    monday = ~U[2026-10-05 13:00:00Z]

    assert {:ok, _, _} = GitHubCollector.round(settings, monday)
    assert days_read(dir) == ["2026-10-04", "2026-10-05"]

    # A record that is not a whole number counts as none.
    Store.put_meta("github_runs_through:acme/shop", "abc")
    assert {:ok, _, _} = GitHubCollector.round(settings, DateTime.add(monday, 300))
    assert days_read(dir) == ["2026-10-04", "2026-10-05"]
  end

  test "one round never reads further back than the backfill", %{dir: dir, settings: settings} do
    settings = put_in(settings.archive.backfill_days, 3)
    Store.put_meta("github_backfill:acme/shop", "2026-08-01")
    Store.put_meta("github_runs_through:acme/shop", "1785000000")

    GitHubCollector.round(settings, ~U[2026-10-05 13:00:00Z])
    assert days_read(dir) == ["2026-10-02", "2026-10-03", "2026-10-04", "2026-10-05"]
  end

  test "the runs' start moves when runs save, whatever happens to the pull requests",
       %{dir: dir, settings: settings} do
    settings = put_in(settings.archive.backfill_days, 14)
    Store.put_meta("github_backfill:acme/shop", "2026-09-20")
    friday = Integer.to_string(DateTime.to_unix(~U[2026-10-02 21:55:00Z]))
    Store.put_meta("github_runs_through:acme/shop", friday)

    File.write!(Path.join(dir, "runs_down"), "")
    assert {:error, _} = GitHubCollector.round(settings, ~U[2026-10-05 13:00:00Z])
    assert Store.get_meta("github_runs_through:acme/shop") == friday

    File.rm!(Path.join(dir, "runs_down"))
    File.write!(Path.join(dir, "pulls_down"), "")
    monday = ~U[2026-10-05 13:05:00Z]
    assert {:ok, _, _} = GitHubCollector.round(settings, monday)
    assert [_] = Store.query("SELECT run_id FROM gh_runs WHERE run_id = 2", [])

    assert Store.get_meta("github_runs_through:acme/shop") ==
             Integer.to_string(DateTime.to_unix(monday))
  end

  test "a token that cannot read pull requests still saves runs, and Shipped says why",
       %{dir: dir, settings: settings} do
    File.write!(Path.join(dir, "pulls_forbidden"), "")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _, _} = GitHubCollector.round(settings, ~U[2026-09-30 18:00:00Z])
        assert {:ok, _, _} = GitHubCollector.round(settings, ~U[2026-09-30 18:05:00Z])
      end)

    assert [_] = Store.query("SELECT run_id FROM gh_runs WHERE run_id = 1", [])

    assert Trends.shipped_loading(settings) ==
             "Can't read pull requests in acme/shop: the GitHub sign-in is not allowed to"

    # Said once when it starts, not every round.
    assert length(Regex.scan(~r/pull requests/, log)) == 1

    # A private repository the sign-in cannot see answers 404: refused too.
    File.rm!(Path.join(dir, "pulls_forbidden"))
    File.write!(Path.join(dir, "pulls_not_found"), "")
    Store.put_meta(GitHubCollector.prs_error_key("acme/shop"), "")

    ExUnit.CaptureLog.capture_log(fn ->
      GitHubCollector.round(settings, ~U[2026-09-30 18:07:00Z])
    end)

    assert Trends.shipped_loading(settings) ==
             "Can't read pull requests in acme/shop: the GitHub sign-in is not allowed to"

    # GitHub failing for another reason is said differently.
    File.rm!(Path.join(dir, "pulls_not_found"))
    File.write!(Path.join(dir, "pulls_down"), "")

    ExUnit.CaptureLog.capture_log(fn ->
      GitHubCollector.round(settings, ~U[2026-09-30 18:10:00Z])
    end)

    assert Trends.shipped_loading(settings) ==
             "Can't read pull requests in acme/shop right now, trying again every 5 minutes"

    # A good read clears it.
    File.rm!(Path.join(dir, "pulls_down"))
    assert {:ok, _, _} = GitHubCollector.round(settings, ~U[2026-09-30 18:15:00Z])
    assert Trends.shipped_loading(settings) == nil
  end

  # 100 closed pull requests numbered from `first`, all changed at `at`.
  defp pulls_page(first, at) do
    Jason.encode!(
      for n <- first..(first + 99) do
        %{number: n, title: "PR #{n}", updated_at: at, closed_at: at, merged_at: at}
      end
    )
  end

  test "every pull request of the backfill is read, past 1,000", %{dir: dir, settings: settings} do
    at = "2026-09-30T12:00:00Z"

    for page <- 1..11,
        do: File.write!(Path.join(dir, "pulls_page_#{page}.json"), pulls_page(page * 100, at))

    assert {:ok, _, _} = GitHubCollector.round(settings, ~U[2026-09-30 18:00:00Z])
    assert [%{n: 1_100}] = Store.query("SELECT count(*) AS n FROM gh_prs", [])
    assert Store.get_meta("github_prs_backfill:acme/shop") == "2026-09-30"
  end

  test "a read that stops at its safety limit marks nothing done", %{dir: dir, settings: settings} do
    File.write!(Path.join(dir, "pulls_every_page.json"), pulls_page(1, "2026-09-30T12:00:00Z"))

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, _, _} = GitHubCollector.round(settings, ~U[2026-09-30 18:00:00Z])
    end)

    assert Enum.count(asked(dir), &String.contains?(&1, "/pulls?")) == 100
    # What was read is saved, though nothing is marked read.
    assert [%{n: 100}] = Store.query("SELECT count(*) AS n FROM gh_prs", [])
    assert Store.get_meta("github_prs_backfill:acme/shop") == nil
    assert Store.get_meta("github_prs_through:acme/shop") == nil

    # Once read, the next round's start stays where it was too.
    Store.put_meta("github_prs_backfill:acme/shop", "2026-09-20")
    Store.put_meta("github_prs_through:acme/shop", "1790000000")

    ExUnit.CaptureLog.capture_log(fn ->
      GitHubCollector.round(settings, ~U[2026-09-30 18:05:00Z])
    end)

    assert Store.get_meta("github_prs_through:acme/shop") == "1790000000"
  end

  test "a rerun's jobs are saved for every attempt", %{settings: settings} do
    assert {:ok, 1, 1} = GitHubCollector.round(settings, ~U[2026-09-30 18:00:00Z])

    assert [%{attempt: 1}, %{attempt: 2}] =
             Store.query("SELECT attempt FROM gh_jobs ORDER BY attempt", [])
  end

  test "a big matrix rerun's jobs are all saved, a page at a time",
       %{dir: dir, settings: settings} do
    job = fn id, attempt -> %{id: id, run_id: 1, run_attempt: attempt, labels: []} end
    jobs = for(id <- 1..80, do: job.(id, 1)) ++ for(id <- 81..130, do: job.(id, 2))
    {first, second} = Enum.split(jobs, 100)
    File.write!(Path.join(dir, "jobs_1.json"), Jason.encode!(%{total_count: 130, jobs: first}))
    File.write!(Path.join(dir, "jobs_2.json"), Jason.encode!(%{total_count: 130, jobs: second}))

    assert {:ok, 1, 1} = GitHubCollector.round(settings, ~U[2026-09-30 18:00:00Z])
    assert [%{n: 130}] = Store.query("SELECT count(*) AS n FROM gh_jobs", [])
    assert Enum.any?(asked(dir), &(&1 =~ "/runs/1/jobs?filter=all&per_page=100&page=2"))
  end

  test "a run whose second page of jobs fails saves none of them, and is read again later",
       %{dir: dir, settings: settings} do
    jobs = for id <- 1..100, do: %{id: id, run_id: 1, run_attempt: 1, labels: []}
    File.write!(Path.join(dir, "jobs_1.json"), Jason.encode!(%{total_count: 130, jobs: jobs}))
    File.write!(Path.join(dir, "page_2_down"), "")

    assert {:ok, 1, 0} = GitHubCollector.round(settings, ~U[2026-09-30 18:00:00Z])
    assert [%{n: 0}] = Store.query("SELECT count(*) AS n FROM gh_jobs", [])
    assert Store.runs_missing_jobs("acme/shop", 10) == [1]
  end

  test "a run whose jobs come back in a shape not known is not taken for one with none",
       %{dir: dir, settings: settings} do
    File.write!(Path.join(dir, "jobs_1.json"), ~s({"message": "something else"}))

    assert {:ok, 1, 0} = GitHubCollector.round(settings, ~U[2026-09-30 18:00:00Z])
    assert Store.runs_missing_jobs("acme/shop", 10) == [1]
  end

  test "a repository's visibility is read once a day, and a failed read keeps the last",
       %{dir: dir, settings: settings} do
    facts = fn -> Enum.count(asked(dir), &(&1 == "repos/acme/shop")) end

    GitHubCollector.round(settings, ~U[2026-09-30 18:00:00Z])
    assert facts.() == 1
    assert %{private: false, default_branch: "trunk"} = CiMinutes.repo_facts("acme/shop")

    GitHubCollector.round(settings, ~U[2026-09-30 18:05:00Z])
    assert facts.() == 0

    File.write!(Path.join(dir, "down"), "")
    GitHubCollector.round(settings, ~U[2026-10-01 09:00:00Z])
    assert facts.() == 1
    assert %{private: false, day: "2026-09-30"} = CiMinutes.repo_facts("acme/shop")
  end
end
