defmodule Wallboard.Archive.Trends do
  @moduledoc """
  Cumulative metrics over time, from the database: one value per day for
  the last N days, the value over the whole period, and the change from
  the N days before when those are fully saved.

  Days are this Mac's local days. Rates (found, worked, failed) are
  weighted over the period (all hits over all searches), never an average
  of daily rates.

  Session totals (Korium use, tool calls, lines) count on the day the
  session last did something, so a session that ran for days lands on its
  last day. Spend and requests use each request's own time. CI minutes
  count on the day each run attempt began, and the part agents caused goes
  to the tool of the session that pushed (see `CiMinutes`).

  The Shipped cards count merged pull requests on the day each merged, with
  what the sessions behind it spent (see `Wallboard.Archive.PullRequests`).
  A pull request no session was found for counts as merged but not in the
  per-PR numbers, and the cards say how many were matched.

  The Claude cards count Claude sessions only, the Codex cards Codex
  sessions only. Korium cards count calls from both. With Codex on,
  `compare` holds the measures shown for both tools side by side, one pair
  of bars per day, led by tokens per merged pull request: what a shipped
  change costs each tool, in tokens, since Codex has no dollar price.
  """

  alias Wallboard.Archive.{CiMinutes, PullRequests}
  alias Wallboard.Store

  @doc "The cards for the last `days` days, ending today."
  def build(settings, days, now \\ DateTime.utc_now()) do
    today = local_day(DateTime.to_unix(now))
    current = Enum.map((days - 1)..0//-1, &Date.add(today, -&1))
    previous = Enum.map((2 * days - 1)..days//-1, &Date.add(today, -&1))
    since = List.first(previous)

    sums = day_sums(settings, since)
    history = history_start(settings, today)
    shipped = shipped_start(settings, today, history)
    saved_since? = &(&1 != nil and Date.compare(List.first(previous), &1) != :lt)
    prev_ok? = fn group -> saved_since?.(if group == :shipped, do: shipped, else: history) end

    # A tool with nothing in the period has no section, and the comparison
    # shows only when both have something to compare.
    cur_all = merge(Enum.map(current, &sums[&1]))
    claude_data? = cur_all.sessions + cur_all.requests > 0
    codex_data? = codex?(settings) and cur_all.codex_sessions + cur_all.codex_requests > 0

    shown =
      Enum.filter(metrics(settings), fn m ->
        case m.group do
          :korium -> korium?(settings)
          :codex -> codex_data?
          :claude -> claude_data?
          _ -> true
        end
      end)

    %{
      days: current,
      history_start: history,
      loading: %{github: github_loading(settings), shipped: shipped_loading(settings)},
      compare:
        if claude_data? and codex_data? do
          Enum.map(compare_metrics(), fn m ->
            %{
              key: m.key,
              label: m.label,
              fmt: m.fmt,
              claude: m.claude.(cur_all),
              codex: m.codex.(cur_all),
              series:
                Enum.map(current, fn d ->
                  day = sums[d]
                  {day && m.claude.(day), day && m.codex.(day)}
                end)
            }
          end)
        else
          []
        end,
      cards:
        Enum.map(shown, fn m ->
          cur = merge(Enum.map(current, &sums[&1]))
          prev = if prev_ok?.(m.group), do: merge(Enum.map(previous, &sums[&1])), else: nil
          value = m.value.(cur)
          prev_value = prev && m.value.(prev)

          %{
            key: m.key,
            group: m.group,
            label: m.label,
            fmt: m.fmt,
            value: value,
            sub: m[:sub] && m.sub.(cur),
            change: change(value, prev_value),
            good: m[:good] || :up,
            series: Enum.map(current, fn d -> sums[d] && m.value.(sums[d]) end)
          }
        end)
    }
  end

  defp korium?(settings), do: get_in(settings, [:korium, :enabled]) != false

  @doc """
  Words for the GitHub heading while its history is still coming in, or nil
  when it is all there: first the runs of the backfill days, then the jobs
  of each run (which carry runner time), a batch every few minutes.
  """
  def github_loading(settings) do
    repos = Wallboard.Settings.repo_names(settings)

    cond do
      Enum.any?(repos, &(!Store.get_meta("github_backfill:" <> &1))) ->
        "Loading…"

      (n = repos |> Enum.map(&Store.runs_missing_jobs_count/1) |> Enum.sum()) > 0 ->
        "Loading job times, #{thousands(n)} #{if n == 1, do: "run", else: "runs"} to go"

      true ->
        nil
    end
  end

  @doc "Words for the Shipped heading until every repository's pull requests are saved."
  def shipped_loading(settings) do
    if settings
       |> Wallboard.Settings.repo_names()
       |> Enum.any?(&(!Store.get_meta("github_prs_backfill:" <> &1))),
       do: "Loading…"
  end

  defp codex?(settings), do: get_in(settings, [:codex, :enabled]) == true

  # Measures shown for Claude and Codex in one chart.
  defp compare_metrics do
    [
      %{
        key: :tokens_per_pr,
        label: "Tokens per merged PR",
        fmt: :tokens,
        claude: &per(&1.pr_tokens, &1.pr_claude),
        codex: &per(&1.pr_codex_tokens, &1.pr_codex)
      },
      %{
        key: :tokens,
        label: "Tokens",
        fmt: :tokens,
        claude: & &1.tokens,
        codex: & &1.codex_tokens
      },
      %{
        key: :lines,
        label: "Lines added",
        fmt: :count,
        claude: & &1.lines_added,
        codex: & &1.codex_lines_added
      },
      %{
        key: :tool_failed,
        label: "Tool calls failed",
        fmt: :pct,
        claude: &ratio(&1.tool_errors, &1.tool_calls),
        codex: &ratio(&1.codex_tool_errors, &1.codex_tool_calls)
      },
      %{
        key: :ci_minutes,
        label: "CI minutes",
        fmt: :count,
        claude: & &1.ci_agent,
        codex: & &1.codex_ci_agent
      }
    ]
  end

  # The first day every source had saved, or nil before anything is saved.
  defp history_start(settings, today) do
    repos = Wallboard.Settings.repo_names(settings)
    latest_start([{"claude_since", 0}] ++ backfills(settings, repos, "github_backfill:"), today)
  end

  # The same for the Shipped cards, which also need the pull requests saved.
  # Those were first saved later than sessions and runs on a board that ran
  # before, so they hold only the Shipped cards back, never the others.
  defp shipped_start(settings, today, history) do
    repos = Wallboard.Settings.repo_names(settings)

    case latest_start(backfills(settings, repos, "github_prs_backfill:"), today) do
      prs when history != nil and prs != nil -> Enum.max([history, prs], Date)
      _ -> nil
    end
  end

  defp backfills(settings, repos, prefix),
    do: Enum.map(repos, &{prefix <> &1, settings.archive.backfill_days})

  # The latest of the saved starts, or nil when none is saved.
  defp latest_start(keys, today) do
    starts =
      Enum.flat_map(keys, fn {key, days_back} ->
        with v when is_binary(v) <- Store.get_meta(key),
             {:ok, d} <- Date.from_iso8601(v) do
          [Date.add(d, -days_back)]
        else
          _ -> []
        end
      end)

    if starts == [], do: nil, else: Enum.max(starts, Date, fn -> today end)
  end

  # ---------------------------------------------------------------------------
  # The metrics

  defp metrics(settings) do
    gate =
      case settings
           |> Wallboard.Settings.github_repos()
           |> Enum.map(& &1.gate_workflow)
           # A repository with no gate workflow has no gate runs to name.
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq() do
        [one] -> one
        _ -> "gate"
      end

    [
      %{
        key: :merged_prs,
        group: :shipped,
        label: "Merged PRs",
        fmt: :count,
        value: & &1.merged_prs,
        sub: &sessions_per_pr/1
      },
      %{
        key: :pr_cost,
        group: :shipped,
        label: "Cost per merged PR",
        fmt: :money,
        good: :down,
        value: &per(&1.pr_cost, &1.pr_claude),
        sub: &matched(&1.pr_claude, &1.merged_prs, "Claude sessions")
      },
      %{
        key: :pr_tokens,
        group: :shipped,
        label: "Tokens per merged PR",
        fmt: :tokens,
        good: :down,
        value: &per(&1.pr_tokens + &1.pr_codex_tokens, &1.matched_prs),
        sub: &matched(&1.matched_prs, &1.merged_prs, "sessions")
      },
      %{
        key: :spend,
        group: :claude,
        label: "Spend",
        fmt: :money,
        good: :down,
        value: & &1.cost,
        sub: &"#{thousands(&1.requests)} requests"
      },
      %{
        key: :sessions,
        group: :claude,
        label: "Sessions",
        fmt: :count,
        value: & &1.sessions,
        sub: &"#{thousands(&1.prompts)} prompts"
      },
      %{
        key: :cache_hit,
        group: :claude,
        label: "Cache hit",
        fmt: :pct,
        value: &ratio(&1.cache_read, &1.prompt),
        sub: fn _ -> "of prompt tokens" end
      },
      %{
        key: :codex_tokens,
        group: :codex,
        label: "Tokens",
        fmt: :tokens,
        good: :down,
        value: & &1.codex_tokens,
        sub: &"#{thousands(&1.codex_requests)} replies"
      },
      %{
        key: :codex_sessions,
        group: :codex,
        label: "Sessions",
        fmt: :count,
        value: & &1.codex_sessions,
        sub: &"#{thousands(&1.codex_prompts)} prompts"
      },
      %{
        key: :codex_cache_hit,
        group: :codex,
        label: "Cache hit",
        fmt: :pct,
        value: &ratio(&1.codex_cache_read, &1.codex_prompt),
        sub: fn _ -> "of prompt tokens" end
      },
      %{
        key: :codex_tool_failed,
        group: :codex,
        label: "Tool calls failed",
        fmt: :pct,
        good: :down,
        value: &ratio(&1.codex_tool_errors, &1.codex_tool_calls),
        sub: &"of #{thousands(&1.codex_tool_calls)} calls"
      },
      %{
        key: :codex_lines,
        group: :codex,
        label: "Lines added",
        fmt: :count,
        value: & &1.codex_lines_added,
        sub: &"#{thousands(&1.codex_lines_removed)} removed"
      },
      # Codex logs no API errors; how long its turns run stands in.
      %{
        key: :codex_turns,
        group: :codex,
        label: "Turns",
        fmt: :count,
        value: & &1.codex_turns,
        sub: &turn_minutes(&1.codex_turn_ms, &1.codex_turns)
      },
      %{
        key: :korium_found,
        group: :korium,
        label: "Memory searches found",
        fmt: :pct,
        value: &ratio(&1.ks_hits, &1.ks),
        sub: &"of #{thousands(&1.ks)} searches"
      },
      %{
        key: :korium_saved,
        group: :korium,
        label: "Memory saves worked",
        fmt: :pct,
        value: &ratio(&1.saves - &1.save_errors, &1.saves),
        sub: &"of #{thousands(&1.saves)} saves"
      },
      %{
        key: :code_found,
        group: :korium,
        label: "Code searches found",
        fmt: :pct,
        value: &ratio(&1.cs_hits, &1.cs),
        sub: &"of #{thousands(&1.cs)} searches · #{thousands(&1.index)} indexing runs"
      },
      %{
        key: :tool_failed,
        group: :claude,
        label: "Tool calls failed",
        fmt: :pct,
        good: :down,
        value: &ratio(&1.tool_errors, &1.tool_calls),
        sub: &"of #{thousands(&1.tool_calls)} calls"
      },
      %{
        key: :lines,
        group: :claude,
        label: "Lines added",
        fmt: :count,
        value: & &1.lines_added,
        sub: &"#{thousands(&1.lines_removed)} removed"
      },
      %{
        key: :api_errors,
        group: :claude,
        label: "API errors",
        fmt: :count,
        good: :down,
        value: & &1.api_errors,
        sub: &"#{thousands(&1.denials)} permission denials"
      },
      %{
        key: :runs,
        group: :github,
        label: "Workflow runs",
        fmt: :count,
        value: & &1.runs,
        sub: &"#{thousands(&1.runs_failed)} failed"
      },
      %{
        key: :run_failed,
        group: :github,
        label: "Runs failed",
        fmt: :pct,
        good: :down,
        value: &ratio(&1.runs_failed, &1.runs_done),
        sub: &"of #{thousands(&1.runs_done)} finished"
      },
      %{
        key: :gate_time,
        group: :github,
        label: "Gate time, median",
        fmt: :minutes,
        good: :down,
        value: &median(&1.gate_durations),
        sub: &"#{length(&1.gate_durations)} #{gate} runs"
      },
      %{
        key: :deploys,
        group: :github,
        label: "Deploys",
        fmt: :count,
        value: &(&1.deploys_dev + &1.deploys_prod),
        sub: &"dev #{&1.deploys_dev} · prod #{&1.deploys_prod}"
      },
      # Runner time, split by whose machine ran the job (see
      # Wallboard.Runners). GitHub's time is what the plan pays for.
      %{
        key: :runner_hours,
        group: :github,
        label: "Runner time on GitHub",
        fmt: :hours,
        good: :down,
        value: fn d -> d.github_s / 3600 end,
        sub: &runner_sub(&1.github_jobs, &1.unknown_s)
      },
      %{
        key: :own_runner_hours,
        group: :github,
        label: "Runner time on your machines",
        fmt: :hours,
        value: fn d -> d.own_s / 3600 end,
        sub: &runner_sub(&1.own_jobs, &1.unknown_s)
      },
      %{
        key: :ci_minutes,
        group: :github,
        label: "CI minutes",
        fmt: :count,
        good: :down,
        value: & &1.ci_paid,
        sub: &ci_note/1
      },
      # Beside CI minutes: your own runners' minutes, which GitHub does not
      # bill, counted the way it would have (each job rounded up to a whole
      # minute; see CiMinutes), and not on a public repository, where its
      # standard runners are free.
      %{
        key: :minutes_avoided,
        group: :github,
        label: "Paid minutes avoided",
        fmt: :count,
        value: & &1.ci_avoided,
        sub: &"#{thousands(&1.own_jobs)} jobs on your machines"
      }
    ]
  end

  defp runner_sub(jobs, unknown_s) when unknown_s > 0,
    do: "#{thousands(jobs)} jobs · #{hours_text(unknown_s)} not known"

  defp runner_sub(jobs, _), do: "#{thousands(jobs)} jobs"

  defp hours_text(s), do: "#{:erlang.float_to_binary(s / 3600, decimals: 1)} h"

  # What the CI minutes card's number leaves out, beside the part agents
  # caused: minutes that use up no plan.
  defp ci_note(d) do
    [
      "#{thousands(d.ci_agent + d.codex_ci_agent)} from agent sessions",
      d.ci_free > 0 && "#{thousands(d.ci_free)} free on public repositories",
      d.ci_own > 0 && "#{thousands(d.ci_own)} on your own machines"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # ---------------------------------------------------------------------------
  # Adding up

  # What each tool counts on its own; Codex rows carry them as codex_<name>.
  # Korium counts are shared: a search is a search whichever tool made it.
  @per_tool ~w(cost requests prompt cache_read tokens sessions prompts turns turn_ms tool_calls
    tool_errors lines_added lines_removed api_errors denials ci_agent)a

  @zero_codex Map.new(@per_tool, &{:"codex_#{&1}", 0})

  @zero %{
    cost: 0.0,
    requests: 0,
    prompt: 0,
    cache_read: 0,
    tokens: 0,
    turns: 0,
    turn_ms: 0,
    sessions: 0,
    prompts: 0,
    ks: 0,
    ks_hits: 0,
    saves: 0,
    save_errors: 0,
    cs: 0,
    cs_hits: 0,
    index: 0,
    tool_calls: 0,
    tool_errors: 0,
    lines_added: 0,
    lines_removed: 0,
    api_errors: 0,
    denials: 0,
    runs: 0,
    runs_done: 0,
    runs_failed: 0,
    gate_durations: [],
    deploys_dev: 0,
    deploys_prod: 0,
    runner_s: 0,
    jobs: 0,
    github_s: 0,
    github_jobs: 0,
    own_s: 0,
    own_jobs: 0,
    unknown_s: 0,
    ci_paid: 0,
    ci_free: 0,
    ci_own: 0,
    ci_avoided: 0,
    ci_agent: 0,
    # Merged pull requests, those with any session found, and those with a
    # Claude or a Codex session; then their sessions, Claude dollars and
    # each tool's tokens.
    merged_prs: 0,
    matched_prs: 0,
    pr_claude: 0,
    pr_codex: 0,
    pr_sessions: 0,
    pr_cost: 0.0,
    pr_tokens: 0,
    pr_codex_tokens: 0
  }

  @doc "Adds up day sums; days with nothing saved count as zero."
  def merge(days) do
    Enum.reduce(days, Map.merge(@zero, @zero_codex), fn
      nil, acc -> acc
      d, acc -> Map.merge(acc, d, fn _k, a, b -> add(a, b) end)
    end)
  end

  defp add(a, b) when is_list(a), do: a ++ b
  defp add(a, b), do: a + b

  # One repository's runs, runner time and gate times by the hour. Dev and
  # Prod deploys count only for the first repository, as on the status line.
  defp github_hours({gh, index}, from) do
    {dev, prod} = if index == 0, do: {gh.dev_deploy, gh.prod_deploy}, else: {"", ""}
    # The runners GitHub has listed as the repository's own: a job on one
    # is yours here as on the Git tab, with or without the label.
    listed = Store.runner_names(gh.repo)

    Store.query(
      """
      SELECT created_at / 3600 AS h, count(*) AS runs,
        sum(conclusion IN ('success', 'failure')) AS runs_done,
        sum(conclusion = 'failure') AS runs_failed,
        sum(workflow = ?2 AND conclusion = 'success') AS deploys_dev,
        sum(workflow = ?3 AND conclusion = 'success') AS deploys_prod
      FROM gh_runs WHERE repo = ?4 AND created_at >= ?1 GROUP BY h
      """,
      [from, dev, prod, gh.repo]
    ) ++
      Enum.map(
        Store.query(
          """
          SELECT completed_at / 3600 AS h, duration_s, runner_name, runner_group_name, labels
          FROM gh_jobs WHERE repo = ?2 AND completed_at >= ?1
          """,
          [from, gh.repo]
        ),
        &job_hour(&1, listed)
      ) ++
      Enum.map(
        Store.query(
          """
          SELECT created_at / 3600 AS h, duration_s FROM gh_runs
          WHERE repo = ?3 AND created_at >= ?1 AND workflow = ?2
            AND conclusion = 'success' AND duration_s IS NOT NULL
          """,
          [from, gh.gate_workflow, gh.repo]
        ),
        &%{h: &1.h, gate_durations: [&1.duration_s]}
      )
  end

  # One saved job as an hour's sums, by whose machine ran it.
  defp job_hour(%{h: h, duration_s: d} = job, listed) do
    d = d || 0
    base = %{h: h, runner_s: d, jobs: 1}

    case Wallboard.Runners.kind(job, listed) do
      :github -> Map.merge(base, %{github_s: d, github_jobs: 1})
      :own -> Map.merge(base, %{own_s: d, own_jobs: 1})
      :unknown -> Map.put(base, :unknown_s, d)
    end
  end

  @doc """
  Claude and Codex use added up over the local days from `first` to `last`,
  both included, the same way the cards add it up. GitHub is left out.
  """
  def sums(settings, %Date{} = first, %Date{} = last) do
    days = day_sums(settings, first, false)
    first |> Date.range(last) |> Enum.map(&days[&1]) |> merge()
  end

  # Every source, summed by the hour in SQL, then by local day here.
  defp day_sums(settings, since, github? \\ true) do
    from = since |> DateTime.new!(~T[00:00:00]) |> DateTime.to_unix() |> Kernel.-(86_400)

    hourly =
      Store.query(
        """
        SELECT r.at / 3600 AS h, coalesce(s.tool, 'claude') AS tool,
          sum(r.cost) AS cost, count(*) AS requests,
          sum(r.input_tokens + r.cache_read_tokens + r.cache_write_tokens) AS prompt,
          sum(r.cache_read_tokens) AS cache_read,
          sum(r.input_tokens + r.cache_read_tokens + r.cache_write_tokens + r.output_tokens) AS tokens
        FROM requests r
        LEFT JOIN sessions s ON s.machine = r.machine AND s.session_id = r.session_id
        WHERE r.at >= ?1 GROUP BY h, tool
        """,
        [from]
      ) ++
        Store.query(
          """
          SELECT ended_at / 3600 AS h, coalesce(tool, 'claude') AS tool,
            count(*) AS sessions, sum(prompts) AS prompts, sum(turns) AS turns,
            sum(turn_ms) AS turn_ms,
            sum(korium_searches) AS ks, sum(korium_search_hits) AS ks_hits,
            sum(korium_saves) AS saves, sum(korium_save_errors) AS save_errors,
            sum(code_searches) AS cs, sum(code_search_hits) AS cs_hits, sum(korium_index) AS "index",
            sum(tool_calls) AS tool_calls, sum(tool_errors) AS tool_errors,
            sum(lines_added) AS lines_added, sum(lines_removed) AS lines_removed,
            sum(api_errors) AS api_errors, sum(denials) AS denials
          FROM sessions WHERE ended_at >= ?1 GROUP BY h, tool
          """,
          [from]
        ) ++
        if(github?,
          do:
            (settings
             |> Wallboard.Settings.github_repos()
             |> Enum.with_index()
             |> Enum.flat_map(&github_hours(&1, from))) ++
              CiMinutes.hourly(settings, from) ++
              Enum.map(PullRequests.merged(settings, from), &pr_hour/1),
          else: []
        )

    hourly
    |> Enum.group_by(&local_day(&1.h * 3600))
    |> Map.new(fn {day, rows} ->
      {day,
       rows
       |> Enum.map(&Map.delete(&1, :h))
       |> Enum.map(&nils_to_zero/1)
       |> Enum.map(&by_tool/1)
       |> merge()}
    end)
  end

  # One merged pull request, on the hour it merged.
  defp pr_hour(pr) do
    one = fn yes? -> if yes?, do: 1, else: 0 end

    %{
      h: div(pr.merged_at, 3600),
      merged_prs: 1,
      matched_prs: one.(pr.sessions != []),
      pr_claude: one.(pr.claude_sessions > 0),
      pr_codex: one.(pr.codex_sessions > 0),
      pr_sessions: length(pr.sessions),
      pr_cost: pr.cost,
      pr_tokens: round(pr.tokens),
      pr_codex_tokens: round(pr.codex_tokens)
    }
  end

  defp nils_to_zero(row), do: Map.new(row, fn {k, v} -> {k, v || 0} end)

  @doc "Moves a Codex row's own counts to their codex_ names; Korium counts stay shared."
  def by_tool(%{tool: "codex"} = row) do
    row
    |> Map.delete(:tool)
    |> Map.new(fn {k, v} -> if k in @per_tool, do: {:"codex_#{k}", v}, else: {k, v} end)
  end

  def by_tool(row), do: Map.delete(row, :tool)

  # ---------------------------------------------------------------------------

  @doc "An amount per pull request, or nil with no pull requests."
  def per(_amount, prs) when prs in [0, nil], do: nil
  def per(amount, prs), do: amount / prs

  defp sessions_per_pr(%{matched_prs: 0}), do: "no sessions matched"

  defp sessions_per_pr(d),
    do: "#{:erlang.float_to_binary(d.pr_sessions / d.matched_prs, decimals: 1)} sessions per PR"

  defp matched(n, of, what), do: "#{thousands(n)} of #{thousands(of)} matched to #{what}"

  defp turn_minutes(_ms, 0), do: "no turns"

  defp turn_minutes(ms, turns),
    do: "#{:erlang.float_to_binary(ms / turns / 60_000, decimals: 1)} min a turn on average"

  defp ratio(_n, 0), do: nil
  defp ratio(n, d), do: n * 100 / d

  defp median([]), do: nil

  defp median(list) do
    sorted = Enum.sort(list)
    Enum.at(sorted, div(length(sorted), 2)) / 60
  end

  @doc "Percent change, or nil when there is nothing to compare."
  def change(nil, _), do: nil
  def change(_, nil), do: nil
  def change(_, prev) when prev == 0, do: nil
  def change(cur, prev), do: (cur - prev) * 100 / prev

  @doc "The local day a unix time falls on, the day every card counts it under."
  def local_day(unix) do
    {{y, m, d}, _} =
      unix
      |> DateTime.from_unix!()
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    Date.new!(y, m, d)
  end

  @doc "A number rounded to a whole one, with commas: 1234567.8 is \"1,234,568\"."
  def thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def thousands(n), do: n |> round() |> thousands()
end
