defmodule Wallboard.Archive.GitHubCollector do
  @moduledoc """
  Saves GitHub Actions runs and their jobs into the database, so trends can
  go back further than the board's own 24-hour view.

  Every `github_poll_seconds` (5 minutes by default) one round:

    * on the very first round, saves the last `backfill_days` of runs, one
      day at a time (GitHub returns at most 1,000 runs for a filtered list,
      and a busy repo can pass that in two weeks)
    * saves the runs created since the day of the last good round (an hour
      early, and no further back than `backfill_days`), so runs created
      while the board was off are not lost, and always yesterday's and
      today's, which picks up runs that finished or were rerun since
    * saves the jobs of up to `github_jobs_per_round` finished runs that do
      not have them yet, newest first. At 100 every 5 minutes that is 1,200
      calls an hour, which with the board's own ~600 stays well inside
      GitHub's 5,000; two weeks of jobs fill in over about two hours.
    * once a day, reads whether each repository is public and its default
      branch, for `Wallboard.Archive.CiMinutes`
    * saves the closed pull requests changed since the last good read of
      them (the last `backfill_days` on the first round), newest first, 100
      a call: usually one call. `Wallboard.Archive.PullRequests` reads them.
      A failed read keeps the round's runs, and its reason shows on the
      Shipped heading until a read works.

  A run that is rerun or finishes gets its jobs fetched again, every
  attempt's, since each attempt is billed.
  """

  use GenServer
  require Logger

  alias Wallboard.{Cmd, Store}
  alias Wallboard.Archive.CiMinutes

  # The most pages of 100 pull requests one round reads.
  @pr_pages 100

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :round)
    {:ok, %{task: nil}}
  end

  @impl true
  def handle_info(:round, %{task: nil} = state) do
    settings = Wallboard.Settings.get()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    task =
      Task.Supervisor.async_nolink(Wallboard.TaskSupervisor, fn -> round(settings, now) end)

    {:noreply, %{state | task: task}}
  end

  def handle_info(:round, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, runs, jobs} when runs + jobs > 0 ->
        Logger.info("GitHub archive: saved #{runs} runs and the jobs of #{jobs}")

      {:error, reason} ->
        Logger.warning("GitHub archive: " <> reason)

      _ ->
        :ok
    end

    Phoenix.PubSub.broadcast(Wallboard.PubSub, Wallboard.Poller.topic(), {:archive, :github})
    schedule()
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("GitHub archive: the round crashed: #{inspect(reason)}")
    schedule()
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp schedule do
    Process.send_after(
      self(),
      :round,
      Wallboard.Settings.get().archive.github_poll_seconds * 1000
    )
  end

  # ---------------------------------------------------------------------------
  # One round

  @doc """
  Runs one round for every repository, sharing `github_jobs_per_round`
  between them. Returns {:ok, runs_saved, runs_with_jobs_saved} or
  {:error, reason} when every repository failed.
  """
  def round(settings, now) do
    repos = Wallboard.Settings.repo_names(settings)
    jobs_each = max(div(settings.archive.github_jobs_per_round, max(length(repos), 1)), 1)

    {ok, failed} =
      repos
      |> Enum.map(fn repo ->
        case round(repo, jobs_each, settings, now) do
          {:error, why} -> {:error, "#{repo}: #{why}"}
          done -> done
        end
      end)
      |> Enum.split_with(&match?({:ok, _, _}, &1))

    errors = Enum.map_join(failed, "; ", &elem(&1, 1))

    if ok == [] and failed != [] do
      {:error, errors}
    else
      if failed != [], do: Logger.warning("GitHub archive: " <> errors)

      {:ok, ok |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
       ok |> Enum.map(&elem(&1, 2)) |> Enum.sum()}
    end
  end

  defp round(repo, jobs_per_round, settings, now) do
    a = settings.archive
    today = DateTime.to_date(now)
    key = "github_backfill:" <> repo
    runs_through_key = "github_runs_through:" <> repo

    with {:ok, runs} <- fetch_days(repo, run_days(key, runs_through_key, today, a, now)) do
      :ok = Store.put_runs(runs)
      if !Store.get_meta(key), do: Store.put_meta(key, Date.to_iso8601(today))
      Store.put_meta(runs_through_key, Integer.to_string(DateTime.to_unix(now)))

      refresh_facts(repo, today)

      # Every attempt's jobs, not only the latest's: a rerun is billed again.
      jobs =
        repo
        |> Store.runs_missing_jobs(jobs_per_round)
        |> Enum.count(fn run_id ->
          case api("repos/#{repo}/actions/runs/#{run_id}/jobs?filter=all&per_page=100") do
            {:ok, json} -> Store.put_jobs(repo, run_id, parse_jobs(json, repo, run_id)) == :ok
            {:error, _} -> false
          end
        end)

      save_prs(repo, today, a, now)
      {:ok, length(runs), jobs}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  The meta key holding why a repository's last pull request read failed:
  "forbidden" when GitHub refused the sign-in (it may read Actions but not
  pull requests), "failed" for anything else, empty after a good read.
  """
  def prs_error_key(repo), do: "github_prs_error:" <> repo

  # A failed read leaves the runs saved and the round good: the reason is
  # kept for the Shipped heading and logged once, when it starts.
  defp save_prs(repo, today, archive, now) do
    prs_key = "github_prs_backfill:" <> repo
    through_key = "github_prs_through:" <> repo

    case fetch_prs(repo, prs_from(prs_key, through_key, today, archive, now)) do
      {:ok, prs} ->
        :ok = Store.put_prs(prs)
        if !Store.get_meta(prs_key), do: Store.put_meta(prs_key, Date.to_iso8601(today))
        Store.put_meta(through_key, Integer.to_string(DateTime.to_unix(now)))
        put_prs_error(repo, "", nil)

      {:cut, prs} ->
        :ok = Store.put_prs(prs)

        Logger.warning(
          "GitHub archive: #{repo} has more than #{@pr_pages * 100} pull requests changed " <>
            "since the last read; saved the newest and will read them again next round"
        )

        put_prs_error(repo, "", nil)

      {:error, why} ->
        error = if why =~ ~r/HTTP 40[34]\b/, do: "forbidden", else: "failed"
        put_prs_error(repo, error, why)
    end
  end

  defp put_prs_error(repo, error, why) do
    if (Store.get_meta(prs_error_key(repo)) || "") != error do
      if why, do: Logger.warning("GitHub archive: #{repo}: cannot read pull requests: #{why}")
      Store.put_meta(prs_error_key(repo), error)
    end
  end

  # Where a round's pull requests start, in Unix seconds: the backfill on
  # the first round, then an hour before the round of the last good read of
  # them began, so a pull request merged while the board was off, or while
  # GitHub refused the read, is still read. A merged one
  # is rarely changed again, so a fixed window would miss it for good.
  defp prs_from(prs_key, through_key, today, archive, now) do
    midnight = &(&1 |> DateTime.new!(~T[00:00:00]) |> DateTime.to_unix())

    cond do
      !Store.get_meta(prs_key) ->
        midnight.(Date.add(today, -archive.backfill_days))

      (through = Store.get_meta(through_key)) && match?({_, ""}, Integer.parse(through)) ->
        min(String.to_integer(through), DateTime.to_unix(now)) - 3600

      true ->
        midnight.(Date.add(today, -1))
    end
  end

  # The days a round's runs are read from, oldest first: the backfill on the
  # first round, then from the day of an hour before the last good round
  # began, so a run created while the board was off is still saved, but never
  # further back than the backfill. Always yesterday too: a rerun keeps its
  # run's day, and a run started before midnight finishes after it.
  defp run_days(backfill_key, through_key, today, archive, now) do
    yesterday = Date.add(today, -1)
    oldest = Date.add(today, -archive.backfill_days)

    first =
      cond do
        !Store.get_meta(backfill_key) ->
          oldest

        (through = Store.get_meta(through_key)) && match?({_, ""}, Integer.parse(through)) ->
          last =
            (min(String.to_integer(through), DateTime.to_unix(now)) - 3600)
            |> DateTime.from_unix!()
            |> DateTime.to_date()

          Enum.min([yesterday, Enum.max([last, oldest], Date)], Date)

        true ->
          yesterday
      end

    Enum.to_list(Date.range(first, today, 1))
  end

  defp fetch_days(repo, days) do
    Enum.reduce_while(days, {:ok, []}, fn day, {:ok, acc} ->
      case fetch_day(repo, day, 1, []) do
        {:ok, runs} -> {:cont, {:ok, acc ++ runs}}
        err -> {:halt, err}
      end
    end)
  end

  # One day's runs, a page of 100 at a time.
  defp fetch_day(repo, day, page, acc) do
    path =
      "repos/#{repo}/actions/runs?per_page=100&page=#{page}&created=#{Date.to_iso8601(day)}"

    with {:ok, json} <- api(path),
         {:ok, runs, total} <- parse_runs(json, repo) do
      acc = acc ++ runs

      if runs != [] and length(acc) < total and page < 10,
        do: fetch_day(repo, day, page + 1, acc),
        else: {:ok, acc}
    end
  end

  # Whether the repository is public (its minutes on GitHub's runners are
  # then free) and its default branch, read once a day. A failed read keeps
  # what was read before.
  defp refresh_facts(repo, today) do
    day = Date.to_iso8601(today)

    if CiMinutes.repo_facts(repo)[:day] != day do
      with {:ok, json} <- api("repos/#{repo}"),
           {:ok, facts} <- parse_repo(json) do
        Store.put_meta(CiMinutes.meta_key(repo), Jason.encode!(Map.put(facts, :day, day)))
      end
    end
  end

  # Closed pull requests changed at or after `from` (Unix seconds), newest
  # change first, a page of 100 at a time until a page reaches back before it.
  # GitHub's pull request list has no 1,000 cap, unlike its run list; the
  # stop at @pr_pages only guards against a list that never ends, and
  # answers {:cut, prs} so nothing is marked read.
  defp fetch_prs(repo, from, page \\ 1, acc \\ []) do
    path =
      "repos/#{repo}/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=#{page}"

    with {:ok, json} <- api(path),
         {:ok, prs} <- parse_prs(json, repo) do
      recent = Enum.filter(prs, &((&1.updated_at || 0) >= from))
      acc = acc ++ Enum.map(recent, &Map.delete(&1, :updated_at))

      cond do
        length(prs) < 100 or length(recent) < 100 -> {:ok, acc}
        page < @pr_pages -> fetch_prs(repo, from, page + 1, acc)
        true -> {:cut, acc}
      end
    end
  end

  defp api(path), do: Cmd.run("gh", ["api", path], timeout: 60_000)

  # ---------------------------------------------------------------------------
  # Parsing (pure, tested against saved real replies)

  @doc "Runs from a REST reply, as rows for the database, with the list's total."
  def parse_runs(text, repo) do
    case Jason.decode(text) do
      {:ok, %{"workflow_runs" => runs} = body} when is_list(runs) ->
        {:ok, Enum.map(runs, &run(&1, repo)), body["total_count"] || length(runs)}

      _ ->
        {:error, "GitHub returned runs in an unexpected shape"}
    end
  end

  defp run(r, repo) do
    started = unix(r["run_started_at"]) || unix(r["created_at"])
    updated = unix(r["updated_at"])

    %{
      repo: repo,
      run_id: r["id"],
      attempt: r["run_attempt"],
      workflow: r["path"] && Path.basename(r["path"]),
      name: r["name"],
      event: r["event"],
      branch: r["head_branch"],
      head_sha: r["head_sha"],
      status: r["status"],
      conclusion: r["conclusion"],
      created_at: unix(r["created_at"]),
      started_at: started,
      updated_at: updated,
      duration_s:
        if((r["status"] == "completed" and started) && updated, do: max(updated - started, 0)),
      pr:
        r
        |> Map.get("pull_requests", [])
        |> List.wrap()
        |> List.first()
        |> then(&(&1 && &1["number"])),
      url: r["html_url"]
    }
  end

  @doc "A repository's visibility and default branch from a REST reply."
  def parse_repo(text) do
    case Jason.decode(text) do
      {:ok, %{"private" => private} = r} when is_boolean(private) ->
        {:ok, %{private: private, default_branch: r["default_branch"]}}

      _ ->
        {:error, "GitHub returned a repository in an unexpected shape"}
    end
  end

  @doc """
  Closed pull requests from a REST reply, as rows for the database, each
  with `updated_at` for knowing when to stop paging.
  """
  def parse_prs(text, repo) do
    case Jason.decode(text) do
      {:ok, prs} when is_list(prs) ->
        {:ok,
         for %{"number" => n} = p when is_integer(n) <- prs do
           %{
             repo: repo,
             number: n,
             title: p["title"],
             branch: get_in(p, ["head", "ref"]),
             head_repo: get_in(p, ["head", "repo", "full_name"]),
             base_repo: get_in(p, ["base", "repo", "full_name"]),
             default_branch: get_in(p, ["base", "repo", "default_branch"]),
             base: get_in(p, ["base", "ref"]),
             head_sha: get_in(p, ["head", "sha"]),
             author: get_in(p, ["user", "login"]),
             created_at: unix(p["created_at"]),
             closed_at: unix(p["closed_at"]),
             merged_at: unix(p["merged_at"]),
             url: p["html_url"],
             updated_at: unix(p["updated_at"])
           }
         end}

      _ ->
        {:error, "GitHub returned pull requests in an unexpected shape"}
    end
  end

  @doc "A run's jobs from a REST reply, as rows for the database."
  def parse_jobs(text, repo, run_id) do
    case Jason.decode(text) do
      {:ok, %{"jobs" => jobs}} when is_list(jobs) -> job_rows(jobs, repo, run_id)
      _ -> []
    end
  end

  @doc """
  Whether job rows are a finished run's final jobs for `attempt`: every job
  done and none from a later attempt. Right after a rerun starts, GitHub
  already answers with the new attempt's jobs, still waiting.
  """
  def final_jobs?(rows, attempt) do
    Enum.all?(rows, fn j ->
      j.status == "completed" and (is_nil(attempt) or is_nil(j.attempt) or j.attempt <= attempt)
    end)
  end

  @doc """
  Rows for jobs already decoded from a REST reply. The board's own check
  reads running runs' jobs with this too, so a run's panel shows the same
  job whether it came from that check or from the database.
  """
  def job_rows(jobs, repo, run_id) do
    Enum.map(jobs, fn j ->
      created = unix(j["created_at"])
      started = unix(j["started_at"])
      completed = unix(j["completed_at"])

      %{
        repo: repo,
        job_id: j["id"],
        run_id: j["run_id"] || run_id,
        attempt: j["run_attempt"],
        name: j["name"],
        status: j["status"],
        conclusion: j["conclusion"],
        created_at: created,
        started_at: started,
        completed_at: completed,
        queue_s: created && started && max(started - created, 0),
        duration_s: started && completed && max(completed - started, 0),
        runner_name: j["runner_name"],
        runner_group_name: j["runner_group_name"],
        labels: j["labels"] && Enum.join(j["labels"], ","),
        failed_step:
          (j["steps"] || [])
          |> Enum.find(&(&1["conclusion"] == "failure"))
          |> then(&(&1 && &1["name"])),
        # Not saved: the step a running job is on, for the run's panel.
        current_step:
          (j["steps"] || [])
          |> Enum.find(&(&1["status"] == "in_progress"))
          |> then(&(&1 && &1["name"]))
      }
    end)
  end

  defp unix(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp unix(_), do: nil
end
