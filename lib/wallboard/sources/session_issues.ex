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

  The same read of an issue gives the number of the milestone it is in,
  so the Agents tab can show how far down each milestone being worked is
  (issue #144): one line for each milestone a matched issue is in, none
  for a milestone no live session is on. Each such milestone's own counts
  of its issues, done and in all, are read once for the milestone, at most
  every two minutes, as GitHub's totals: never its list of issues. Pull
  requests in a milestone are not its issues, and do not count.

  The facts are `%{sessions: %{card_key => %{repo, number}}, milestones:
  [%{repo, number, done, total, rev, sessions}]}`. Sessions are keyed by
  each card's own `key`, which a streamed card's machine is part of, so
  two machines sending the same session id never share an issue; a
  milestone lists the card keys on it. Numbers and names only, so nothing
  from an issue or a prompt reaches the board or a log. A milestone's
  title is GitHub text: it goes only to `Wallboard.MilestoneTitles`, and
  the facts carry its revision there, so a renamed milestone still counts
  as a change.
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
    # The milestone each read gives sits beside it as {:milestone, key},
    # and each milestone's counts as {:counts, repo, number}, while the
    # check runs; between checks, each in its own map.
    reads =
      for {key, read} <- memory[:milestones] || %{},
          into: Map.merge(memory[:reads] || %{}, memory[:counts] || %{}),
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
    {reads, calls} = settle(wants, reads, at, 4)

    picked = for {s, keys} <- wants, key = pick(keys, reads), do: {s, key}

    # Each session's milestone, as {counts key, card key}.
    on =
      for {s, key} <- picked,
          {n, _} <- [reads[{:milestone, key}]],
          is_integer(n),
          do: {{:counts, String.downcase(elem(key, 1)), n}, s.key}

    counts = on |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    reads = read_counts(counts, reads, at, calls)

    sessions =
      for {s, key} <- picked,
          into: %{},
          do: {s.key, %{repo: elem(key, 1), number: found(key, reads[key])}}

    keys = Enum.flat_map(wants, &elem(&1, 1))

    kept = %{
      reads: Map.take(reads, keys),
      milestones: for(key <- keys, read = reads[{:milestone, key}], into: %{}, do: {key, read}),
      counts: Map.take(reads, counts)
    }

    {%{sessions: sessions, milestones: milestones(on, reads)}, kept}
  end

  # One for each milestone a session's issue is in whose counts are known,
  # with the cards on it.
  defp milestones(on, reads) do
    on
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {{:counts, repo, n} = key, cards} ->
      case reads[key] do
        {%{} = c, _} ->
          [
            %{
              repo: repo,
              number: n,
              done: c.done,
              total: c.total,
              rev: c.rev,
              sessions: Enum.sort(cards)
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&{&1.repo, &1.number})
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
      do: {reads, calls},
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
  # Nothing compares when two reads were made, so a kept answer standing
  # at the new time can never outrank a newer one.
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
        failed(kept_keys(job), reads, at)
    end)
    |> Map.new()
  end

  defp read_job({:issue, repo, n} = key, reads, at) do
    case issue?(repo, n) do
      {issue?, milestone} -> [{key, {issue?, at}}, {{:milestone, key}, {milestone, at}}]
      :failed -> failed(kept_keys(key), reads, at)
    end
  end

  defp read_job({:branches, repo, names}, reads, at), do: closing(repo, names, reads, at)
  defp read_job({:counts, repo, numbers}, reads, at), do: counts(repo, numbers, reads, at)

  # Every answer a call gives, the milestone beside each read included.
  defp kept_keys({:counts, repo, numbers}), do: Enum.map(numbers, &{:counts, repo, &1})
  defp kept_keys(job), do: for(key <- job_keys(job), k <- [key, {:milestone, key}], do: k)

  # What a call that failed keeps: the last answer, standing until the
  # usual two minutes have passed.
  defp failed(keys, reads, at), do: for(key <- keys, do: {key, {kept(key, reads), at}})

  defp kept({:branch, _, _} = key, reads), do: found(key, reads[key])
  defp kept(key, reads), do: last_value(reads[key])

  # Whether the number is an issue in the repository: GitHub's issues call
  # also answers for a pull request, which carries "pull_request".
  # Not an issue here, too: one GitHub has deleted (410) or no such number
  # (404), and one moved to another repository, which gh follows to its
  # new number. With it, `{issue?, milestone}`: the number of the
  # milestone it is in, or nil. `:failed` when GitHub could not say.
  defp issue?(repo, n) do
    case Cmd.run("gh", ["api", "repos/#{repo}/issues/#{n}"], timeout: @read_ms) do
      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{"number" => ^n, "pull_request" => _}} -> {false, nil}
          {:ok, %{"number" => ^n} = issue} -> {true, milestone(issue["milestone"])}
          {:ok, %{"number" => _moved}} -> {false, nil}
          _ -> :failed
        end

      {:error, reason} ->
        if reason =~ ~r/HTTP 4(04|10)\b/, do: {false, nil}, else: :failed
    end
  end

  # The milestone's number, from an issue as GitHub's REST or GraphQL
  # answer gives it. Its counts there are not used: REST's take in the
  # milestone's pull requests.
  defp milestone(%{"number" => n}) when is_integer(n) and n > 0, do: n
  defp milestone(_), do: nil

  # Reads, oldest first, the counts of each milestone with no fresh read,
  # one call for each repository's milestones together, within what is
  # left of the check's calls.
  defp read_counts(keys, reads, at, calls) do
    jobs =
      keys
      |> Enum.reject(&fresh?(reads[&1], at))
      |> Enum.group_by(fn {:counts, repo, _} -> repo end, fn {:counts, _, n} -> n end)
      |> Enum.map(fn {repo, numbers} -> {:counts, repo, numbers} end)
      |> Enum.sort_by(fn job ->
        job |> kept_keys() |> Enum.map(&read_at(&1, reads)) |> Enum.min()
      end)
      |> Enum.take(max(calls, 0))

    if jobs == [], do: reads, else: Map.merge(reads, read_all(jobs, reads, at))
  end

  # Each milestone's own counts of its issues, done and in all, and its
  # title, which goes only to MilestoneTitles: [{{:counts, repo, n},
  # {%{done, total, rev} or nil, at}}]. GitHub's totals only, never a list
  # of issues. One query for the repository, each milestone a variable.
  defp counts(repo, numbers, reads, at) do
    numbers = Enum.with_index(numbers)
    [owner, name] = String.split(repo, "/", parts: 2)

    query = """
    query($owner: String!, $name: String!#{Enum.map_join(numbers, fn {_, i} -> ", $m#{i}: Int!" end)}) {
      repository(owner: $owner, name: $name) {
        #{Enum.map_join(numbers, "\n", fn {_, i} -> "m#{i}: milestone(number: $m#{i}) { title closed: issues(states: CLOSED) { totalCount } all: issues { totalCount } }" end)}
      }
    }
    """

    vars =
      ["-f", "owner=" <> owner, "-f", "name=" <> name] ++
        Enum.flat_map(numbers, fn {n, i} -> ["-F", "m#{i}=#{n}"] end)

    with {:ok, text} <-
           Cmd.run("gh", ["api", "graphql", "-f", "query=" <> query | vars], timeout: @read_ms),
         {:ok, %{"data" => %{"repository" => %{} = got}}} <- Jason.decode(text) do
      for {n, i} <- numbers, do: {{:counts, repo, n}, {issue_counts(repo, n, got["m#{i}"]), at}}
    else
      _ -> failed(kept_keys({:counts, repo, Enum.map(numbers, &elem(&1, 0))}), reads, at)
    end
  end

  defp issue_counts(repo, n, %{
         "title" => title,
         "closed" => %{"totalCount" => done},
         "all" => %{"totalCount" => total}
       })
       when is_binary(title) and is_integer(done) and is_integer(total) and done >= 0 and
              total >= done,
       do: %{done: done, total: total, rev: MilestoneTitles.put(repo, n, title)}

  # No such milestone now, or an answer not of that shape.
  defp issue_counts(_repo, _n, _), do: nil

  # The last answer, or nil (unknown) when there was none.
  defp last_value({value, _}), do: value
  defp last_value(_), do: nil

  # The first issue in the same repository that an open pull request from
  # each branch closes, and the number of its milestone: [{key, {number or
  # nil, at}}] and the same for {:milestone, key}. One query for the
  # repository, each branch a variable.
  defp closing(repo, names, reads, at) do
    names = Enum.with_index(names)
    [owner, name] = String.split(repo, "/", parts: 2)

    query = """
    query($owner: String!, $name: String!#{Enum.map_join(names, fn {_, i} -> ", $b#{i}: String!" end)}) {
      repository(owner: $owner, name: $name) {
        #{Enum.map_join(names, "\n", fn {_, i} -> "b#{i}: pullRequests(headRefName: $b#{i}, states: OPEN, first: 5) { nodes { headRepository { nameWithOwner } closingIssuesReferences(first: 5) { nodes { number repository { nameWithOwner } milestone { number } } } } }" end)}
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

      if answer do
        {value, milestone} = first_closed(answer["b#{i}"], repo) || {nil, nil}
        [{key, {value, at}}, {{:milestone, key}, {milestone, at}}]
      else
        failed(kept_keys(key), reads, at)
      end
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
            if same_repo?(name, repo), do: {n, milestone(issue["milestone"])}

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
