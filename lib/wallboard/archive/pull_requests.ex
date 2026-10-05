defmodule Wallboard.Archive.PullRequests do
  @moduledoc """
  The merged pull requests of the tracked repositories, each with the
  sessions that worked on it and what they spent: the base for every "per
  merged PR" number.

  A session counts toward a merged pull request when either

    * it opened it: Claude writes a `pr-link` line for each pull request a
      session opens, saved in the session's details, or
    * it ran on the pull request's branch in the same repository and started
      before the merge. This is how Codex sessions are found (Codex records
      the branch, not the pull request), and how a session that reviewed or
      fixed a pull request it did not open is counted. A long-lived branch
      ties no session this way: a release from main into production did not
      do the work of every session on main. A branch is long-lived when it
      is the repository's default branch, or when another pull request
      merged into it after its own pull request merged (develop, which
      keeps taking features after each release). A stacked branch, merged
      into before its own merge, still counts. Nor does a fork's branch tie
      sessions, since it only shares a name with one here.

  A session tied to several merged pull requests splits its cost and tokens
  evenly between them, so a dollar is never counted twice. Repository names
  are matched without regard to case, as GitHub does.

  Pull requests come from the GitHub archive (`gh_prs`), sessions from the
  saved sessions; a session saved before its repository was recorded has
  it read from its folder, which works for this machine's own sessions.
  """

  alias Wallboard.{GitRemote, Settings, Store}

  # How long before a pull request was opened a session on its branch may
  # have started: work on a branch begins before its pull request does.
  @lead_days 30

  @doc """
  The pull requests of the tracked repositories merged at or after `from`
  (Unix seconds), oldest merge first. Each is a map with `repo`, `number`,
  `title`, `url`, `branch`, `created_at`, `merged_at` and

    * `sessions`: `[%{machine, session_id, tool, share}]`, where `share` is
      the part of that session's spending that goes to this pull request
    * `cost`: the Claude dollars of those sessions, by share
    * `tokens` and `codex_tokens`: their tokens for each tool, by share
    * `claude_sessions` and `codex_sessions`: how many of each worked on it
  """
  def merged(settings, from) do
    tracked = settings |> Settings.repo_names() |> MapSet.new(&String.downcase/1)

    prs =
      Store.query(
        """
        SELECT repo, number, title, url, branch, head_repo, base, default_branch, created_at,
          merged_at
        FROM gh_prs WHERE merged_at >= ?1 ORDER BY merged_at, repo, number
        """,
        [from]
      )
      |> Enum.filter(&MapSet.member?(tracked, String.downcase(&1.repo)))

    link(prs, sessions(prs))
  end

  @doc """
  Ties sessions to pull requests (both as `merged/2` reads them) and adds up
  each pull request's share of their spending. Pure, for the tests.
  """
  def link(prs, sessions) do
    by_number = Map.new(prs, &{{String.downcase(&1.repo), &1.number}, &1})

    # The last merge into each branch. A merge after a pull request's own is
    # always in `prs` too, since they run from `from` to now.
    merged_into =
      Enum.reduce(prs, %{}, fn pr, acc ->
        Map.update(acc, {String.downcase(pr.repo), pr.base}, pr.merged_at, &max(&1, pr.merged_at))
      end)

    by_branch =
      prs
      |> Enum.filter(fn pr ->
        repo = String.downcase(pr.repo)

        is_binary(pr.branch) and is_binary(pr[:head_repo]) and
          String.downcase(pr.head_repo) == repo and pr.branch != pr[:default_branch] and
          Map.get(merged_into, {repo, pr.branch}, 0) <= pr.merged_at
      end)
      |> Enum.group_by(&{String.downcase(&1.repo), &1.branch})

    shares =
      Enum.flat_map(sessions, fn s ->
        keys =
          (opened(s, by_number) ++ on_branch(s, by_branch))
          |> Enum.uniq()

        Enum.map(keys, &{&1, s, 1 / length(keys)})
      end)
      |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))

    Enum.map(prs, fn pr ->
      linked = Map.get(shares, {String.downcase(pr.repo), pr.number}, [])
      by_tool = fn tool -> Enum.filter(linked, fn {s, _} -> s.tool == tool end) end
      sum = fn list, f -> list |> Enum.map(fn {s, share} -> f.(s) * share end) |> Enum.sum() end

      pr
      |> Map.drop([:base, :head_repo, :default_branch])
      |> Map.merge(%{
        sessions:
          Enum.map(linked, fn {s, share} ->
            %{machine: s.machine, session_id: s.session_id, tool: s.tool, share: share}
          end),
        cost: sum.(by_tool.("claude"), & &1.cost),
        tokens: sum.(by_tool.("claude"), & &1.tokens),
        codex_tokens: sum.(by_tool.("codex"), & &1.tokens),
        claude_sessions: length(by_tool.("claude")),
        codex_sessions: length(by_tool.("codex"))
      })
    end)
  end

  # The pull requests the session opened, among the merged ones.
  defp opened(s, by_number) do
    for %{"repo" => repo, "number" => n} when is_binary(repo) and is_integer(n) <- s.prs,
        Map.has_key?(by_number, {String.downcase(repo), n}),
        do: {String.downcase(repo), n}
  end

  # The first merged pull request of the session's branch that merged after
  # the session started: the one its work went into.
  defp on_branch(%{repo: repo, branch: branch} = s, by_branch)
       when is_binary(repo) and is_binary(branch) do
    by_branch
    |> Map.get({String.downcase(repo), branch}, [])
    |> Enum.filter(&(is_nil(s.started_at) or s.started_at <= &1.merged_at))
    |> Enum.min_by(& &1.merged_at, fn -> nil end)
    |> case do
      nil -> []
      pr -> [{String.downcase(pr.repo), pr.number}]
    end
  end

  defp on_branch(_s, _by_branch), do: []

  # The saved sessions that could have worked on these pull requests: those
  # still going when the earliest was opened, less a lead for branch work.
  defp sessions([]), do: []

  defp sessions(prs) do
    from = prs |> Enum.map(&(&1.created_at || &1.merged_at)) |> Enum.min()

    Store.query(
      """
      SELECT s.machine, s.session_id, coalesce(s.tool, 'claude') AS tool, s.repo, s.cwd, s.source,
        s.git_branch AS branch, s.started_at, coalesce(s.cost, 0) AS cost,
        coalesce(s.input_tokens, 0) + coalesce(s.output_tokens, 0)
          + coalesce(s.cache_read_tokens, 0) + coalesce(s.cache_write_tokens, 0) AS tokens,
        json_extract(s.detail, '$.prs') AS prs
      FROM sessions s
      WHERE s.ended_at >= ?1 AND (s.started_at IS NULL OR s.started_at <= ?2)
      """,
      [from - @lead_days * 86_400, prs |> Enum.map(& &1.merged_at) |> Enum.max()]
    )
    |> Enum.map(fn s ->
      %{
        s
        | repo: s.repo || folder_repo(s),
          prs: decode_prs(s.prs)
      }
      |> Map.drop([:cwd, :source])
    end)
  end

  # Rows saved before the repo column: this machine's own folders can still
  # be read.
  defp folder_repo(%{source: source, cwd: cwd}) when source in [nil, ""],
    do: GitRemote.github_repo(cwd)

  defp folder_repo(_), do: nil

  defp decode_prs(nil), do: []

  defp decode_prs(text) do
    case Jason.decode(text) do
      {:ok, list} when is_list(list) -> Enum.filter(list, &is_map/1)
      _ -> []
    end
  end
end
