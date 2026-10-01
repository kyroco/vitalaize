defmodule Wallboard.Sources.GitHub do
  @moduledoc """
  GitHub Actions for each repository in settings, through the signed-in `gh`
  CLI. Up to four repositories are read at once.

  Each poll makes, per repository:
    * one REST call for every run created in the last 24 hours
    * one GraphQL call for the merge queue and the open pull requests
    * one REST call per run in progress, for its jobs (the step it is on)
    * every `deploy_poll_seconds`, one REST call for the repository's
      workflow files and one per deploy workflow among them, so the last dev
      and prod deploys show even when they are days old

  At the default 30 seconds with two runs going that is about 600 calls an
  hour for each repository, so six repositories stay inside GitHub's 5,000.

  A repository's gate and deploy workflows are its own (see
  `Wallboard.Settings.github_repos/1`). One with no gate workflow, or whose
  gate file is not among its workflow files, gets main's state from the
  latest finished runs on its main branch.

  The facts are `%{repos: [%{repo: "owner/name", facts: ..., error: ...}]}`
  in settings order. A repository whose read fails keeps its last facts with
  the reason; only when every one fails is the whole poll an error.
  """

  alias Wallboard.{Cmd, Settings}

  @gql """
  query($owner: String!, $name: String!, $branch: String!) {
    repository(owner: $owner, name: $name) {
      mergeQueue(branch: $branch) {
        entries(first: 20) { nodes { position state enqueuedAt pullRequest { number title } } }
      }
      pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
        nodes {
          number title isDraft updatedAt
          commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
            __typename
            ... on CheckRun { name status conclusion startedAt completedAt }
            ... on StatusContext { context state }
          } } } } } }
        }
      }
    }
  }
  """

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(settings, prev, memory, now) do
    before = Map.new((prev && prev[:repos]) || [], &{&1.repo, &1.facts})

    entries =
      settings
      |> Settings.github_repos()
      |> Task.async_stream(fn gh -> {gh.repo, fetch(gh, before[gh.repo], now)} end,
        max_concurrency: 4,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {repo, result}} ->
        case result do
          {:ok, facts} -> %{repo: repo, facts: facts, error: nil}
          {:error, reason} -> %{repo: repo, facts: before[repo], error: reason}
        end
      end)

    if entries != [] and Enum.all?(entries, & &1.error),
      do: {:error, errors_text(entries), memory},
      else: {:ok, %{repos: entries}, memory}
  end

  @doc """
  How long a poll may take before it counts as stuck: repositories are read
  four at a time, so each group of four gets its own two minutes.
  """
  def timeout_ms(settings) do
    groups = max(div(length(Settings.repo_names(settings)) + 3, 4), 1)
    60_000 + 120_000 * groups
  end

  defp errors_text([one]), do: one.error
  defp errors_text(entries), do: Enum.map_join(entries, "; ", &"#{&1.repo}: #{&1.error}")

  # When the deploys were last checked is bookkeeping, not news.
  def fingerprint(%{repos: entries}) do
    Enum.map(entries, fn e ->
      %{e | facts: e.facts && Map.delete(e.facts, :deploys_checked_at)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Fetching

  @doc """
  One repository's facts: {:ok, facts} or {:error, reason}. `gh` is that
  repository's settings (see Settings.github_repos/1); `prev` is its previous
  facts, used to skip the slower deploy calls between their turns.
  """
  def fetch(gh, prev, now) do
    since =
      now
      |> DateTime.add(-24 * 3600, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    with {:ok, runs_json} <-
           api(["repos/#{gh.repo}/actions/runs?per_page=100&created=>=#{since}"]),
         {:ok, runs} <- parse_runs(runs_json),
         {:ok, gql_json} <- graphql(gh),
         {:ok, repo} <- parse_graphql(gql_json, gh.gate_check) do
      deploys = fetch_deploys(gh, prev, now)

      jobs =
        runs
        |> Enum.filter(&(&1.status == :in_progress))
        |> Map.new(fn run ->
          case api(["repos/#{gh.repo}/actions/runs/#{run.id}/jobs?per_page=100"]) do
            {:ok, json} -> {run.id, parse_jobs(json)}
            {:error, _} -> {run.id, nil}
          end
        end)

      {:ok,
       %{
         runs: runs,
         deploys: deploys.runs,
         deploys_checked_at: deploys.checked_at,
         workflows: deploys.workflows,
         queue: repo.queue,
         prs: repo.prs,
         jobs: jobs
       }}
    end
  end

  defp fetch_deploys(gh, prev, now) do
    fresh? =
      prev && prev[:deploys_checked_at] &&
        DateTime.diff(now, prev.deploys_checked_at, :second) < gh.deploy_poll_seconds

    if fresh? do
      %{runs: prev.deploys, checked_at: prev.deploys_checked_at, workflows: prev[:workflows]}
    else
      # The repository's workflow files, or nil when they are not known:
      # then every file named in settings is taken to be there. They are
      # not asked for when settings name none to look for, and when the
      # call fails the last list read is kept.
      workflows =
        if gh.gate_workflow in [nil, ""] and gh.deploy_workflows == [] do
          nil
        else
          with {:ok, json} <- api(["repos/#{gh.repo}/actions/workflows?per_page=100"]),
               {:ok, files} <- parse_workflows(json) do
            files
          else
            _ -> prev && prev[:workflows]
          end
        end

      # A deploy file the repository does not have is not asked for: the
      # call would fail every time and spend GitHub's hourly limit on
      # nothing.
      asked = Enum.filter(gh.deploy_workflows, &(is_nil(workflows) or &1 in workflows))

      runs =
        asked
        |> Enum.flat_map(fn file ->
          case api(["repos/#{gh.repo}/actions/workflows/#{file}/runs?per_page=10"]) do
            {:ok, json} ->
              case parse_runs(json) do
                {:ok, runs} -> runs
                _ -> []
              end

            _ ->
              []
          end
        end)

      # If every deploy call failed, keep what we had rather than blanking the
      # tiles, and wait the usual time before asking again. With no deploy
      # file to ask for there is nothing to keep.
      if asked != [] and runs == [] and prev,
        do: %{runs: prev.deploys, checked_at: now, workflows: workflows},
        else: %{runs: runs, checked_at: now, workflows: workflows}
    end
  end

  defp api(args), do: Cmd.run("gh", ["api" | args], timeout: 30_000)

  defp graphql(gh) do
    [owner, name] = String.split(gh.repo, "/", parts: 2)

    Cmd.run(
      "gh",
      [
        "api",
        "graphql",
        "-f",
        "query=" <> @gql,
        "-F",
        "owner=" <> owner,
        "-F",
        "name=" <> name,
        "-F",
        "branch=" <> gh.branch
      ],
      timeout: 30_000
    )
  end

  # ---------------------------------------------------------------------------
  # Parsing (pure, tested against saved real output)

  @doc "Parses a list of workflow runs from the REST API."
  def parse_runs(text) do
    case Jason.decode(text) do
      {:ok, %{"workflow_runs" => runs}} when is_list(runs) -> {:ok, Enum.map(runs, &run/1)}
      {:ok, _} -> {:error, "GitHub returned runs in an unexpected shape"}
      {:error, _} -> {:error, "GitHub returned something that is not JSON"}
    end
  end

  defp run(r) do
    status =
      case r["status"] do
        "completed" -> :completed
        "in_progress" -> :in_progress
        _ -> :queued
      end

    %{
      id: r["id"],
      name: short_name(r["name"]),
      workflow: r["path"] && Path.basename(r["path"]),
      title: r["display_title"],
      event: r["event"],
      branch: r["head_branch"],
      sha: r["head_sha"] && String.slice(r["head_sha"], 0, 9),
      status: status,
      conclusion: r["conclusion"],
      started_at: time(r["run_started_at"]) || time(r["created_at"]),
      created_at: time(r["created_at"]),
      updated_at: time(r["updated_at"]),
      pr: pr_number(r),
      url: r["html_url"]
    }
  end

  @doc """
  Parses the list of a repository's workflows from the REST API into their
  file names, like "ci.yml". A list that is only the first page of more is
  an error: a file missing from it would be taken for one the repository
  does not have.
  """
  def parse_workflows(text) do
    case Jason.decode(text) do
      {:ok, %{"workflows" => list} = body} when is_list(list) ->
        if is_integer(body["total_count"]) and body["total_count"] > length(list),
          do: {:error, "GitHub lists more workflows than one page holds"},
          else:
            {:ok, for(%{"path" => path} when is_binary(path) <- list, do: Path.basename(path))}

      _ ->
        {:error, "GitHub returned workflows in an unexpected shape"}
    end
  end

  @doc "Drops the parenthetical tail GitHub workflow names often carry."
  def short_name(nil), do: "Workflow"
  def short_name(name), do: name |> String.replace(~r/\s*\(.*\)\s*$/, "") |> String.trim()

  defp pr_number(%{"pull_requests" => [%{"number" => n} | _]}), do: n

  defp pr_number(%{"head_branch" => branch}) when is_binary(branch) do
    case Regex.run(~r/pr-(\d+)/, branch) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp pr_number(_), do: nil

  @doc "Summarizes a run's jobs: how many are done and what is running now."
  def parse_jobs(text) do
    case Jason.decode(text) do
      {:ok, %{"jobs" => jobs}} when is_list(jobs) ->
        current = Enum.find(jobs, &(&1["status"] == "in_progress"))

        step =
          current &&
            (current["steps"] || [])
            |> Enum.find(&(&1["status"] == "in_progress"))
            |> then(&(&1 && &1["name"]))

        %{
          total: length(jobs),
          done: Enum.count(jobs, &(&1["status"] == "completed")),
          current_job: current && current["name"],
          current_step: step
        }

      _ ->
        nil
    end
  end

  @doc "Parses the merge queue and open pull requests with their gate check."
  def parse_graphql(text, gate_check) do
    case Jason.decode(text) do
      {:ok, %{"data" => %{"repository" => repo}}} when is_map(repo) ->
        queue =
          (get_in(repo, ["mergeQueue", "entries", "nodes"]) || [])
          |> Enum.map(fn e ->
            %{
              position: e["position"],
              state: e["state"],
              enqueued_at: time(e["enqueuedAt"]),
              pr: get_in(e, ["pullRequest", "number"]),
              title: get_in(e, ["pullRequest", "title"])
            }
          end)
          |> Enum.sort_by(& &1.position)

        prs =
          (get_in(repo, ["pullRequests", "nodes"]) || [])
          |> Enum.map(fn p ->
            contexts =
              get_in(p, [
                "commits",
                "nodes",
                Access.at(0),
                "commit",
                "statusCheckRollup",
                "contexts",
                "nodes"
              ]) || []

            %{
              number: p["number"],
              title: p["title"],
              draft: p["isDraft"] == true,
              updated_at: time(p["updatedAt"]),
              gate: gate_state(contexts, gate_check)
            }
          end)

        {:ok, %{queue: queue, prs: prs}}

      {:ok, %{"errors" => [%{"message" => msg} | _]}} ->
        {:error, "GitHub GraphQL: " <> msg}

      _ ->
        {:error, "GitHub GraphQL returned an unexpected shape"}
    end
  end

  defp gate_state(contexts, gate_check) do
    want = String.downcase(gate_check)

    case Enum.find(contexts, &(String.downcase(&1["name"] || &1["context"] || "") == want)) do
      nil ->
        :none

      %{"status" => "COMPLETED", "conclusion" => c} when c in ["SUCCESS", "NEUTRAL", "SKIPPED"] ->
        :passed

      %{"status" => "COMPLETED"} ->
        :failed

      %{"state" => "SUCCESS"} ->
        :passed

      %{"state" => s} when s in ["FAILURE", "ERROR"] ->
        :failed

      _ ->
        :running
    end
  end

  # ---------------------------------------------------------------------------
  # Summary for the board (pure). Everything here depends on `now`, so the
  # page recomputes it on its own clock; the poller only compares the facts.

  @doc "One repository's summary. `gh` is its settings (see Settings.github_repos/1)."
  def summary(facts, gh, now) do
    all = Enum.uniq_by(facts.runs ++ facts.deploys, & &1.id)
    typical = typical_durations(all)

    running =
      all
      |> Enum.filter(&(&1.status in [:in_progress, :queued]))
      |> Enum.sort_by(&DateTime.to_unix(&1.started_at || now))
      |> Enum.map(&running_run(&1, facts.jobs[&1.id], typical, now))

    completed =
      all |> Enum.filter(&(&1.status == :completed)) |> Enum.sort_by(&unix(&1.updated_at), :desc)

    day_ago = DateTime.add(now, -24 * 3600, :second)

    # Pull request runs have their own row, and "dynamic" runs are GitHub's
    # own Dependabot jobs, so neither counts as a build failure here.
    failures =
      completed
      |> Enum.filter(
        &(&1.conclusion == "failure" and &1.event not in ["pull_request", "dynamic"])
      )
      |> Enum.filter(&(DateTime.compare(&1.updated_at, day_ago) == :gt))

    gate = gate_workflow(gh, facts[:workflows])
    {rows, more} = lanes(all, gh.lanes, now)

    %{
      main: main_state(all, completed, gate, gh.branch),
      # Whether main's state is the gate workflow's or, with none, what the
      # latest runs on main say.
      main_from: if(gate, do: :gate, else: :runs),
      queue: facts.queue,
      last_merge:
        Enum.find(
          completed,
          &((is_nil(gate) or &1.workflow == gate) and &1.event == "merge_group" and
              &1.conclusion == "success")
        ),
      running: running,
      failures: failures,
      dev: deploy_state(all, gh.dev_deploy),
      prod: deploy_state(all, gh.prod_deploy),
      recent: completed |> Enum.take(6) |> Enum.map(&recent_run(&1, gh)),
      prs: facts.prs,
      lanes: rows,
      # How many more workflows ran in the window than the rows shown.
      lanes_more: more
    }
  end

  @doc """
  Every repository in settings order, as the board shows it:
  `%{repo, name, error, s, hot?, last_at}`, where `s` is its summary (nil
  until its first read) and `name` is the short name, like "api", unless
  two repositories share it.
  """
  def repos(facts, settings, now) do
    got = Map.new((facts && facts[:repos]) || [], &{&1.repo, &1})
    configs = Settings.github_repos(settings)
    short = configs |> Enum.map(&short_repo/1) |> Enum.frequencies()

    Enum.map(configs, fn gh ->
      entry = got[gh.repo] || %{facts: nil, error: nil}
      s = entry.facts && summary(entry.facts, gh, now)
      name = short_repo(gh)

      %{
        repo: gh.repo,
        name: if(short[name] > 1, do: gh.repo, else: name),
        error: entry.error,
        s: s,
        hot?: hot?(s, now),
        last_at: s && last_activity(s)
      }
    end)
  end

  defp short_repo(%{repo: repo}), do: repo |> String.split("/") |> List.last()

  # Busy enough for a column: something running, main red, or a build
  # failure in the last 6 hours (the span of the column's timeline).
  defp hot?(nil, _now), do: false

  defp hot?(s, now) do
    six_hours_ago = DateTime.add(now, -6 * 3600, :second)

    s.running != [] or red?(s.main) or
      Enum.any?(s.failures, &(DateTime.compare(&1.updated_at, six_hours_ago) == :gt))
  end

  defp red?(%{conclusion: "failure"}), do: true
  defp red?(_), do: false

  defp last_activity(s) do
    (Enum.map(s.running, & &1.started_at) ++ Enum.map(s.recent, & &1.updated_at))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  @doc """
  Splits the repositories into the ones that get a column and the quiet
  rest. The `max` busiest get columns: anything running or failed first,
  then the most recent run, then settings order. Both lists keep settings
  order, so a column moves only when another repository takes its place.
  """
  def arrange(repos, max \\ 4) do
    chosen =
      repos
      |> Enum.with_index()
      |> Enum.sort_by(fn {r, i} -> {if(r.hot?, do: 0, else: 1), -unix(r.last_at), i} end)
      |> Enum.take(max)
      |> MapSet.new(fn {r, _} -> r.repo end)

    Enum.split_with(repos, &MapSet.member?(chosen, &1.repo))
  end

  @doc """
  The status line's numbers across every repository: how many have a green
  main and which are red, the merge queues, what is running and what failed.
  """
  def totals(repos) do
    loaded = Enum.filter(repos, & &1.s)

    %{
      count: length(repos),
      green: Enum.filter(loaded, &match?(%{s: %{main: %{conclusion: "success"}}}, &1)),
      red: Enum.filter(loaded, &red?(&1.s.main)),
      unknown: Enum.filter(repos, &(is_nil(&1.s) or is_nil(&1.s.main))),
      queued: Enum.filter(loaded, &(&1.s.queue != [])),
      running: Enum.filter(loaded, &(&1.s.running != [])),
      failures:
        loaded
        |> Enum.flat_map(fn r -> Enum.map(r.s.failures, &Map.put(&1, :repo_name, r.name)) end)
        |> Enum.sort_by(&unix(&1.updated_at), :desc)
    }
  end

  @doc "Each workflow's runs from the last day and the deploy history, newest first."
  def by_workflow(facts) do
    (facts.runs ++ facts.deploys)
    |> Enum.uniq_by(& &1.id)
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, runs} ->
      {name,
       Enum.sort_by(runs, &unix(&1.updated_at || &1.started_at), :desc)
       |> Enum.map(&Map.merge(&1, %{what: what(&1), took: duration(&1)}))}
    end)
    |> Enum.sort_by(fn {_, [latest | _]} -> -unix(latest.updated_at || latest.started_at) end)
  end

  # The repository's gate workflow file, or nil when it names none or has
  # no such file. `workflows` is its workflow files, nil when not known.
  defp gate_workflow(%{gate_workflow: file}, workflows) when is_binary(file) and file != "" do
    if is_nil(workflows) or file in workflows, do: file
  end

  defp gate_workflow(_gh, _workflows), do: nil

  # The run that says how main is: the latest finished gate run.
  defp main_state(_all, completed, gate, branch) when is_binary(gate) do
    Enum.find(completed, fn r ->
      r.workflow == gate and r.conclusion in ["success", "failure"] and
        (r.event == "merge_group" or (r.event == "push" and r.branch == branch))
    end)
  end

  # With no gate, main's state comes from the pushes to main. Only "push"
  # runs on the main branch count: a pull request's run can carry a branch
  # of the same name, and a nightly or a bot's run says nothing about the
  # commit. The workflows looked at are the ones that ran on the newest
  # commit, and each speaks through its newest finished run on main, so a
  # workflow still running on the newest commit keeps what it said about
  # the commit before. Main is red when one of them failed and green when
  # all passed; the run returned is the failed one, or the one that
  # finished last. A run made again keeps its place: its first start is
  # what orders it.
  defp main_state(all, _completed, nil, branch) do
    on_main =
      Enum.filter(all, &(&1.event == "push" and &1.branch == branch and is_binary(&1.sha)))

    made = &unix(&1[:created_at] || &1.started_at)
    flow = &(&1.workflow || &1.name)

    case Enum.max_by(on_main, made, fn -> nil end) do
      nil ->
        nil

      newest ->
        here = on_main |> Enum.filter(&(&1.sha == newest.sha)) |> MapSet.new(flow)

        latest =
          on_main
          |> Enum.filter(fn r ->
            r.status == :completed and r.conclusion in ["success", "failure"] and
              MapSet.member?(here, flow.(r))
          end)
          |> Enum.sort_by(made, :desc)
          |> Enum.uniq_by(flow)

        Enum.find(
          latest,
          Enum.max_by(latest, &unix(&1.updated_at), fn -> nil end),
          &(&1.conclusion == "failure")
        )
    end
  end

  defp deploy_state(all, file) do
    runs =
      all
      |> Enum.filter(&(is_binary(file) and &1.workflow == file))
      |> Enum.sort_by(&unix(&1.started_at), :desc)

    %{
      latest: List.first(runs),
      last_success: Enum.find(runs, &(&1.status == :completed and &1.conclusion == "success"))
    }
  end

  defp running_run(run, jobs, typical, now) do
    elapsed = if run.started_at, do: max(DateTime.diff(now, run.started_at, :second), 0), else: 0
    typical_s = typical[run.workflow]

    progress =
      cond do
        run.status == :queued -> 0
        typical_s && typical_s > 0 -> min(round(elapsed * 100 / typical_s), 97)
        jobs && jobs.total > 0 -> round(jobs.done * 100 / jobs.total)
        true -> 10
      end

    step =
      cond do
        run.status == :queued ->
          "Waiting for a runner"

        jobs && jobs.current_job ->
          [jobs.current_job, jobs.current_step]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(": ")
          |> Kernel.<>(", #{jobs.done} of #{jobs.total} jobs done")

        jobs ->
          "#{jobs.done} of #{jobs.total} jobs done"

        true ->
          "Starting"
      end

    Map.merge(run, %{
      what: what(run),
      elapsed: elapsed,
      progress: progress,
      step: step,
      typical: typical_s
    })
  end

  defp recent_run(run, gh) do
    label =
      cond do
        run.event == "merge_group" -> run.name <> " · merge queue"
        run.workflow in gh.deploy_workflows and run.branch == gh.branch -> run.name
        true -> run.name
      end

    Map.merge(run, %{label: label, what: what(run), took: duration(run)})
  end

  @doc "A one-line description of what a run was for."
  def what(%{event: "merge_group", pr: pr}) when is_integer(pr), do: "##{pr} in the merge queue"
  def what(%{event: "pull_request", pr: pr, title: t}) when is_integer(pr), do: "##{pr} #{t}"

  def what(%{title: t, name: n, sha: sha, branch: b}) do
    if is_nil(t) or short_name(t) == n, do: "#{sha} on #{b}", else: t
  end

  def duration(%{started_at: %DateTime{} = s, updated_at: %DateTime{} = e}),
    do: max(DateTime.diff(e, s, :second), 0)

  def duration(_), do: nil

  # Median of successful runs per workflow, to estimate how far along a
  # running one is.
  defp typical_durations(runs) do
    runs
    |> Enum.filter(&(&1.status == :completed and &1.conclusion == "success"))
    |> Enum.group_by(& &1.workflow)
    |> Map.new(fn {wf, rs} ->
      ds = rs |> Enum.map(&duration/1) |> Enum.reject(&is_nil/1) |> Enum.sort()
      {wf, if(ds == [], do: nil, else: Enum.at(ds, div(length(ds), 2)))}
    end)
  end

  # The most rows the timeline shows.
  @max_lanes 6

  # The timeline's rows: one for each workflow with a run in the last 6
  # hours. The repository's own rows (`lanes` in its settings) come first, in
  # their order and under their labels; then every other workflow that ran,
  # the latest first, under its name, up to `@max_lanes` rows in all.
  # Returns the rows and how many more workflows ran, so no rows means
  # nothing ran.
  defp lanes(all, lanes, now) do
    window_start = DateTime.add(now, -6 * 3600, :second)
    ended = fn r -> if r.status == :completed, do: r.updated_at || r.started_at, else: now end

    in_window =
      Enum.filter(all, &(&1.started_at && DateTime.compare(ended.(&1), window_start) == :gt))

    bar = fn r ->
      %{
        id: r.id,
        start: DateTime.diff(r.started_at, window_start, :second),
        length: max(DateTime.diff(ended.(r), r.started_at, :second), 0),
        kind:
          cond do
            r.status != :completed -> :run
            r.conclusion == "failure" -> :fail
            r.conclusion == "success" -> :pass
            true -> :other
          end
      }
    end

    named = lanes |> Enum.flat_map(& &1.workflows) |> MapSet.new()

    own =
      for lane <- lanes,
          runs = Enum.filter(in_window, &(&1.workflow in lane.workflows)),
          runs != [],
          do: %{label: lane.label, bars: Enum.map(runs, bar)}

    others =
      in_window
      |> Enum.reject(&MapSet.member?(named, &1.workflow))
      |> Enum.group_by(&(&1.workflow || &1.name))
      |> Enum.map(fn {_, runs} ->
        latest = Enum.max_by(runs, &unix(ended.(&1)))
        {unix(ended.(latest)), %{label: latest.name, bars: Enum.map(runs, bar)}}
      end)
      |> Enum.sort_by(fn {at, row} -> {-at, row.label} end)
      |> Enum.map(&elem(&1, 1))

    # The repository's own rows are never cut: they are the ones it chose.
    {shown, rest} = Enum.split(others, max(@max_lanes - length(own), 0))
    {own ++ shown, length(rest)}
  end

  defp unix(nil), do: 0
  defp unix(dt), do: DateTime.to_unix(dt)

  defp time(nil), do: nil

  defp time(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
