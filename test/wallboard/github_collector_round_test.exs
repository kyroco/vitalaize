defmodule Wallboard.GitHubCollectorRoundTest do
  # A stand-in gh on the PATH answers like GitHub, and keeps what it was
  # asked. One at a time: the PATH is this whole test run's.
  use ExUnit.Case, async: false

  alias Wallboard.Archive.{CiMinutes, GitHubCollector}
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
      *"/actions/runs/1/jobs?filter=all"*)
        echo '{"jobs": [#{job.(11, 1)}, #{job.(12, 2)}]}' ;;
      *"/actions/runs/1/jobs"*)
        echo '{"jobs": [#{job.(12, 2)}]}' ;;
      *"/actions/runs?"*)
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

  test "a rerun's jobs are saved for every attempt", %{settings: settings} do
    assert {:ok, 1, 1} = GitHubCollector.round(settings, ~U[2026-09-30 18:00:00Z])

    assert [%{attempt: 1}, %{attempt: 2}] =
             Store.query("SELECT attempt FROM gh_jobs ORDER BY attempt", [])
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
