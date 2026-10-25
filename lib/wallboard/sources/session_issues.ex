defmodule Wallboard.Sources.SessionIssues do
  @moduledoc """
  Which issue each live session is on, so its card on the Agents tab can
  show it, as `#1418`. First match wins:

    1. The first prompt in the session that names an issue, written the way
       people write one: `#1418`, `issue 1418`, a link to the issue, or a
       project-board link that opens it (see `Wallboard.IssueRef`). A link
       names its repository; otherwise it is the session's own. A number
       that is not an issue there (a pull request, or no such number) does
       not count, and a later prompt naming another issue does not change it.
    2. Else an open pull request from the session's branch, in the
       session's own repository, that closes an issue there.
    3. Neither: no issue.

  Robert, October 24, 2026: "from the first prompt that names one: yes".

  It reads only what live sessions point at, through the signed-in `gh`:
  one REST call for each issue, and one GraphQL call for each repository
  with branches to look up. Each issue and each branch is read at most
  every two minutes, and no repository's whole list of issues or milestones
  is ever asked for.

  What a prompt named comes with the session: the usage reader keeps it for
  this machine's Claude sessions, a Codex card carries it, and a collector
  sends it for a session on another machine. A session's repository and
  branch come from its card, or for one on this machine from its folder
  (see `Wallboard.GitRemote`).

  The same read of an issue gives the milestone it is in, with GitHub's
  own counts of its open and closed issues, so the Agents tab can show how
  far down each milestone being worked is (issue #144): one line for each
  milestone a matched issue is in, none for a milestone no live session
  is on.

  The facts are `%{sessions: %{card_key => %{repo, number}}, milestones:
  [%{repo, number, done, total, title_hash}]}`. Sessions are keyed by each
  card's own `key`, which a streamed card's machine is part of, so two
  machines sending the same session id never share an issue. Numbers and
  names only, so nothing from an issue or a prompt reaches the board or a
  log. A milestone's title is GitHub text: it goes only to
  `Wallboard.MilestoneTitles`, and the facts carry its hash, so a renamed
  milestone still counts as a change.
  """

  alias Wallboard.{Cmd, GitRemote, MilestoneTitles, Poller}

  # How long a read stands before it is asked again.
  @fresh_s 120

  # How long one call to GitHub may take.
  @read_ms 20_000

  # At most this many calls to GitHub in one check, four at a time. With
  # each call allowed @read_ms, a check ends inside the poller's two
  # minutes even when GitHub is slow, so what it read is kept. What is left
  # waits for the next check, oldest read first.
  @per_check 8

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(_settings, _prev, memory, now) do
    {facts, memory} = match(live_sessions(), memory || %{}, now)
    {:ok, facts, memory}
  end

  def fingerprint(facts), do: facts

  # Every live session the board shows: this machine's Claude and Codex
  # sessions, and those a collector streams from another machine. As on the
  # board (BoardLive.derive_sessions/1), a session shows once, and this
  # machine's own copy comes first.
  defp live_sessions do
    # What this machine's Claude sessions' prompts named, by session id. The
    # usage reader's first read can take minutes after a start; while it is
    # still on it they wait, so a branch's issue never stands in. A read
    # that failed, or a reader that is not running, ends the wait: their
    # branches still count.
    %{facts: usage, meta: meta} = Poller.snapshot(:usage)
    named = (usage || %{})[:sessions] || %{}
    reading? = is_nil(usage) and is_nil(meta[:error])

    local =
      for name <- [:claude, :codex],
          s <- (Poller.snapshot(name).facts || %{})[:sessions] || [],
          do:
            Map.merge(s, %{
              repo: GitRemote.github_repo(s[:cwd]),
              branch: GitRemote.branch(s[:cwd]),
              issue_refs:
                s[:issue_refs] ||
                  if(reading?, do: :waiting, else: named[s[:session_id]][:issues] || []),
              local?: true
            })

    local_ids = MapSet.new(local, & &1[:session_id])

    stream =
      for s <- Wallboard.Link.Sessions.cards(),
          not MapSet.member?(local_ids, s[:session_id]),
          do: Map.put(s, :repo, s[:gh_repo])

    local ++ stream
  end

  # ---------------------------------------------------------------------------
  # Matching

  # What to ask GitHub about a session, in order: the issues its prompts
  # named, then its branch's pull requests. Only names fit to send.
  defp keys(%{issue_refs: :waiting}), do: []

  defp keys(s) do
    named =
      for %{number: n} = ref <- List.wrap(s[:issue_refs]),
          is_integer(n),
          n > 0,
          do: {:issue, ref[:repo] || s[:repo], n}

    branch = if is_binary(s[:branch]), do: [{:branch, s[:repo], s.branch}], else: []

    Enum.filter(named ++ branch, fn key -> repo?(elem(key, 1)) end)
  end

  @doc """
  The issue each session is on, from what GitHub says and what was read in
  the last two minutes: `{facts, memory}`. `sessions` are maps with
  `key` (the card's), `issue_refs` (`[%{repo, number}]`, what its prompts named),
  `repo` (`owner/name`) and `branch`; `memory` holds each read and when it
  was made.
  """
  def match(sessions, memory, now) do
    # Each read's milestone sits beside it as {:milestone, key} while the
    # check runs, and in its own map between checks.
    reads =
      for {key, read} <- memory[:milestones] || %{},
          into: memory[:reads] || %{},
          do: {{:milestone, key}, read}

    at = DateTime.to_unix(now)

    wants =
      for s <- sessions,
          is_binary(s[:key]),
          keys = keys(s),
          keys != [],
          do: {s, keys}

    # A session has at most four keys (three named, one branch), so four
    # rounds settle every one.
    reads = settle(wants, reads, at, 4)

    picked = for {s, keys} <- wants, key = pick(keys, reads), do: {s, key}

    sessions =
      for {s, key} <- picked,
          into: %{},
          do: {s.key, %{repo: elem(key, 1), number: found(key, reads[key])}}

    keys = Enum.flat_map(wants, &elem(&1, 1))

    kept = %{
      reads: Map.take(reads, keys),
      milestones: for(key <- keys, read = reads[{:milestone, key}], into: %{}, do: {key, read})
    }

    {%{sessions: sessions, milestones: milestones(picked, reads)}, kept}
  end

  # One for each milestone a session's issue is in. Two issues in the same
  # milestone can be read at different times; the later read's counts win.
  defp milestones(picked, reads) do
    picked
    |> Enum.map(fn {_s, key} -> reads[{:milestone, key}] end)
    |> Enum.filter(&match?({%{}, _}, &1))
    |> Enum.group_by(fn {m, _} -> {String.downcase(m.repo), m.number} end)
    |> Enum.map(fn {_, read} -> read |> Enum.max_by(&elem(&1, 1)) |> elem(0) end)
    |> Enum.sort_by(&{String.downcase(&1.repo), &1.number})
  end

  # The key that gives a session's issue. A named issue that is not known
  # yet, because its read failed or has not been made, stops the walk, so
  # an earlier read of the branch never stands in for it.
  defp pick([], _reads), do: nil

  defp pick([key | rest], reads) do
    cond do
      found(key, reads[key]) -> key
      match?({:issue, _, _}, key) and not match?({false, _}, reads[key]) -> nil
      true -> pick(rest, reads)
    end
  end

  # Reads, round by round, the first key of each session with no fresh
  # read, passing over keys a fresh read says are on no issue. A session
  # whose prompt named an issue never has its branch asked about.
  defp settle(wants, reads, at, rounds, calls \\ @per_check) do
    # This machine's own sessions first, so a collector streaming many new
    # ones cannot keep them from being read again.
    mine = for {%{local?: true}, keys} <- wants, key <- keys, into: MapSet.new(), do: key

    jobs =
      wants
      |> Enum.map(fn {_s, keys} -> next_stale(keys, reads, at) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> jobs()
      |> Enum.sort_by(fn job ->
        {if(Enum.any?(job_keys(job), &MapSet.member?(mine, &1)), do: 0, else: 1),
         read_at(job, reads)}
      end)
      |> Enum.take(calls)

    if jobs == [] or rounds == 0,
      do: reads,
      else:
        settle(
          wants,
          Map.merge(reads, read_all(jobs, reads, at)),
          at,
          rounds - 1,
          calls - length(jobs)
        )
  end

  # One call to GitHub for each issue, and one for each repository's
  # branches together.
  defp jobs(keys) do
    {issues, branches} = Enum.split_with(keys, &match?({:issue, _, _}, &1))

    issues ++
      (branches
       |> Enum.group_by(fn {:branch, repo, _} -> repo end, fn {:branch, _, b} -> b end)
       |> Enum.map(fn {repo, names} -> {:branches, repo, names} end))
  end

  # When a call's answer was last read, or 0 when never.
  defp read_at({:branches, repo, names}, reads),
    do: names |> Enum.map(&read_at({:branch, repo, &1}, reads)) |> Enum.min()

  defp read_at(key, reads) do
    case reads[key] do
      {_, at} -> at
      _ -> 0
    end
  end

  defp job_keys({:branches, repo, names}), do: Enum.map(names, &{:branch, repo, &1})
  defp job_keys(key), do: [key]

  defp next_stale([], _reads, _at), do: nil

  # An issue read that failed with nothing read before is unknown, not "no
  # issue": the session waits for it rather than taking its branch's.
  defp next_stale([key | rest], reads, at) do
    cond do
      not fresh?(reads[key], at) -> key
      found(key, reads[key]) -> nil
      match?({:issue, _, _}, key) and match?({nil, _}, reads[key]) -> nil
      true -> next_stale(rest, reads, at)
    end
  end

  # The name goes into the path of a call to GitHub, and a collector on
  # another machine can send it.
  defp repo?(repo), do: Wallboard.RepoPrompts.name?(repo)

  defp fresh?({_value, read_at}, at), do: at - read_at < @fresh_s
  defp fresh?(_, _at), do: false

  # What a read says the session is on.
  defp found({:issue, _repo, n}, {true, _}), do: n
  defp found({:branch, _repo, _}, {n, _}) when is_integer(n), do: n
  defp found(_key, _read), do: nil

  # Makes each call, four at a time. A read that fails keeps what was read
  # before, and waits the usual two minutes before it is asked again.
  defp read_all(jobs, reads, at) do
    jobs
    |> Task.async_stream(&read_job(&1, reads, at),
      max_concurrency: 4,
      timeout: @read_ms + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(jobs)
    |> Enum.flat_map(fn
      {{:ok, read}, _job} ->
        read

      {{:exit, _}, job} ->
        Enum.flat_map(job_keys(job), fn key ->
          [{key, {kept(key, reads), at}}, {{:milestone, key}, {kept_milestone(key, reads), at}}]
        end)
    end)
    |> Map.new()
  end

  defp read_job({:issue, repo, n} = key, reads, at) do
    {issue?, milestone} = issue?(repo, n, reads[key], kept_milestone(key, reads))
    [{key, {issue?, at}}, {{:milestone, key}, {milestone, at}}]
  end

  defp read_job({:branches, repo, names}, reads, at), do: closing(repo, names, reads, at)

  # What a read that failed keeps: the last answer.
  defp kept({:issue, _, _} = key, reads), do: last_value(reads[key])
  defp kept(key, reads), do: found(key, reads[key])

  defp kept_milestone(key, reads), do: last_value(reads[{:milestone, key}])

  # Whether the number is an issue in the repository: GitHub's issues call
  # also answers for a pull request, which carries "pull_request".
  # Not an issue here, too: one GitHub has deleted (410) or no such number
  # (404), and one moved to another repository, which gh follows to its
  # new number. With it, `{issue?, milestone}`: the milestone it is in, or
  # what was last read when the read fails.
  defp issue?(repo, n, last, last_milestone) do
    case Cmd.run("gh", ["api", "repos/#{repo}/issues/#{n}"], timeout: @read_ms) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"number" => ^n, "pull_request" => _}} -> {false, nil}
          {:ok, %{"number" => ^n} = issue} -> {true, milestone(repo, issue["milestone"])}
          {:ok, %{"number" => _moved}} -> {false, nil}
          _ -> {last_value(last), last_milestone}
        end

      {:error, reason} ->
        if reason =~ ~r/HTTP 4(04|10)\b/,
          do: {false, nil},
          else: {last_value(last), last_milestone}
    end
  end

  # A milestone as GitHub's REST or GraphQL answer gives it. Its title goes
  # only to MilestoneTitles; what is kept is its number, its counts and the
  # title's hash.
  defp milestone(repo, %{
         "number" => n,
         "title" => t,
         "open_issues" => open,
         "closed_issues" => closed
       }),
       do: shown(repo, n, t, open, closed)

  defp milestone(repo, %{
         "number" => n,
         "title" => t,
         "openIssueCount" => open,
         "closedIssueCount" => closed
       }),
       do: shown(repo, n, t, open, closed)

  defp milestone(_repo, _), do: nil

  defp shown(repo, n, title, open, closed)
       when is_integer(n) and is_binary(title) and is_integer(open) and is_integer(closed) and
              open >= 0 and closed >= 0 do
    MilestoneTitles.put(repo, n, title)

    %{
      repo: repo,
      number: n,
      done: closed,
      total: open + closed,
      title_hash: :erlang.phash2(title)
    }
  end

  defp shown(_repo, _n, _title, _open, _closed), do: nil

  # The last answer, or nil (unknown) when there was none.
  defp last_value({value, _}), do: value
  defp last_value(_), do: nil

  # The first issue in the same repository that an open pull request from
  # each branch closes, and its milestone: [{key, {number or nil, at}}] and
  # the same for {:milestone, key}. One query for the repository, each
  # branch a variable.
  defp closing(repo, names, reads, at) do
    names = Enum.with_index(names)
    [owner, name] = String.split(repo, "/", parts: 2)

    query = """
    query($owner: String!, $name: String!#{Enum.map_join(names, fn {_, i} -> ", $b#{i}: String!" end)}) {
      repository(owner: $owner, name: $name) {
        #{Enum.map_join(names, "\n", fn {_, i} -> "b#{i}: pullRequests(headRefName: $b#{i}, states: OPEN, first: 5) { nodes { headRepository { nameWithOwner } closingIssuesReferences(first: 5) { nodes { number repository { nameWithOwner } milestone { number title openIssueCount closedIssueCount } } } } }" end)}
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

    Enum.flat_map(names, fn {b, i} ->
      key = {:branch, repo, b}

      {value, milestone} =
        if answer,
          do: first_closed(answer["b#{i}"], repo) || {nil, nil},
          else: {kept(key, reads), kept_milestone(key, reads)}

      [{key, {value, at}}, {{:milestone, key}, {milestone, at}}]
    end)
  end

  # A pull request's branch is the session's only when it is in the
  # session's repository: GitHub matches headRefName in forks too.
  defp first_closed(%{"nodes" => prs}, repo) when is_list(prs) do
    Enum.find_value(prs, fn pr ->
      if same_repo?(get_in(pr, ["headRepository", "nameWithOwner"]), repo) do
        (get_in(pr, ["closingIssuesReferences", "nodes"]) || [])
        |> Enum.find_value(fn
          %{"number" => n, "repository" => %{"nameWithOwner" => name}} = issue ->
            if same_repo?(name, repo), do: {n, milestone(repo, issue["milestone"])}

          _ ->
            nil
        end)
      end
    end)
  end

  defp first_closed(_, _repo), do: nil

  # GitHub's names ignore capitals, and a folder's remote keeps whatever
  # spelling it was cloned with.
  defp same_repo?(name, repo) when is_binary(name),
    do: String.downcase(name) == String.downcase(repo)

  defp same_repo?(_name, _repo), do: false
end
