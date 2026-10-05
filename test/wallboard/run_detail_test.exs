defmodule Wallboard.RunDetailTest do
  # The Git tab's run panel, on the real board page. A stand-in gh on the
  # PATH answers a run's jobs and keeps what it was asked, and it can be
  # held until the test lets it answer. One at a time: the PATH, the
  # settings and the endpoint are this whole test run's.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias Wallboard.{Fixtures, Settings, Store}
  alias Wallboard.Sources.GitHub

  @endpoint WallboardWeb.Endpoint
  @repo "acme/api"

  setup do
    dir = Fixtures.tmp_path("wallboard-run-detail")
    File.mkdir_p!(dir)

    # Answers a run's jobs with jobs.json, once a file named "go" is there.
    File.write!(Path.join(dir, "gh"), """
    #!/bin/sh
    echo "$2" >> "$WALLBOARD_TEST_GH/asked"
    while [ ! -f "$WALLBOARD_TEST_GH/go" ]; do sleep 0.05; done
    case "$2" in
      *"/jobs?"*) cat "$WALLBOARD_TEST_GH/jobs.json" ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac
    """)

    File.chmod!(Path.join(dir, "gh"), 0o755)
    File.write!(Path.join(dir, "jobs.json"), jobs_json(finished_jobs()))

    old = {System.get_env("PATH"), System.get_env("WALLBOARD_TEST_GH")}
    System.put_env("PATH", dir <> ":" <> elem(old, 0))
    System.put_env("WALLBOARD_TEST_GH", dir)

    old_settings = :persistent_term.get({Settings, :settings}, nil)

    endpoint = Application.get_env(:wallboard, @endpoint, [])

    Application.put_env(
      :wallboard,
      @endpoint,
      Keyword.merge(endpoint, secret_key_base: String.duplicate("k", 64), server: false)
    )

    start_supervised!(@endpoint)

    on_exit(fn ->
      System.put_env("PATH", elem(old, 0))

      if elem(old, 1),
        do: System.put_env("WALLBOARD_TEST_GH", elem(old, 1)),
        else: System.delete_env("WALLBOARD_TEST_GH")

      if old_settings,
        do: :persistent_term.put({Settings, :settings}, old_settings),
        else: :persistent_term.erase({Settings, :settings})

      Application.put_env(:wallboard, @endpoint, endpoint)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp use_settings(archive?) do
    settings =
      Settings.merge(Settings.defaults(), %{
        github: %{repos: [@repo], gate_workflow: nil, deploy_workflows: []},
        archive: %{enabled: archive?, collect_local: false, advertise: false},
        new_relic: %{enabled: false}
      })

    :persistent_term.put({Settings, :settings}, settings)
  end

  defp open_board do
    conn =
      put_connect_params(build_conn(), %{
        "asset_version" => WallboardWeb.Layouts.asset_version()
      })

    {:ok, view, _html} = live_isolated(conn, WallboardWeb.BoardLive, session: %{})
    view
  end

  # ---------------------------------------------------------------------------
  # Made-up acme data, as GitHub sends it

  defp iso(seconds_ago),
    do: DateTime.utc_now() |> DateTime.add(-seconds_ago) |> DateTime.to_iso8601()

  defp run_json(id, status, conclusion, opts \\ []) do
    %{
      "id" => id,
      "name" => Keyword.get(opts, :name, "Gate"),
      "path" => ".github/workflows/gate.yml",
      "display_title" => "Fix the login redirect",
      "event" => "push",
      "head_branch" => "main",
      "head_sha" => "a1b2c3d4e5f60718",
      "status" => status,
      "conclusion" => conclusion,
      "run_attempt" => Keyword.get(opts, :attempt, 1),
      "run_started_at" => iso(900),
      "created_at" => iso(900),
      "updated_at" => iso(468),
      "html_url" => "https://github.com/acme/api/actions/runs/#{id}",
      "pull_requests" => [],
      "actor" => %{"login" => "dana"},
      "triggering_actor" => %{"login" => Keyword.get(opts, :started_by, "dana")},
      "head_commit" => %{"message" => "Fix the login redirect\n\nLonger words below."}
    }
  end

  defp facts(runs, jobs \\ %{}) do
    {:ok, runs} = GitHub.parse_runs(Jason.encode!(%{"workflow_runs" => runs}))

    %{
      repos: [
        %{
          repo: @repo,
          error: nil,
          facts: %{
            runs: runs,
            deploys: [],
            deploys_checked_at: DateTime.utc_now(),
            workflows: nil,
            queue: [],
            prs: [],
            jobs: jobs
          }
        }
      ]
    }
  end

  defp send_facts(view, facts) do
    meta = %{fetched_at: DateTime.utc_now(), error: nil, interval: 30_000}
    send(view.pid, {:source, :github, facts, meta})
    render(view)
  end

  defp job(id, name, status, conclusion, opts \\ []) do
    %{
      "id" => id,
      "run_id" => Keyword.get(opts, :run_id, 101),
      "run_attempt" => 1,
      "name" => name,
      "status" => status,
      "conclusion" => conclusion,
      "created_at" => iso(Keyword.get(opts, :created, 900)),
      "started_at" => opts[:started] && iso(opts[:started]),
      "completed_at" => opts[:completed] && iso(opts[:completed]),
      "runner_name" => opts[:runner],
      "labels" => ["ubuntu-latest"],
      "steps" => Keyword.get(opts, :steps, [])
    }
  end

  defp jobs_json(jobs), do: Jason.encode!(%{"total_count" => length(jobs), "jobs" => jobs})

  defp finished_jobs do
    [
      job(1, "Build", "completed", "success",
        started: 890,
        completed: 760,
        runner: "GitHub Actions 12"
      ),
      job(2, "Tests", "completed", "failure",
        started: 750,
        completed: 470,
        runner: "gate-air-1",
        steps: [
          %{"name" => "Set up", "conclusion" => "success"},
          %{"name" => "Run mix test", "conclusion" => "failure"}
        ]
      ),
      job(3, "Deploy", "completed", "skipped")
    ]
  end

  defp asked(dir) do
    case File.read(Path.join(dir, "asked")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------

  test "a finished run's panel shows its jobs and the failed step from the archive, with no call",
       %{dir: dir} do
    use_settings(true)
    start_supervised!({Store, path: ":memory:"})
    rows = Wallboard.Archive.GitHubCollector.job_rows(finished_jobs(), @repo, 101)
    :ok = Store.put_jobs(@repo, 101, rows)
    File.write!(Path.join(dir, "go"), "")

    view = open_board()
    send_facts(view, facts([run_json(101, "completed", "failure")]))

    html = view |> element(~s|button.recent-row[phx-value-id="101"]|) |> render_click()

    assert html =~ "detail-run"
    assert html =~ "Failed"
    assert html =~ "ran 7m"
    assert html =~ "branch main"
    assert html =~ "a1b2c3d4e"
    assert html =~ "Fix the login redirect"
    assert html =~ "by dana"
    refute html =~ "rerun by"
    assert html =~ "https://github.com/acme/api/actions/runs/101"
    assert html =~ "Jobs · 3"
    assert html =~ "failed at: Run mix test"
    assert html =~ "on gate-air-1"
    assert html =~ "on GitHub Actions 12"
    assert asked(dir) == []
  end

  test "a finished run whose jobs are not saved says loading, then shows them, with one call",
       %{dir: dir} do
    use_settings(true)
    start_supervised!({Store, path: ":memory:"})

    view = open_board()
    send_facts(view, facts([run_json(101, "completed", "failure", started_by: "sam")]))

    html = view |> element(~s|button.recent-row[phx-value-id="101"]|) |> render_click()
    assert html =~ "Loading jobs…"
    refute html =~ "failed at:"

    File.write!(Path.join(dir, "go"), "")
    html = render_async(view, 5_000)

    refute html =~ "Loading jobs…"
    assert html =~ "failed at: Run mix test"
    assert html =~ "by dana"
    assert html =~ "rerun by sam"
    assert asked(dir) == ["repos/acme/api/actions/runs/101/jobs?per_page=100"]

    # Saved in the archive for every screen, and not read again on a new
    # check, a close or a second tap.
    assert [_, _, _] = Store.run_jobs(@repo, 101, 1)
    send_facts(view, facts([run_json(101, "completed", "failure", started_by: "sam")]))
    view |> element(~s|button.close[phx-click="close_run"]|) |> render_click()
    html = view |> element(~s|button.recent-row[phx-value-id="101"]|) |> render_click()
    assert html =~ "failed at: Run mix test"
    assert length(asked(dir)) == 1
  end

  test "with the archive off, the one read is kept on that screen", %{dir: dir} do
    use_settings(false)
    File.write!(Path.join(dir, "go"), "")

    view = open_board()
    send_facts(view, facts([run_json(101, "completed", "failure")]))
    view |> element(~s|button.recent-row[phx-value-id="101"]|) |> render_click()
    html = render_async(view, 5_000)
    assert html =~ "failed at: Run mix test"

    view |> element(~s|button.close[phx-click="close_run"]|) |> render_click()
    html = view |> element(~s|button.recent-row[phx-value-id="101"]|) |> render_click()
    assert html =~ "failed at: Run mix test"
    assert length(asked(dir)) == 1
  end

  test "a failed read says so, and a new tap tries once more", %{dir: dir} do
    use_settings(false)
    File.write!(Path.join(dir, "jobs.json"), "not json")
    File.write!(Path.join(dir, "go"), "")

    view = open_board()
    send_facts(view, facts([run_json(101, "completed", "failure")]))
    view |> element(~s|button.recent-row[phx-value-id="101"]|) |> render_click()
    assert render_async(view, 5_000) =~ "Could not read the jobs"
    assert length(asked(dir)) == 1

    send_facts(view, facts([run_json(101, "completed", "failure")]))
    assert length(asked(dir)) == 1

    view |> element(~s|button.close[phx-click="close_run"]|) |> render_click()
    view |> element(~s|button.recent-row[phx-value-id="101"]|) |> render_click()
    render_async(view, 5_000)
    assert length(asked(dir)) == 2
  end

  test "a running run's panel follows the checks as jobs finish, with no call of its own",
       %{dir: dir} do
    use_settings(false)

    running = [
      job(1, "Build", "completed", "success", run_id: 202, started: 300, completed: 200),
      job(2, "Tests", "in_progress", nil, run_id: 202, started: 190, runner: "gate-air-1")
    ]

    done = [
      job(1, "Build", "completed", "success", run_id: 202, started: 300, completed: 200),
      job(2, "Tests", "completed", "success",
        run_id: 202,
        started: 190,
        completed: 10,
        runner: "gate-air-1"
      ),
      job(3, "Deploy", "queued", nil, run_id: 202, created: 5)
    ]

    run = run_json(202, "in_progress", nil)
    view = open_board()
    send_facts(view, facts([run], %{202 => GitHub.parse_jobs(jobs_json(running))}))

    html = view |> element(~s|button.run-card[phx-value-id="202"]|) |> render_click()
    assert html =~ "Running"
    assert html =~ "running for"
    assert html =~ "Jobs · 2"
    assert html =~ ~s|class="job-icon info-ink"|

    html = send_facts(view, facts([run], %{202 => GitHub.parse_jobs(jobs_json(done))}))
    assert html =~ "Jobs · 3"
    assert html =~ "3m"
    assert html =~ "waiting for a runner"
    refute html =~ ~s|class="job-icon info-ink"|
    assert asked(dir) == []
  end

  test "a run that finishes while its panel is open has its final jobs read once", %{dir: dir} do
    use_settings(false)
    File.write!(Path.join(dir, "go"), "")

    running = [job(2, "Tests", "in_progress", nil, run_id: 101, started: 190)]
    view = open_board()

    send_facts(
      view,
      facts([run_json(101, "in_progress", nil)], %{101 => GitHub.parse_jobs(jobs_json(running))})
    )

    view |> element(~s|button.run-card[phx-value-id="101"]|) |> render_click()
    send_facts(view, facts([run_json(101, "completed", "failure")]))
    html = render_async(view, 5_000)

    assert html =~ "failed at: Run mix test"
    assert length(asked(dir)) == 1
  end

  test "jobs show in the order they ran, waiting ones last, a running one with its step" do
    use_settings(false)

    jobs = [
      job(3, "Browser tests", "queued", nil, run_id: 202, created: 400),
      job(2, "Tests", "in_progress", nil,
        run_id: 202,
        created: 400,
        started: 190,
        steps: [
          %{"name" => "Set up", "status" => "completed", "conclusion" => "success"},
          %{"name" => "Run mix test", "status" => "in_progress", "conclusion" => nil}
        ]
      ),
      job(1, "Build", "completed", "success", run_id: 202, started: 380, completed: 200)
    ]

    view = open_board()

    send_facts(
      view,
      facts([run_json(202, "in_progress", nil)], %{202 => GitHub.parse_jobs(jobs_json(jobs))})
    )

    html = view |> element(~s|button.run-card[phx-value-id="202"]|) |> render_click()

    at = fn text -> html |> :binary.match(text) |> elem(0) end
    assert at.(">Build<") < at.(">Tests<")
    assert at.(">Tests<") < at.(">Browser tests<")
    assert html =~ "now: Run mix test"
  end

  test "a waiting run says it waits for a runner" do
    use_settings(false)
    view = open_board()
    send_facts(view, facts([run_json(303, "queued", nil)]))

    html = view |> element(~s|button.run-card[phx-value-id="303"]|) |> render_click()
    assert html =~ "Waiting for a runner"
  end

  test "the panel closes by a tap outside, by its button, and by itself", %{dir: dir} do
    use_settings(false)
    File.write!(Path.join(dir, "go"), "")
    view = open_board()
    send_facts(view, facts([run_json(101, "completed", "failure")]))
    tap = fn -> view |> element(~s|button.recent-row[phx-value-id="101"]|) |> render_click() end

    assert tap.() =~ "detail-run"
    html = view |> element(~s|div.detail-scrim[phx-click="close_run"]|) |> render_click()
    refute html =~ "detail-run"

    assert tap.() =~ "detail-run"
    html = view |> element(~s|button.close[phx-click="close_run"]|) |> render_click()
    refute html =~ "detail-run"

    assert tap.() =~ "detail-run"
    %{socket: socket} = :sys.get_state(view.pid)
    send(view.pid, {:back_to_live, socket.assigns.back_ref})
    refute render(view) =~ "detail-run"
  end

  test "a run opened from its repository's details sits on top, and closing it goes back",
       %{dir: dir} do
    use_settings(false)
    File.write!(Path.join(dir, "go"), "")
    view = open_board()
    send_facts(view, facts([run_json(101, "completed", "failure")]))

    view |> element(~s|button.repo-head[phx-value-repo="#{@repo}"]|) |> render_click()

    html =
      view
      |> element(~s|.detail tr.tap-row[phx-value-id="101"]|, "Gate")
      |> render_click()

    assert html =~ "detail-run"
    assert html =~ "Every workflow"

    html = view |> element(~s|button.close[phx-click="close_run"]|) |> render_click()
    refute html =~ "detail-run"
    assert html =~ "Every workflow"
  end

  test "a tap on a run the board no longer lists does nothing" do
    use_settings(false)
    view = open_board()
    send_facts(view, facts([run_json(101, "completed", "failure")]))

    refute render_click(view, "open_run", %{"repo" => @repo, "id" => "999"}) =~ "detail-run"

    refute render_click(view, "open_run", %{"repo" => "acme/other", "id" => "101"}) =~
             "detail-run"
  end
end
