defmodule Wallboard.Archive.CiMinutes do
  @moduledoc """
  The CI minutes each session's pushes caused, and each pull request's,
  from the runs and jobs `Wallboard.Archive.GitHubCollector` saves.

  Minutes are counted the way GitHub bills them: each job's time is rounded
  up to a whole minute, a Windows job counts 2 and a macOS job 10 against the
  plan's included minutes, and a job on one of your own machines (labelled
  `self-hosted`, or on a runner GitHub lists as the repository's own; see
  `Wallboard.Runners`) counts nothing. GitHub's standard runners are free
  on a public repository, so a public repository's minutes are kept apart
  from the ones that use up the plan. Four kinds, then:

    * `paid`: GitHub's runners on a private repository, or one whose
      visibility is not known yet, and its macOS larger runners anywhere,
      weighted as above
    * `free`: GitHub's standard runners on a public repository, weighted
      the same
    * `unknown`: on a public repository, jobs in a runner group other than
      "GitHub Actions" that are not known to be yours, weighted the same
    * `own`: your own machines, in plain minutes

  GitHub's larger runners are billed on every repository, public or not,
  and the plan's minutes never cover them. Its macOS larger runners are
  asked for by labels GitHub names (`macos-15-large`,
  `macos-latest-xlarge`), so they are always paid. Its Linux and Windows
  larger runners carry names and groups their owner chose, and so does a
  runner of your own without the `self-hosted` label (an Actions Runner
  Controller scale set, or one asked for by a custom label): a job in such
  a group is billed if it is GitHub's and free if it is yours, and nothing
  in the job says which. On a private repository both are counted paid,
  as GitHub's would be; on a public one they are `unknown`, as
  `Wallboard.Runners.kind/2` calls them. Their system is read from the
  words in their labels, runner's name and group, so `big-windows` counts
  2. GitHub prices a larger runner by its size too, which no job says, so
  its minutes are a floor: a 96-core Linux runner costs 42 times a 2-core
  one and counts the same.

  Minutes are added up by attempt: a rerun is another attempt of the same
  run, billed again, and begins when it was asked for.

  An attempt goes to the session that caused it: one that was on the
  attempt's branch when the attempt began (from when it was first seen
  there to `@after_s` past when it was last seen there, since a push is
  often a session's last act there), in its repository when the session's
  repository is known. A Claude session keeps every branch it was on, with
  when; a Codex session and one from another machine keep one branch, for
  their whole span. When several qualify, a session no script or other
  tool started comes first (a review it started runs inside the session
  that pushes), then the one that started last, so an attempt counts once.
  Sessions save no commit, so the link is by branch and time.

  Attempts on the repository's default branch (and on `main` or `master`),
  on another long-lived branch, scheduled runs, merge queue runs and runs
  GitHub starts itself are never a session's: anyone's merge can cause
  them. A branch is long-lived by the rule of
  `Wallboard.Archive.PullRequests`: a pull request merged into it after
  its own pull request merged (develop, which keeps taking features after
  each release), or it took a merge and has no pull request of its own. A
  stacked branch, merged into while its own pull request is open, is not.
  """

  alias Wallboard.{GitRemote, Settings, Store}

  # How long after a session's last activity an attempt it caused may begin.
  @after_s 300

  # How a session that a script or another tool started says so: a Codex
  # review Claude asked for ("Claude Code"), `codex exec`, and Claude's own
  # `claude -p` and Agent SDK runs ("sdk-cli"; on one hub, 2,115 such
  # sessions opened no pull request, while 159 of 213 terminal ones did).
  @nested ["Claude Code", "codex_exec", "sdk-cli"]

  # Events no session causes by pushing.
  @not_pushed ~w(schedule merge_group dynamic)

  # A job that ran on one of your own machines, by the rule of
  # `Wallboard.Runners.kind/2`: not in GitHub's own runner group, and
  # labelled "self-hosted" (as kyroco's own runners' jobs read
  # "self-hosted,Linux,ARM64,kyroco-gate") or on a runner GitHub has listed
  # as the repository's own. The Trends and Git tab tests hold the two to
  # the same answer.
  @own """
  (coalesce(j.runner_group_name, '') <> 'GitHub Actions' AND
    ((',' || coalesce(j.labels, '') || ',') LIKE '%,self-hosted,%' OR
      j.runner_name IN (SELECT g.name FROM gh_runners g WHERE g.repo = j.repo)))
  """

  # A job's minutes as GitHub rounds them.
  @rounded "((coalesce(j.duration_s, 0) + 59) / 60)"

  # A job asking by label for one of GitHub's macOS larger runners, as
  # "macos-15-large" or "macos-latest-xlarge". LIKE ignores case, as GitHub
  # does with labels.
  @mac_larger """
  ((',' || coalesce(j.labels, '') || ',') LIKE '%,macos-latest-large,%' OR
    (',' || coalesce(j.labels, '') || ',') LIKE '%,macos-latest-xlarge,%' OR
    (',' || coalesce(j.labels, '') || ',') LIKE '%,macos-__-large,%' OR
    (',' || coalesce(j.labels, '') || ',') LIKE '%,macos-__-xlarge,%')
  """

  # A job in a runner group other than GitHub's: one of its Linux or
  # Windows larger runners, or a runner of your own without the self-hosted
  # label. Old rows saved no group and are not swept in.
  @other_group "coalesce(j.runner_group_name, '') NOT IN ('', 'GitHub Actions')"

  # Everything a job says about its machine: a larger runner's system can
  # be in its runner's name or group rather than its labels.
  @names """
  (coalesce(j.labels, '') || ',' || coalesce(j.runner_name, '') || ',' ||
    coalesce(j.runner_group_name, ''))
  """

  # What a minute on GitHub's runner counts against the plan.
  @weight """
  (CASE WHEN #{@names} LIKE '%macos%' THEN 10
    WHEN #{@names} LIKE '%windows%' THEN 2 ELSE 1 END)
  """

  @doc """
  The minutes of one saved session: `%{paid, free, unknown, own, runs, failed}`,
  where `runs` counts attempts and `failed` those with a failed job.
  """
  def for_session(%{started_at: from, ended_at: to} = s)
      when is_integer(from) and is_integer(to) do
    case s |> spans() |> Enum.map(& &1.branch) |> Enum.uniq() do
      [] -> total([])
      branches -> for_session(s, branches, from, to)
    end
  end

  def for_session(_s), do: total([])

  defp for_session(s, branches, from, to) do
    attempts =
      "r.branch IN (#{marks(branches, 1)})"
      |> attempts(branches)
      |> Enum.filter(&(&1.at >= from and &1.at <= to + @after_s))

    # The other sessions on these branches at work then, which may have
    # caused some of these attempts rather than this one.
    on = marks(branches, 5)

    rivals =
      sessions(
        """
        (git_branch IN (#{on}) OR EXISTS
          (SELECT 1 FROM json_each(detail, '$.branches') b
            WHERE json_extract(b.value, '$.branch') IN (#{on})))
          AND started_at <= ?2 AND ended_at >= ?1 - #{@after_s}
          OR (machine = ?3 AND session_id = ?4)
        """,
        [from, to + @after_s, s.machine, s.session_id | branches]
      )

    attempts
    |> link(rivals)
    |> Enum.filter(fn {_a, owner} ->
      {owner.machine, owner.session_id} == {s.machine, s.session_id}
    end)
    |> Enum.map(&elem(&1, 0))
    |> total()
  end

  # Each branch a saved session worked on, with when: `%{branch, from, to}`.
  # A Claude session saved since #52 lists them in its details; any other
  # has the one branch saved with it, for its whole span.
  defp spans(s) do
    detail = Map.get(s, :detail) || %{}

    listed =
      for span <- List.wrap(Map.get(detail, "branches") || Map.get(detail, :branches)),
          is_map(span),
          branch = span["branch"] || span[:branch],
          from = span["from"] || span[:from],
          to = span["to"] || span[:to],
          is_binary(branch) and branch != "" and is_integer(from) and is_integer(to),
          do: %{branch: branch, from: from, to: to}

    branch = Map.get(s, :git_branch)

    if is_binary(branch) and branch != "" and not Enum.any?(listed, &(&1.branch == branch)),
      do: listed ++ [%{branch: branch, from: s[:started_at], to: s[:ended_at]}],
      else: listed
  end

  # "?first, ?first+1, ..." for each value.
  defp marks(values, first),
    do: Enum.map_join(first..(first + length(values) - 1)//1, ", ", &"?#{&1}")

  @doc """
  The minutes of one pull request, in the same shape as `for_session/1`:
  the runs GitHub tags with its number, push runs on its branch in its own
  time (after the last other pull request on that branch closed, until it
  closed) that GitHub tagged with no other, and its merge queue runs.
  `repo` is "owner/name".
  """
  def for_pr(repo, number) when is_binary(repo) and is_integer(number) do
    branches =
      Store.query(
        """
        SELECT DISTINCT branch FROM gh_runs
        WHERE lower(repo) = lower(?1) AND pr = ?2 AND branch IS NOT NULL
        """,
        [repo, number]
      )
      |> Enum.map(& &1.branch)
      |> Enum.reject(&(&1 in ["main", "master", repo_facts(repo)[:default_branch]]))

    # A later pull request can use the branch's name again: a run on it is
    # this one's only in its time, and not when GitHub tagged another.
    {on_branch, more} =
      if branches == [] do
        {"", []}
      else
        {since, until} = window(repo, number, branches)

        {"""
          OR (r.branch IN (#{marks(branches, 6)}) AND (r.pr IS NULL OR r.pr = ?2)
           AND r.created_at > ?4 AND r.created_at <= ?5)
         """, [since, until | branches]}
      end

    "lower(r.repo) = lower(?1) AND (r.pr = ?2 OR r.branch LIKE ?3#{on_branch})"
    |> attempts([repo, number, "gh-readonly-queue/%/pr-#{number}-%" | more])
    |> total()
  end

  def for_pr(_repo, _number), do: total([])

  # When a run on `branches`, a pull request's own, can be its own,
  # `{since, until}`: after the last other pull request on those branches
  # closed (before this one opened, when this one is saved), until this one
  # closed. The board saves only closed pull requests, so an open one has
  # no row and no end. A fork's pull request only shares the name.
  @no_end 9_223_372_036_854_775_807

  defp window(repo, number, branches) do
    own =
      Store.query(
        """
        SELECT created_at, coalesce(closed_at, merged_at) AS closed FROM gh_prs
        WHERE lower(repo) = lower(?1) AND number = ?2
        """,
        [repo, number]
      )
      |> List.first(%{})

    [%{since: since}] =
      Store.query(
        """
        SELECT max(coalesce(closed_at, merged_at)) AS since FROM gh_prs
        WHERE lower(repo) = lower(?1) AND number <> ?2 AND lower(head_repo) = lower(repo)
          AND branch IN (#{marks(branches, 4)})
          AND (?3 IS NULL OR coalesce(closed_at, merged_at) <= ?3)
        """,
        [repo, number, own[:created_at] | branches]
      )

    {since || 0, own[:closed] || @no_end}
  end

  @doc """
  Rows for Trends, by the hour each attempt began, from `from` (Unix
  seconds), for the tracked repositories: `%{h, ci_paid, ci_free, ci_own,
  ci_avoided, ci_unknown}` for every attempt, and `%{h, tool, ci_agent}`
  for the paid minutes of each attempt a session caused, under that
  session's tool.
  """
  def hourly(settings, from) do
    tracked = settings |> Settings.repo_names() |> Enum.map(&String.downcase/1)

    if tracked == [] do
      []
    else
      marks = Enum.map_join(Enum.with_index(tracked, 3), ", ", fn {_, i} -> "?#{i}" end)

      # A rerun begun in the period can belong to a run created before it.
      attempts =
        "lower(r.repo) IN (#{marks}) AND r.created_at >= ?1 - ?2"
        |> attempts([from, 30 * 86_400 | tracked])
        |> Enum.filter(&(&1.at >= from))

      sessions =
        sessions(
          "(git_branch IS NOT NULL OR json_extract(detail, '$.branches') IS NOT NULL) AND ended_at >= ?1",
          [from - @after_s]
        )

      Enum.map(attempts, fn a ->
        %{
          h: div(a.at, 3600),
          ci_paid: a.paid,
          ci_free: a.free,
          ci_own: a.own,
          ci_avoided: a.avoided,
          ci_unknown: a.unknown
        }
      end) ++
        Enum.map(link(attempts, sessions), fn {a, s} ->
          %{h: div(a.at, 3600), tool: s.tool, ci_agent: a.paid}
        end)
    end
  end

  @doc """
  Pairs each attempt with the session that caused it, as `{attempt,
  session}`; attempts no session caused are left out. Pure, for the tests.

  An attempt has `repo`, `branch`, `event`, `at`, `default` (its
  repository's default branch, or nil) and, optionally, `long_lived` (true
  when its branch is another long-lived one); a session has `machine`,
  `session_id`, `repo` (nil when not known), `started_at`, `ended_at`,
  either `branch` (worked on for the whole session) or `spans` (each branch
  with when it was worked on, `%{branch, from, to}`), and, optionally,
  `nested` (true when a script or another tool started it).
  """
  def link(attempts, sessions) do
    by_branch =
      for s <- sessions, span <- span_list(s), reduce: %{} do
        acc -> Map.update(acc, span.branch, [{s, span}], &[{s, span} | &1])
      end

    for a <- attempts,
        pushed?(a),
        owner = owner(a, Map.get(by_branch, a.branch, [])),
        owner != nil,
        do: {a, owner}
  end

  defp span_list(%{spans: spans}) when is_list(spans), do: spans
  defp span_list(s), do: [%{branch: s.branch, from: s.started_at, to: s.ended_at}]

  defp pushed?(a) do
    is_binary(a.branch) and is_integer(a.at) and a.event not in @not_pushed and
      a.branch not in ["main", "master", a.default] and not Map.get(a, :long_lived, false) and
      not String.starts_with?(a.branch, "gh-readonly-queue/")
  end

  # Among the sessions on the attempt's branch, those on it when the attempt
  # began: one no script or other tool started first, then the latest start.
  defp owner(a, on_branch) do
    on_branch
    |> Enum.filter(fn {s, span} ->
      is_integer(span.from) and is_integer(span.to) and span.from <= a.at and
        a.at <= span.to + @after_s and
        (s.repo == nil or String.downcase(s.repo) == String.downcase(a.repo))
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq_by(&{&1.machine, &1.session_id})
    |> Enum.max_by(
      &{!Map.get(&1, :nested, false), &1.started_at || 0, &1.machine, &1.session_id},
      fn -> nil end
    )
  end

  @doc """
  Adds up attempts (with `paid`, `free`, `own`, `failed` and, optionally,
  `unknown`) into `%{paid, free, unknown, own, runs, failed}`.
  """
  def total(attempts) do
    %{
      paid: attempts |> Enum.map(& &1.paid) |> Enum.sum(),
      free: attempts |> Enum.map(& &1.free) |> Enum.sum(),
      unknown: attempts |> Enum.map(&Map.get(&1, :unknown, 0)) |> Enum.sum(),
      own: attempts |> Enum.map(& &1.own) |> Enum.sum(),
      runs: length(attempts),
      failed: Enum.count(attempts, & &1.failed)
    }
  end

  # The attempts of the saved runs that match `where` (over gh_runs as r):
  # each one's time, its minutes split by the repository's visibility, and
  # whether a job failed. The first attempt begins when its run was
  # created; a rerun when its first job was. `avoided` is the minutes on
  # your own machines GitHub would have billed: none on a public
  # repository, where its standard runners are free.
  defp attempts(where, params) do
    rows =
      Store.query(
        """
        SELECT r.repo, r.run_id, coalesce(j.attempt, 1) AS attempt, r.branch, r.event, r.pr,
          r.created_at, min(j.created_at) AS job_created,
          max(coalesce(j.conclusion, '') = 'failure') AS failed,
          sum(CASE WHEN #{@own} OR #{@mac_larger} OR #{@other_group} THEN 0
            ELSE #{@rounded} * #{@weight} END) AS hosted,
          sum(CASE WHEN #{@own} THEN 0 WHEN #{@mac_larger} THEN #{@rounded} * #{@weight}
            ELSE 0 END) AS larger,
          sum(CASE WHEN #{@own} OR #{@mac_larger} THEN 0
            WHEN #{@other_group} THEN #{@rounded} * #{@weight} ELSE 0 END) AS grouped,
          sum(CASE WHEN #{@own} THEN #{@rounded} ELSE 0 END) AS own
        FROM gh_runs r JOIN gh_jobs j ON j.repo = r.repo AND j.run_id = r.run_id
        WHERE #{where}
        GROUP BY r.repo, r.run_id, coalesce(j.attempt, 1)
        """,
        params
      )

    repos = rows |> Enum.map(& &1.repo) |> Enum.uniq()
    facts = Map.new(repos, &{&1, repo_facts(&1)})
    long_lived = Map.new(repos, &{&1, long_lived(&1)})

    for row <- rows,
        at = if(row.attempt > 1, do: row.job_created || row.created_at, else: row.created_at),
        is_integer(at) do
      public? = facts[row.repo][:private] == false
      hosted = row.hosted || 0
      grouped = row.grouped || 0
      own = row.own || 0

      %{
        repo: row.repo,
        run_id: row.run_id,
        attempt: row.attempt,
        branch: row.branch,
        event: row.event,
        pr: row.pr,
        at: at,
        default: facts[row.repo][:default_branch],
        long_lived: MapSet.member?(long_lived[row.repo], row.branch),
        failed: row.failed == 1,
        paid: if(public?, do: 0, else: hosted + grouped) + (row.larger || 0),
        free: if(public?, do: hosted, else: 0),
        unknown: if(public?, do: grouped, else: 0),
        own: own,
        avoided: if(public?, do: 0, else: own)
      }
    end
  end

  # The long-lived branches of `repo` besides its default one, by the rule
  # in the moduledoc: a pull request merged into the branch, and either the
  # branch's own pull request merged before the last merge into it, or it
  # has no pull request of its own. The board saves only closed pull
  # requests, so an open one of its own is known from GitHub's tag on a run
  # of the branch (GitHub tags none from a fork). A fork's pull request
  # only shares the branch's name, as in `PullRequests`.
  defp long_lived(repo) do
    Store.query(
      """
      SELECT t.base AS branch FROM
        (SELECT base, max(merged_at) AS last_in FROM gh_prs
          WHERE lower(repo) = lower(?1) AND merged_at IS NOT NULL AND base IS NOT NULL
          GROUP BY base) t
        LEFT JOIN
        (SELECT branch, max(merged_at) AS merged FROM gh_prs
          WHERE lower(repo) = lower(?1) AND lower(head_repo) = lower(repo)
          GROUP BY branch) o ON o.branch = t.base
      WHERE CASE WHEN o.merged IS NOT NULL THEN t.last_in > o.merged
        ELSE o.branch IS NULL AND NOT EXISTS
          (SELECT 1 FROM gh_runs r
            WHERE lower(r.repo) = lower(?1) AND r.branch = t.base AND r.pr IS NOT NULL) END
      """,
      [repo]
    )
    |> MapSet.new(& &1.branch)
  end

  # Saved sessions matching `where`, as `link/2` takes them. A session saves
  # its repository (as "owner/name"); one saved before that has it read from
  # its folder, once per folder, which works for this machine's own.
  defp sessions(where, params) do
    rows =
      Store.query(
        """
        SELECT machine, session_id, coalesce(tool, 'claude') AS tool, entrypoint, git_branch,
          json_extract(detail, '$.branches') AS branches, started_at, ended_at, cwd, source,
          nullif(repo, '') AS repo
        FROM sessions WHERE #{where}
        """,
        params
      )

    repos =
      rows
      |> Enum.filter(&(&1.repo == nil and &1.source in [nil, ""]))
      |> Enum.map(& &1.cwd)
      |> Enum.uniq()
      |> Map.new(&{&1, GitRemote.github_repo(&1)})

    Enum.map(rows, fn row ->
      %{
        machine: row.machine,
        session_id: row.session_id,
        tool: row.tool,
        nested: row.entrypoint in @nested,
        repo: row.repo || if(row.source in [nil, ""], do: repos[row.cwd]),
        spans:
          spans(%{
            git_branch: row.git_branch,
            started_at: row.started_at,
            ended_at: row.ended_at,
            detail: %{"branches" => listed(row)}
          }),
        started_at: row.started_at,
        ended_at: row.ended_at
      }
    end)
  end

  defp listed(%{branches: text}) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  defp listed(_), do: []

  @doc """
  What the board last read about a repository from GitHub: `private` (true
  or false), `default_branch` and `day` (when it was read), or an empty map
  before the first read.
  """
  def repo_facts(repo) do
    with v when is_binary(v) <- Store.get_meta(meta_key(repo)),
         {:ok, %{"private" => private} = m} when is_boolean(private) <- Jason.decode(v) do
      %{private: private, default_branch: m["default_branch"], day: m["day"]}
    else
      _ -> %{}
    end
  end

  @doc "The meta key `repo_facts/1` reads and the GitHub collector writes."
  def meta_key(repo), do: "github_repo:" <> String.downcase(repo)
end
