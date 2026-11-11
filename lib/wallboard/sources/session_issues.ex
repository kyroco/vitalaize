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

  Linear issues count the same way once a Linear API key is set
  (`Wallboard.Linear`): a prompt that names one, as `VIT-41` or a link to
  it, and else the issue Linear ties to the session's branch, asked after
  the branch's pull request on GitHub. Its card shows `VIT-41`. A word
  written like one whose letters are no team's in the workspace (`UTF-8`)
  is never asked about. The line above the cards then shows the milestone
  the issue is in, or its project when it is in no milestone, counted
  from each of its issues' kind of status: done are those Linear calls
  completed, and canceled ones are left out. Linear's calls count toward
  the same few a check may make.

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
  [%{repo, number, done, total, rev, sessions}]}`. A session on a Linear
  issue is `%{linear: "VIT-41"}`, and a Linear milestone or project has
  `source: :linear`, its `kind`, and Linear's id as its `number`. Sessions are keyed by
  each card's own `key`, which a streamed card's machine is part of, so
  two machines sending the same session id never share an issue; a
  milestone lists the card keys on it. Numbers and names only, so nothing
  from an issue or a prompt reaches the board or a log. A milestone's
  title is GitHub text: it goes only to `Wallboard.MilestoneTitles`, and
  the facts carry its revision there, so a renamed milestone still counts
  as a change.
  """

  alias Wallboard.{Cmd, GitRemote, IssueRef, Linear, MilestoneTitles, Poller}

  # How long a read stands before it is asked again.
  @fresh_s 120

  # How long one call to GitHub may take.
  @read_ms 20_000

  # At most this many calls to GitHub in one check, four at a time. With
  # each call allowed @read_ms, a check ends inside the poller's two
  # minutes even when GitHub is slow, so what it read is kept. What is left
  # waits for the next check, oldest read first.
  @per_check 8

  # How long Linear's list of teams stands, and how soon it is asked again
  # after a read of it failed.
  @teams_fresh_s 600
  @teams_retry_s 120

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
  # `teams` is the Linear workspace's teams, or nil when Linear is not
  # set up or its teams are not known yet: then nothing is asked of it.
  defp keys(%{issue_refs: :waiting}, _teams), do: []

  defp keys(s, teams) do
    named =
      for %{number: n} = ref <- List.wrap(s[:issue_refs]),
          is_integer(n),
          n > 0,
          do:
            if(IssueRef.linear?(ref),
              do: {:linear, ref.team, n},
              else: {:issue, ref[:repo] || s[:repo], n}
            )

    branch =
      if is_binary(s[:branch]),
        do: [{:branch, s[:repo], s.branch}, {:linear_branch, s.branch}],
        else: []

    (named ++ branch)
    |> Enum.filter(fn
      {:linear, team, _} -> teams != nil and MapSet.member?(teams, team)
      {:linear_branch, name} -> teams != nil and linear_branch?(name)
      key -> repo?(elem(key, 1))
    end)
    |> first_linear(3)
  end

  # A session's prompts may hold many words written like a Linear id. Of
  # those a team here could own, only the first few are asked about.
  defp first_linear(keys, most) do
    keys
    |> Enum.map_reduce(0, fn
      {:linear, _, _} = key, n -> {if(n < most, do: key), n + 1}
      key, n -> {key, n}
    end)
    |> elem(0)
    |> Enum.reject(&is_nil/1)
  end

  # A branch Linear could tie to an issue: not the main one, and short
  # enough to be a branch's name.
  defp linear_branch?(name),
    do: name not in ["main", "master", "HEAD"] and byte_size(name) in 1..200

  # Whether the key is an issue a prompt named, not a branch's.
  defp named?({:issue, _, _}), do: true
  defp named?({:linear, _, _}), do: true
  defp named?(_), do: false

  # Linear's teams, read at most every ten minutes: {teams or nil, what to
  # keep}. A read that fails keeps the teams known before and is tried
  # again in two minutes.
  defp linear_teams(kept, at) do
    cond do
      not Linear.on?() ->
        {nil, nil}

      match?({_, read_at} when at - read_at < @teams_fresh_s, kept) ->
        {elem(kept, 0), kept}

      true ->
        case Linear.teams() do
          {:ok, teams} ->
            {teams, {teams, at}}

          :failed ->
            before = last_value(kept)
            {before, {before, at - @teams_fresh_s + @teams_retry_s}}
        end
    end
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
    {teams, teams_read} = linear_teams(memory[:linear_teams], at)

    wants =
      for s <- sessions,
          is_binary(s[:key]),
          keys = keys(s, teams),
          keys != [],
          do: {s, keys}

    # A session has at most eight keys (three named on GitHub, three on
    # Linear, and its branch on each), so eight rounds settle every one.
    # A collector may send more named ones: keys/2 drops the rest.
    {reads, calls} = settle(wants, reads, at, 8)

    picked = for {s, keys} <- wants, key = pick(keys, reads), do: {s, key}

    # Each session's milestone, as {counts key, {card key, repository as
    # written}}. The key ignores capitals, as GitHub's names do; the line
    # shows the name as it was written.
    on =
      for {s, key} <- picked,
          {place, _} <- [reads[{:milestone, key}]],
          counts = counts_key(key, place),
          do: {counts, {s.key, elem(key, 1)}}

    counts = on |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    reads = read_counts(counts, reads, at, calls)

    sessions =
      for {s, key} <- picked, into: %{}, do: {s.key, session_fact(key, found(key, reads[key]))}

    keys = Enum.flat_map(wants, &elem(&1, 1))

    kept = %{
      reads: Map.take(reads, keys),
      milestones: for(key <- keys, read = reads[{:milestone, key}], into: %{}, do: {key, read}),
      counts: Map.take(reads, counts),
      linear_teams: teams_read
    }

    {%{sessions: sessions, milestones: milestones(on, reads)}, kept}
  end

  # One for each milestone a session's issue is in whose counts are known,
  # with the cards on it.
  # GitHub's come first, by repository and number, then Linear's.
  defp milestones(on, reads) do
    on
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {key, on} ->
      {order, named} =
        case key do
          {:counts, repo, n} ->
            {{0, repo, n}, %{repo: on |> Enum.map(&elem(&1, 1)) |> Enum.min(), number: n}}

          {:linear_counts, kind, id} ->
            {{1, kind, id}, %{repo: "Linear", number: id, source: :linear, kind: kind}}
        end

      case reads[key] do
        {%{} = c, _} ->
          [
            {order,
             Map.merge(named, %{
               done: c.done,
               total: c.total,
               rev: c.rev,
               sessions: on |> Enum.map(&elem(&1, 0)) |> Enum.sort()
             })}
          ]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # Where a milestone's counts are kept, from the key that gave the issue
  # and what its read says the issue is in. Nil when it is in none.
  defp counts_key({kind, repo, _}, n) when kind in [:issue, :branch] and is_integer(n),
    do: {:counts, String.downcase(repo), n}

  defp counts_key({:linear_branch, _}, {in_kind, id}) when is_binary(id),
    do: {:linear_counts, in_kind, id}

  defp counts_key({:linear, _, _}, {in_kind, id}) when is_binary(id),
    do: {:linear_counts, in_kind, id}

  defp counts_key(_key, _place), do: nil

  # What the board is told a session is on.
  defp session_fact({kind, repo, _}, n) when kind in [:issue, :branch],
    do: %{repo: repo, number: n}

  defp session_fact(_linear, id), do: %{linear: id}

  # The key that gives a session's issue. A named issue that is not known
  # yet, because its read failed or has not been made, stops the walk, so
  # an earlier read of the branch never stands in for it.
  defp pick([], _reads), do: nil

  defp pick([key | rest], reads) do
    cond do
      found(key, reads[key]) -> key
      named?(key) and not match?({false, _}, reads[key]) -> nil
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
  # branches together. One call to Linear for every issue named there, and
  # one for every branch.
  defp jobs(keys) do
    by = Enum.group_by(keys, &elem(&1, 0))

    linear_issues =
      for {:linear, team, n} <- by[:linear] || [], do: {team, n}

    linear_branches = for {:linear_branch, name} <- by[:linear_branch] || [], do: name

    (by[:issue] || []) ++
      ((by[:branch] || [])
       |> Enum.group_by(fn {:branch, repo, _} -> repo end, fn {:branch, _, b} -> b end)
       |> Enum.map(fn {repo, names} -> {:branches, repo, names} end)) ++
      if(linear_issues == [], do: [], else: [{:linear_issues, linear_issues}]) ++
      if(linear_branches == [], do: [], else: [{:linear_branches, linear_branches}])
  end

  # When a call's answer was last read, or 0 when never: for a call that
  # reads several, the oldest of them.
  defp read_at(job, reads) do
    job
    |> job_keys()
    |> Enum.map(fn key ->
      case reads[key] do
        {_, at} -> at
        _ -> 0
      end
    end)
    |> Enum.min()
  end

  defp job_keys({:branches, repo, names}), do: Enum.map(names, &{:branch, repo, &1})
  defp job_keys({:linear_issues, pairs}), do: for({team, n} <- pairs, do: {:linear, team, n})
  defp job_keys({:linear_branches, names}), do: Enum.map(names, &{:linear_branch, &1})
  defp job_keys(key), do: [key]

  defp next_stale([], _reads, _at), do: nil

  # An issue read that failed with nothing read before is unknown, not "no
  # issue": the session waits for it rather than taking its branch's.
  defp next_stale([key | rest], reads, at) do
    cond do
      not fresh?(reads[key], at) -> key
      found(key, reads[key]) -> nil
      named?(key) and match?({nil, _}, reads[key]) -> nil
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
  defp found({:linear, _team, _}, {id, _}) when is_binary(id), do: id
  defp found({:linear_branch, _}, {id, _}) when is_binary(id), do: id
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

  defp read_job({:linear_issues, pairs} = job, reads, at),
    do: linear_read(job, Linear.issues(pairs), pairs, reads, at)

  defp read_job({:linear_branches, names} = job, reads, at),
    do: linear_read(job, Linear.branches(names), names, reads, at)

  # A Linear milestone's or project's counts, and its name, which goes
  # only to MilestoneTitles, with the name of a milestone's project.
  defp read_job({:linear_counts, kind, id} = key, reads, at) do
    case Linear.counts(kind, id) do
      {:ok, %{done: done, total: total, title: title, project: project}} ->
        rev =
          :erlang.phash2({
            MilestoneTitles.put("linear", id, title),
            is_binary(project) && MilestoneTitles.put("linear project", id, project)
          })

        [{key, {%{done: done, total: total, rev: rev}, at}}]

      {:ok, nil} ->
        [{key, {nil, at}}]

      :failed ->
        failed([key], reads, at)
    end
  end

  # What one call to Linear said of each issue or branch asked about, in
  # the order asked: its id, and beside it the milestone or project.
  defp linear_read(job, {:ok, got}, asked, _reads, at) do
    for {key, name} <- Enum.zip(job_keys(job), asked),
        {id, place} = Map.fetch!(got, name),
        read <- [{key, {id, at}}, {{:milestone, key}, {place, at}}],
        do: read
  end

  defp linear_read(job, :failed, _asked, reads, at), do: failed(kept_keys(job), reads, at)

  # Every answer a call gives, the milestone beside each read included.
  defp kept_keys({:counts, repo, numbers}), do: Enum.map(numbers, &{:counts, repo, &1})
  defp kept_keys({:linear_counts, _, _} = key), do: [key]
  defp kept_keys(job), do: for(key <- job_keys(job), k <- [key, {:milestone, key}], do: k)

  # What a call that failed keeps: the last answer, standing until the
  # usual two minutes have passed.
  defp failed(keys, reads, at), do: for(key <- keys, do: {key, {kept(key, reads), at}})

  defp kept({:branch, _, _} = key, reads), do: found(key, reads[key])
  defp kept({:linear_branch, _} = key, reads), do: found(key, reads[key])
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
    {github, linear} =
      keys
      |> Enum.reject(&fresh?(reads[&1], at))
      |> Enum.split_with(&match?({:counts, _, _}, &1))

    jobs =
      github
      |> Enum.group_by(fn {:counts, repo, _} -> repo end, fn {:counts, _, n} -> n end)
      |> Enum.map(fn {repo, numbers} -> {:counts, repo, numbers} end)
      |> Enum.concat(linear)
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
