defmodule Wallboard.Archive.GitHubCollector do
  @moduledoc """
  Saves GitHub Actions runs and their jobs into the database, so trends can
  go back further than the board's own 24-hour view.

  Every `github_poll_seconds` (5 minutes by default) one round:

    * on the very first round, saves the last `backfill_days` of runs, one
      day at a time (GitHub returns at most 1,000 runs for a filtered list,
      and a busy repo can pass that in two weeks)
    * saves the runs created in the last 2 days, which picks up runs that
      finished or were rerun since
    * saves the jobs of up to `github_jobs_per_round` finished runs that do
      not have them yet, newest first. At 100 every 5 minutes that is 1,200
      calls an hour, which with the board's own ~600 stays well inside
      GitHub's 5,000; two weeks of jobs fill in over about two hours.

  A run that is rerun or finishes gets its jobs fetched again.
  """

  use GenServer
  require Logger

  alias Wallboard.{Cmd, Store}

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

  @doc "Runs one round. Returns {:ok, runs_saved, runs_with_jobs_saved} or {:error, reason}."
  def round(settings, now) do
    repo = settings.github.repo
    a = settings.archive
    today = DateTime.to_date(now)
    key = "github_backfill:" <> repo

    days =
      if Store.get_meta(key),
        do: [Date.add(today, -1), today],
        else: Enum.map(a.backfill_days..0//-1, &Date.add(today, -&1))

    with {:ok, runs} <- fetch_days(repo, days) do
      :ok = Store.put_runs(runs)
      if !Store.get_meta(key), do: Store.put_meta(key, Date.to_iso8601(today))

      jobs =
        repo
        |> Store.runs_missing_jobs(a.github_jobs_per_round)
        |> Enum.count(fn run_id ->
          case api("repos/#{repo}/actions/runs/#{run_id}/jobs?per_page=100") do
            {:ok, json} -> Store.put_jobs(repo, run_id, parse_jobs(json, repo, run_id)) == :ok
            {:error, _} -> false
          end
        end)

      {:ok, length(runs), jobs}
    end
  rescue
    e -> {:error, Exception.message(e)}
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

  @doc "A run's jobs from a REST reply, as rows for the database."
  def parse_jobs(text, repo, run_id) do
    case Jason.decode(text) do
      {:ok, %{"jobs" => jobs}} when is_list(jobs) ->
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
            labels: j["labels"] && Enum.join(j["labels"], ","),
            failed_step:
              (j["steps"] || [])
              |> Enum.find(&(&1["conclusion"] == "failure"))
              |> then(&(&1 && &1["name"]))
          }
        end)

      _ ->
        []
    end
  end

  defp unix(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp unix(_), do: nil
end
