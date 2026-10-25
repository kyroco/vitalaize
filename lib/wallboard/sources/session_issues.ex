defmodule Wallboard.Sources.SessionIssues do
  @moduledoc """
  Which issue each live session is on, so its card on the Agents tab can
  show it, as `#1418`. First match wins:

    1. An issue number in the session's name, then one in its branch:
       `1418-issue`, `robert/1418-short-title`. The first number in each
       counts, and the first of those that is an issue in the session's
       repository wins: a pull request or a number with no issue is passed
       over. A name with a space in it is a title or a prompt, not a name
       picked for the issue, so its numbers do not count.
    2. With no number, an open pull request from the session's branch that
       closes an issue in the same repository.
    3. Neither: no issue.

  It reads only what live sessions point at, through the signed-in `gh`:
  one REST call for each issue number, and one GraphQL call for each
  repository with branches to look up. Each issue and each branch is read
  at most every two minutes, and no repository's whole list of issues or
  milestones is ever asked for.

  A session's repository and branch come from its card: a collector sends
  both, and a session on this machine has them read from its folder (see
  `Wallboard.GitRemote`).

  The facts are `%{sessions: %{session_id => %{repo, number}}}`, numbers
  only, so nothing from an issue's text reaches the board or a log.
  """

  alias Wallboard.{Cmd, GitRemote, Poller}

  # How long a read stands before it is asked again.
  @fresh_s 120

  # How long one call to GitHub may take.
  @read_ms 20_000

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(_settings, _prev, memory, now) do
    {facts, memory} = match(live_sessions(), memory || %{}, now)
    {:ok, facts, memory}
  end

  def fingerprint(facts), do: facts

  # Every live session the board shows: this machine's Claude and Codex
  # sessions, and those a collector streams from another machine.
  defp live_sessions do
    local =
      for name <- [:claude, :codex],
          s <- (Poller.snapshot(name).facts || %{})[:sessions] || [],
          do:
            Map.merge(s, %{
              repo: GitRemote.github_repo(s[:cwd]),
              branch: GitRemote.branch(s[:cwd])
            })

    stream =
      for s <- Wallboard.Link.Sessions.cards(),
          do: Map.merge(s, %{repo: s[:gh_repo], branch: s[:branch]})

    local ++ stream
  end

  # ---------------------------------------------------------------------------
  # Matching

  @doc """
  The first issue number standing alone in a session's name, or else in
  its branch, or nil. A number stands alone when it starts the text or
  follows `/`, `-`, `_`, `#` or a space, and ends it or comes before one of
  those: `1418-issue` and `robert/1418-fix-1420` give 1418, while a short
  id like `4d6407ac` or a version like `v0.4.2` gives nothing. A name with
  a space in it counts for nothing (see the rules above).
  """
  def number(%{} = session), do: session |> numbers() |> List.first()

  def number(text) when is_binary(text) do
    case Regex.run(~r{(?:^|[/\-_# ])(\d+)(?=$|[/\-_# ])}, text) do
      [_, digits] -> String.to_integer(digits)
      _ -> nil
    end
  end

  def number(_), do: nil

  # The numbers to try, in order: the name's, then the branch's.
  defp numbers(session) do
    [name_number(session), number(session[:branch])]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp name_number(%{name: name} = session) when is_binary(name) do
    # A session with no name is named after the start of its id, which can
    # be all digits; Codex and streamed sessions are named from a title or
    # their first prompt, which have spaces.
    id? = is_binary(session[:session_id]) and String.starts_with?(session.session_id, name)
    if id? or name =~ ~r/\s/, do: nil, else: number(name)
  end

  defp name_number(_), do: nil

  # What to ask GitHub about a session, in order: each of its numbers, or,
  # with no number, its branch's pull requests.
  defp keys(s) do
    case numbers(s) do
      [] -> if is_binary(s[:branch]), do: [{:branch, s.repo, s.branch}], else: []
      ns -> Enum.map(ns, &{:issue, s.repo, &1})
    end
  end

  @doc """
  The issue each session is on, from what GitHub says and what was read in
  the last two minutes: `{facts, memory}`. `sessions` are maps with
  `session_id`, `name`, `repo` (`owner/name`) and `branch`; `memory` holds
  each read and when it was made.
  """
  def match(sessions, memory, now) do
    reads = memory[:reads] || %{}
    at = DateTime.to_unix(now)

    wants =
      for s <- sessions,
          is_binary(s[:session_id]),
          repo?(s[:repo]),
          keys = keys(s),
          keys != [],
          do: {s, keys}

    # A session has at most two keys, so two rounds settle every one.
    reads = settle(wants, reads, at, 2)

    sessions =
      for {s, keys} <- wants,
          number = Enum.find_value(keys, &found(&1, reads[&1])),
          into: %{},
          do: {s.session_id, %{repo: s.repo, number: number}}

    {%{sessions: sessions}, %{reads: Map.take(reads, Enum.flat_map(wants, &elem(&1, 1)))}}
  end

  # Reads, round by round, the first key of each session with no fresh
  # read, passing over keys a fresh read says are on no issue. A session
  # whose name gives an issue never has its branch asked about.
  defp settle(wants, reads, at, rounds) do
    stale =
      wants
      |> Enum.map(fn {_s, keys} -> next_stale(keys, reads, at) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if stale == [] or rounds == 0,
      do: reads,
      else: settle(wants, Map.merge(reads, read_all(stale, reads, at)), at, rounds - 1)
  end

  defp next_stale([], _reads, _at), do: nil

  defp next_stale([key | rest], reads, at) do
    cond do
      not fresh?(reads[key], at) -> key
      found(key, reads[key]) -> nil
      true -> next_stale(rest, reads, at)
    end
  end

  defp repo?(repo), do: is_binary(repo) and repo =~ ~r{^[\w.-]+/[\w.-]+$}

  defp fresh?({_value, read_at}, at), do: at - read_at < @fresh_s
  defp fresh?(_, _at), do: false

  # What a read says the session is on.
  defp found({:issue, _repo, n}, {true, _}), do: n
  defp found({:branch, _repo, _}, {n, _}) when is_integer(n), do: n
  defp found(_key, _read), do: nil

  # Reads every stale key: each issue on its own, each repository's
  # branches together. A read that fails keeps what was read before, and
  # waits the usual two minutes before it is asked again.
  defp read_all(keys, reads, at) do
    {issues, branches} = Enum.split_with(keys, &match?({:issue, _, _}, &1))

    # Four at a time, so a board with many sessions stays inside the
    # poller's time limit.
    issue_reads =
      issues
      |> Task.async_stream(
        fn {:issue, repo, n} = key -> {key, {issue?(repo, n, reads[key]), at}} end,
        max_concurrency: 4,
        timeout: @read_ms + 5_000,
        on_timeout: :kill_task
      )
      |> Enum.zip(issues)
      |> Map.new(fn
        {{:ok, read}, _key} -> read
        {{:exit, _}, key} -> {key, {last_value(reads[key]), at}}
      end)

    branch_reads =
      branches
      |> Enum.group_by(fn {:branch, repo, _} -> repo end, fn {:branch, _, b} -> b end)
      |> Enum.flat_map(fn {repo, names} -> closing(repo, names, reads, at) end)
      |> Map.new()

    Map.merge(issue_reads, branch_reads)
  end

  # Whether the number is an issue in the repository: GitHub's issues call
  # also answers for a pull request, which carries "pull_request".
  defp issue?(repo, n, last) do
    case Cmd.run("gh", ["api", "repos/#{repo}/issues/#{n}"], timeout: @read_ms) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"number" => ^n} = issue} -> not Map.has_key?(issue, "pull_request")
          _ -> last_value(last)
        end

      {:error, reason} ->
        if reason =~ "HTTP 404", do: false, else: last_value(last)
    end
  end

  defp last_value({value, _}), do: value
  defp last_value(_), do: false

  # The first issue in the same repository that an open pull request from
  # each branch closes: [{key, {number or nil, at}}]. One query for the
  # repository, each branch a variable.
  defp closing(repo, names, reads, at) do
    names = Enum.with_index(names)
    [owner, name] = String.split(repo, "/", parts: 2)

    query = """
    query($owner: String!, $name: String!#{Enum.map_join(names, fn {_, i} -> ", $b#{i}: String!" end)}) {
      repository(owner: $owner, name: $name) {
        #{Enum.map_join(names, "\n", fn {_, i} -> "b#{i}: pullRequests(headRefName: $b#{i}, states: OPEN, first: 5) { nodes { closingIssuesReferences(first: 5) { nodes { number repository { nameWithOwner } } } } }" end)}
      }
    }
    """

    vars =
      ["-f", "owner=" <> owner, "-f", "name=" <> name] ++
        Enum.flat_map(names, fn {b, i} -> ["-f", "b#{i}=" <> b] end)

    answer =
      with {:ok, text} <-
             Cmd.run("gh", ["api", "graphql", "-f", "query=" <> query | vars], timeout: @read_ms),
           {:ok, %{"data" => %{"repository" => %{} = got}}} <- Jason.decode(text) do
        got
      else
        _ -> nil
      end

    for {b, i} <- names do
      key = {:branch, repo, b}

      value =
        if answer,
          do: first_closed(answer["b#{i}"], repo),
          else: last_value(reads[key]) |> then(&if(is_integer(&1), do: &1))

      {key, {value, at}}
    end
  end

  defp first_closed(%{"nodes" => prs}, repo) when is_list(prs) do
    Enum.find_value(prs, fn pr ->
      (get_in(pr, ["closingIssuesReferences", "nodes"]) || [])
      |> Enum.find_value(fn
        %{"number" => n, "repository" => %{"nameWithOwner" => ^repo}} -> n
        _ -> nil
      end)
    end)
  end

  defp first_closed(_, _repo), do: nil
end
