defmodule Wallboard.TrendsTest do
  use ExUnit.Case, async: false

  alias Wallboard.Archive.{GitHubCollector, Trends}
  alias Wallboard.{Fixtures, Store}

  test "reads runs from a real reply, with their time and pull request" do
    {:ok, runs, total} = GitHubCollector.parse_runs(Fixtures.read!("github/runs_24h.json"), "o/r")
    run = hd(runs)
    assert total >= length(runs)
    assert run.run_id == 36_487_639_186
    assert run.workflow == "ci.yml"
    assert run.pr == 895
    assert run.duration_s == 474
  end

  test "reads a run's jobs from a real reply" do
    jobs = GitHubCollector.parse_jobs(Fixtures.read!("github/jobs_completed.json"), "o/r", 1)
    assert length(jobs) == 26
    job = hd(jobs)
    assert job.name == "Changed files route"
    assert job.duration_s == 38
    assert job.failed_step == nil
  end

  test "a rerun or a finished run has its jobs fetched again" do
    start_supervised!({Store, path: ":memory:"})
    run = %{repo: "o/r", run_id: 1, attempt: 1, status: "completed", conclusion: "failure"}

    :ok = Store.put_runs([run])
    assert Store.runs_missing_jobs("o/r", 10) == [1]

    :ok = Store.put_jobs("o/r", 1, [])
    :ok = Store.put_runs([run])
    assert Store.runs_missing_jobs("o/r", 10) == []

    :ok = Store.put_runs([%{run | attempt: 2}])
    assert Store.runs_missing_jobs("o/r", 10) == [1]
  end

  test "rates are weighted over the period, not averaged by day" do
    days = [%{ks: 1, ks_hits: 1}, %{ks: 99, ks_hits: 0}, nil]
    sums = Trends.merge(days)
    assert {sums.ks, sums.ks_hits} == {100, 1}
  end

  test "no change is shown without an earlier period to compare" do
    assert Trends.change(10, nil) == nil
    assert Trends.change(10, 0) == nil
    assert Trends.change(15, 10) == 50.0
  end

  test "builds every card from saved rows" do
    start_supervised!({Store, path: ":memory:"})
    now = DateTime.utc_now()
    at = DateTime.to_unix(now) - 3600

    Store.put_session(
      %{
        machine: "m",
        session_id: "s",
        ended_at: at,
        prompts: 3,
        korium_searches: 4,
        korium_search_hits: 3,
        korium_saves: 2,
        korium_save_errors: 1,
        tool_calls: 10,
        tool_errors: 1
      },
      [
        %{
          machine: "m",
          session_id: "s",
          request_id: "r",
          at: at,
          cost: 2.5,
          input_tokens: 10,
          cache_read_tokens: 90,
          cache_write_tokens: 0
        }
      ]
    )

    Store.put_runs([
      %{
        repo: "acme/shop",
        run_id: 1,
        workflow: "ci.yml",
        status: "completed",
        conclusion: "success",
        created_at: at,
        duration_s: 600
      },
      %{
        repo: "acme/shop",
        run_id: 2,
        workflow: "ci.yml",
        status: "completed",
        conclusion: "failure",
        created_at: at,
        duration_s: 60
      }
    ])

    t = Trends.build(Wallboard.Settings.merge(settings(), %{}), 7, now)
    card = fn key -> Enum.find(t.cards, &(&1.key == key)) end

    assert card.(:spend).value == 2.5
    assert card.(:cache_hit).value == 90.0
    assert card.(:korium_found).value == 75.0
    assert card.(:korium_saved).value == 50.0
    assert card.(:tool_failed).value == 10.0
    assert card.(:runs).value == 2
    assert card.(:run_failed).value == 50.0
    assert card.(:gate_time).value == 10.0
    assert length(card.(:spend).series) == 7
    assert card.(:spend).change == nil

    off = Trends.build(Map.put(settings(), :korium, %{enabled: false}), 7, now)
    refute Enum.any?(off.cards, &(&1.group == :korium))
    assert Enum.any?(off.cards, &(&1.group == :github))
  end

  test "a period that spans old uploads and new streaming counts every session once" do
    start_supervised!({Store, path: ":memory:"})
    now = DateTime.utc_now()
    day = 86_400
    at = DateTime.to_unix(now)

    put = fn machine, id, source, ended_at ->
      :ok =
        Store.put_session(
          %{
            machine: machine,
            session_id: id,
            source: source,
            tool: "claude",
            ended_at: ended_at,
            prompts: 1,
            tool_calls: 10
          },
          [
            %{
              machine: machine,
              session_id: id,
              request_id: "r-" <> id,
              at: ended_at,
              cost: 1.0,
              input_tokens: 10,
              cache_read_tokens: 0,
              cache_write_tokens: 0
            }
          ]
        )
    end

    # Three days ago 0.2.0 was still on the machine: two sessions came as
    # uploads, under the name the machine gave itself.
    put.("build-box.local", "only-uploaded", "upload", at - 3 * day)
    put.("build-box.local", "both-ways", "upload", at - 3 * day)
    # The hub's own session, read from its own files.
    put.("the-hub", "local", nil, at - 2 * day)
    # Then the collector: it streams a new session, and the one that was
    # still open when the machine moved across, under its certificate's name.
    put.("build-box", "only-streamed", "stream", at - 3600)
    put.("build-box", "both-ways", "stream", at - 3600)

    saved =
      Store.query("SELECT machine, session_id, source FROM sessions ORDER BY session_id", [])

    assert Enum.map(saved, &{&1.session_id, &1.machine, &1.source}) == [
             {"both-ways", "build-box", "stream"},
             {"local", "the-hub", nil},
             {"only-streamed", "build-box", "stream"},
             {"only-uploaded", "build-box.local", "upload"}
           ]

    t = Trends.build(Wallboard.Settings.merge(settings(), %{}), 7, now)
    card = fn key -> Enum.find(t.cards, &(&1.key == key)) end

    # Four sessions, each one's dollar and its ten tool calls counted once.
    assert card.(:sessions).value == 4
    assert card.(:spend).value == 4.0
    assert Store.counts().total == 4
    assert [%{n: 4}] = Store.query("SELECT count(*) AS n FROM requests", [])
  end

  defp settings do
    %{
      archive: %{backfill_days: 14},
      github: %{
        repo: "acme/shop",
        gate_workflow: "ci.yml",
        dev_deploy: "deploy-staging.yml",
        prod_deploy: "deploy-production.yml"
      }
    }
  end
end
