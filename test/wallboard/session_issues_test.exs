defmodule Wallboard.SessionIssuesTest do
  # Which issue a live session is on (issue #143). A stand-in gh on the
  # PATH answers like GitHub and writes down every call. One at a time: the
  # PATH is this whole test run's.
  use ExUnit.Case, async: false

  alias Wallboard.Fixtures
  alias Wallboard.Sources.SessionIssues

  @now ~U[2026-10-20 15:00:00Z]

  setup do
    dir = Fixtures.tmp_path("wallboard-session-issues")
    File.mkdir_p!(dir)

    # acme/shop has issues 1418 and 1419 and pull request 1420; anything
    # else is not found. An open pull request from feature/checkout closes
    # issue 77, one from feature/elsewhere closes an issue in another
    # repository, and one from a fork's feature/forked closes issue 77.
    File.write!(Path.join(dir, "gh"), """
    #!/bin/sh
    # One line for each call, the query's line breaks and all, written at
    # once: calls run four at a time.
    line=$(printf '%s' "$*" | tr '\\n' ' ')
    echo "$line" >> "$WALLBOARD_TEST_GH/calls"
    if [ "$2" = "graphql" ]; then
      # A list is any milestones call, or issues asked for one by one. A
      # milestone's own counts (issues { totalCount }) are not a list.
      if printf '%s' "$*" | grep -Eq 'milestones\\(|issues(\\([^)]*\\))? *\\{ *(nodes|edges)'; then
        echo "$*" >> "$WALLBOARD_TEST_GH/listed"
      fi
      if [ -f "$WALLBOARD_TEST_GH/down" ] || [ -f "$WALLBOARD_TEST_GH/graphql_down" ]; then
        echo "gh: Something went wrong (HTTP 502)" >&2; exit 1
      fi
      out=""
      prev=""
      for a in "$@"; do
        if [ "$prev" = "-f" ]; then
          case "$a" in
            b[0-9]*=*)
              key="${a%%=*}"; branch="${a#*=}"
              head="acme/shop"
              case "$branch" in
                feature/checkout) refs='{"number": 77, "repository": {"nameWithOwner": "acme/shop"}}' ;;
                feature/elsewhere) refs='{"number": 5, "repository": {"nameWithOwner": "acme/other"}}' ;;
                feature/forked) head="someone/shop"; refs='{"number": 77, "repository": {"nameWithOwner": "acme/shop"}}' ;;
                feature/milestoned) refs='{"number": 1432, "repository": {"nameWithOwner": "acme/shop"}, "milestone": {"number": 8, "title": "PLANTED milestone eight"}}' ;;
                *) refs="" ;;
              esac
              if [ -n "$refs" ]; then
                prs='[{"headRepository": {"nameWithOwner": "'"$head"'"}, "closingIssuesReferences": {"nodes": ['"$refs"']}}]'
              else
                prs='[]'
              fi
              out="$out${out:+, }\\"$key\\": {\\"nodes\\": $prs}" ;;
          esac
        fi
        # A milestone's own counts, issues only. Milestone 7 has 8 issues,
        # 3 closed, or what the file "closed7" says, so a test can close
        # one, and its title is what "title7" says, so a test can rename it.
        if [ "$prev" = "-F" ]; then
          case "$a" in
            m[0-9]*=7)
              key="${a%%=*}"
              closed=$(cat "$WALLBOARD_TEST_GH/closed7" 2>/dev/null || echo 3)
              title=$(cat "$WALLBOARD_TEST_GH/title7" 2>/dev/null || echo "PLANTED milestone seven")
              out="$out${out:+, }\\"$key\\": {\\"title\\": \\"$title\\", \\"closed\\": {\\"totalCount\\": $closed}, \\"all\\": {\\"totalCount\\": 8}}" ;;
            m[0-9]*=8)
              key="${a%%=*}"
              out="$out${out:+, }\\"$key\\": {\\"title\\": \\"PLANTED milestone eight\\", \\"closed\\": {\\"totalCount\\": 1}, \\"all\\": {\\"totalCount\\": 2}}" ;;
            m[0-9]*=*)
              key="${a%%=*}"
              out="$out${out:+, }\\"$key\\": null" ;;
          esac
        fi
        prev="$a"
      done
      echo "{\\"data\\": {\\"repository\\": {$out}}}"
      exit 0
    fi
    if [ -f "$WALLBOARD_TEST_GH/down" ] || [ -f "$WALLBOARD_TEST_GH/rest_down" ]; then
      echo "gh: Something went wrong (HTTP 502)" >&2; exit 1
    fi
    case "$2" in
      repos/acme/shop/issues/1418) echo '{"number": 1418, "title": "PLANTED issue text"}' ;;
      repos/acme/shop/issues/1419) echo '{"number": 1419, "title": "PLANTED issue text"}' ;;
      repos/acme/shop/issues/1420) echo '{"number": 1420, "pull_request": {"url": "x"}}' ;;
      repos/acme/shop/issues/1430|repos/acme/shop/issues/1431)
        # REST's counts take in the milestone's pull requests too, so they
        # are not the milestone's issue counts.
        n="${2##*/}"
        echo '{"number": '"$n"', "title": "PLANTED issue text", "milestone": {"number": 7, "title": "PLANTED milestone seven", "open_issues": 50, "closed_issues": 40}}' ;;
      repos/acme/shop/issues/1432) echo '{"number": 1432, "title": "PLANTED issue text", "milestone": {"number": 8, "title": "PLANTED milestone eight", "open_issues": 50, "closed_issues": 40}}' ;;
      repos/acme/other/issues/2001) echo '{"number": 2001, "title": "PLANTED issue text", "milestone": {"number": 7, "title": "PLANTED other seven", "open_issues": 1, "closed_issues": 0}}' ;;
      repos/acme/shop/issues/1500) echo "gh: Issue was deleted (HTTP 410)" >&2; exit 1 ;;
      repos/acme/shop/issues/1501) echo '{"number": 9, "title": "PLANTED moved"}' ;;
      *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac
    """)

    File.chmod!(Path.join(dir, "gh"), 0o755)

    old = {System.get_env("PATH"), System.get_env("WALLBOARD_TEST_GH")}
    System.put_env("PATH", dir <> ":" <> elem(old, 0))
    System.put_env("WALLBOARD_TEST_GH", dir)

    on_exit(fn ->
      System.put_env("PATH", elem(old, 0))

      if elem(old, 1),
        do: System.put_env("WALLBOARD_TEST_GH", elem(old, 1)),
        else: System.delete_env("WALLBOARD_TEST_GH")

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp calls(c) do
    case File.read(Path.join(c.dir, "calls")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  defp session(id, fields),
    do: Map.merge(%{key: id, session_id: id, repo: "acme/shop"}, Map.new(fields))

  defp later(s), do: DateTime.add(@now, s)

  # A session whose prompts named #n in its own repository.
  defp named(id, n, fields \\ []),
    do: session(id, [issue_refs: [%{repo: nil, number: n}]] ++ fields)

  describe "match/3" do
    test "the issue a prompt named, when it is an issue here, numbers only", c do
      {facts, _} = SessionIssues.match([named("s1", 1418)], %{}, @now)
      assert facts.sessions == %{"s1" => %{repo: "acme/shop", number: 1418}}
      assert calls(c) == ["api repos/acme/shop/issues/1418"]
      refute inspect(facts) =~ "PLANTED"
    end

    test "a linked issue is checked in the link's repository, whatever the session's" do
      ref = %{repo: "acme/shop", number: 1418}

      sessions = [
        session("a", repo: "acme/other", issue_refs: [ref]),
        %{key: "b", session_id: "b", issue_refs: [ref]}
      ]

      {facts, _} = SessionIssues.match(sessions, %{}, @now)

      assert facts.sessions == %{
               "a" => %{repo: "acme/shop", number: 1418},
               "b" => %{repo: "acme/shop", number: 1418}
             }
    end

    test "a named number that is a pull request, or no issue at all, gives no issue" do
      sessions = [named("pr", 1420), named("gone", 5555)]
      assert {%{sessions: none}, _} = SessionIssues.match(sessions, %{}, @now)
      assert none == %{}
    end

    test "a named number that is not an issue falls back to the branch's closing pull request" do
      s = named("s1", 5555, branch: "feature/checkout")
      {facts, _} = SessionIssues.match([s], %{}, @now)
      assert facts.sessions == %{"s1" => %{repo: "acme/shop", number: 77}}
    end

    test "a named issue never asks about the branch", c do
      s = named("s1", 1418, branch: "feature/checkout")
      {facts, _} = SessionIssues.match([s], %{}, @now)
      assert facts.sessions == %{"s1" => %{repo: "acme/shop", number: 1418}}
      assert calls(c) == ["api repos/acme/shop/issues/1418"]
    end

    test "a name or a branch with a number in it names nothing", c do
      sessions = [
        session("a", name: "1418-issue", branch: "robert/issue-1418-login"),
        session("b", name: "#1418")
      ]

      {facts, _} = SessionIssues.match(sessions, %{}, @now)
      assert facts.sessions == %{}
      refute Enum.any?(calls(c), &(&1 =~ "issues/1418"))
    end

    test "with no issue named, an open pull request from the branch that closes an issue gives it",
         c do
      sessions = [
        session("a", name: "checkout", branch: "feature/checkout"),
        session("b", name: "nothing", branch: "feature/none"),
        session("c", name: "away", branch: "feature/elsewhere")
      ]

      {facts, _} = SessionIssues.match(sessions, %{}, @now)
      assert facts.sessions == %{"a" => %{repo: "acme/shop", number: 77}}

      # One query for the repository, each branch sent as text.
      assert [query] = calls(c)
      assert query =~ "api graphql"
      assert query =~ "-f b0=feature/checkout"
      refute query =~ "-F"
    end

    test "a pull request from a fork's branch of the same name gives no issue" do
      # Its branch is the fork's, not the session's.
      s = session("a", name: "forked", branch: "feature/forked")
      assert {%{sessions: none}, _} = SessionIssues.match([s], %{}, @now)
      assert none == %{}
    end

    test "a repository written in other capitals than GitHub's still finds the closing pull request" do
      s = session("a", name: "checkout", branch: "feature/checkout", repo: "Acme/Shop")
      {facts, _} = SessionIssues.match([s], %{}, @now)
      assert facts.sessions == %{"a" => %{repo: "Acme/Shop", number: 77}}
    end

    test "a repository name that is not owner/name, such as dot parts or a line break, asks nothing",
         c do
      sessions = [
        named("a", 1418, repo: "../.."),
        named("b", 1418, repo: "acme/.."),
        named("c", 1418, repo: "acme/shop\n"),
        session("d", issue_refs: [%{repo: "../..", number: 1418}])
      ]

      assert {%{sessions: none}, _} = SessionIssues.match(sessions, %{}, @now)
      assert none == %{}
      assert calls(c) == []
    end

    test "a session with no repository, or no issue named and no branch, asks nothing", c do
      sessions = [
        %{key: "x", session_id: "x", issue_refs: [%{repo: nil, number: 1418}]},
        named("y", 1418, repo: "not a repo"),
        session("z", name: "checkout")
      ]

      assert {%{sessions: none}, _} = SessionIssues.match(sessions, %{}, @now)
      assert none == %{}
      assert calls(c) == []
    end

    test "an issue or a branch is read at most every two minutes", c do
      sessions = [named("a", 1418), session("b", name: "checkout", branch: "feature/checkout")]

      {first, memory} = SessionIssues.match(sessions, %{}, @now)
      assert length(calls(c)) == 2

      {again, memory} = SessionIssues.match(sessions, memory, later(60))
      assert again == first
      assert length(calls(c)) == 2

      {third, _} = SessionIssues.match(sessions, memory, later(130))
      assert third == first
      assert length(calls(c)) == 4
    end

    test "one check asks GitHub at most eight times, so a slow GitHub cannot run it past its limit",
         c do
      sessions = for n <- 2001..2012, do: named("s#{n}", n)

      {_, memory} = SessionIssues.match(sessions, %{}, @now)
      assert length(calls(c)) == 8

      # The next check asks about the rest, and then nothing is left.
      {_, memory} = SessionIssues.match(sessions, memory, later(5))
      assert length(calls(c)) == 12
      assert map_size(memory.reads) == 12

      {_, _} = SessionIssues.match(sessions, memory, later(10))
      assert length(calls(c)) == 12
    end

    test "when more calls are due than one check makes, the ones read longest ago go first", c do
      sessions = for n <- 2001..2012, do: named("s#{n}", n)
      at = DateTime.to_unix(@now)

      # Every read is stale; 2012 was read longest ago.
      reads =
        Map.new(2001..2012, fn n ->
          {{:issue, "acme/shop", n}, {false, at - 200 - (n - 2001) * 10}}
        end)

      SessionIssues.match(sessions, %{reads: reads}, @now)

      asked =
        for line <- calls(c),
            [_, n] <- [Regex.run(~r{issues/(\d+)}, line)],
            do: String.to_integer(n)

      assert Enum.sort(asked) == Enum.to_list(2005..2012)
    end

    test "a first read of a named issue that fails leaves the session waiting, not on its branch's issue",
         c do
      s = named("s1", 1418, branch: "feature/checkout")
      File.write!(Path.join(c.dir, "rest_down"), "")

      {facts, memory} = SessionIssues.match([s], %{}, @now)
      assert facts.sessions == %{}
      refute Enum.any?(calls(c), &(&1 =~ "graphql"))

      # Two minutes on, GitHub answers again.
      File.rm!(Path.join(c.dir, "rest_down"))
      {facts, _} = SessionIssues.match([s], memory, later(130))
      assert facts.sessions == %{"s1" => %{repo: "acme/shop", number: 1418}}
    end

    test "this machine's sessions are read before streamed ones when more calls are due than one check makes",
         c do
      at = DateTime.to_unix(@now)
      mine = named("mine", 1418, local?: true)
      streamed = for n <- 2001..2010, do: named("s#{n}", n)
      reads = %{{:issue, "acme/shop", 1418} => {true, at - 130}}

      SessionIssues.match(streamed ++ [mine], %{reads: reads}, @now)
      assert "api repos/acme/shop/issues/1418" in calls(c)
    end

    test "a branch read before the named issue was known never stands in for it", c do
      at = DateTime.to_unix(@now)
      s = named("s1", 1418, branch: "feature/checkout")

      # The branch was read while nothing was named yet (as after a restart).
      reads = %{{:branch, "acme/shop", "feature/checkout"} => {77, at - 30}}
      File.write!(Path.join(c.dir, "rest_down"), "")

      {facts, memory} = SessionIssues.match([s], %{reads: reads}, @now)
      assert facts.sessions == %{}

      {facts, _} = SessionIssues.match([s], memory, later(400))
      assert facts.sessions == %{}
    end

    test "a deleted issue, or one moved to another repository, is not an issue here", c do
      # 410 for a deleted issue; a moved one answers with its new number.
      for n <- [1500, 1501] do
        s = named("s#{n}", n, branch: "feature/checkout")
        {facts, _} = SessionIssues.match([s], %{}, @now)
        assert facts.sessions == %{"s#{n}" => %{repo: "acme/shop", number: 77}}, "##{n}"
      end

      assert length(calls(c)) == 4
    end

    test "the first of the named numbers that is an issue here wins", c do
      refs = [
        %{repo: nil, number: 333_333},
        %{repo: nil, number: 1418},
        %{repo: nil, number: 1419}
      ]

      s = session("s1", issue_refs: refs)

      {facts, _} = SessionIssues.match([s], %{}, @now)
      assert facts.sessions == %{"s1" => %{repo: "acme/shop", number: 1418}}
      refute Enum.any?(calls(c), &(&1 =~ "issues/1419"))
    end

    test "a read that fails keeps what was read before", c do
      sessions = [named("a", 1418), session("b", name: "checkout", branch: "feature/checkout")]

      {first, memory} = SessionIssues.match(sessions, %{}, @now)
      File.write!(Path.join(c.dir, "down"), "")

      {down, _} = SessionIssues.match(sessions, memory, later(130))
      assert down == first

      # Nothing read before, and GitHub down: no issue, and nothing breaks.
      assert {%{sessions: none}, _} = SessionIssues.match(sessions, %{}, later(130))
      assert none == %{}
    end

    test "what is remembered is only what live sessions still point at" do
      {_, memory} = SessionIssues.match([named("a", 1418)], %{}, @now)
      assert Map.keys(memory.reads) == [{:issue, "acme/shop", 1418}]

      {_, memory} = SessionIssues.match([], memory, later(10))
      assert memory.reads == %{}
    end

    test "no repository's whole list of issues or milestones is ever asked for", c do
      sessions = [
        named("a", 1418),
        named("b", 1420),
        session("c", name: "checkout", branch: "feature/checkout"),
        session("d", name: "plain", branch: "feature/none")
      ]

      SessionIssues.match(sessions, %{}, @now)
      listed = Path.join(c.dir, "listed")
      if File.exists?(listed), do: flunk("asked for a list: " <> File.read!(listed))
      refute Enum.any?(calls(c), &(&1 =~ ~r{/issues(\?|$)|/milestones}))
    end
  end

  describe "poll/4" do
    # Stands in for a poller this source reads: Claude, Codex or usage.
    # Its meta can carry the error a failed check left.
    defmodule FakePoller do
      use GenServer

      def child_spec({name, facts}), do: child_spec({name, facts, %{}})

      def child_spec({name, facts, meta}),
        do: %{id: name, start: {__MODULE__, :start_link, [{name, facts, meta}]}}

      def start_link({name, facts, meta}),
        do: GenServer.start_link(__MODULE__, {facts, meta}, name: name)

      def init(state), do: {:ok, state}

      def handle_call(:snapshot, _from, {facts, meta} = state),
        do: {:reply, %{facts: facts, meta: meta}, state}
    end

    # Stands in for the sessions collectors stream from other machines.
    defmodule FakeStream do
      use GenServer

      def start_link(cards),
        do: GenServer.start_link(__MODULE__, cards, name: Wallboard.Link.Sessions)

      def init(cards), do: {:ok, cards}
      def handle_call(:cards, _from, cards), do: {:reply, cards, cards}
    end

    # A checkout of acme/shop on the given branch.
    defp checkout(c, branch) do
      folder = Path.join(c.dir, "checkout")
      File.mkdir_p!(Path.join([folder, ".git"]))

      File.write!(Path.join([folder, ".git", "config"]), """
      [remote "origin"]
      \turl = git@github.com:acme/shop.git
      """)

      File.write!(Path.join([folder, ".git", "HEAD"]), "ref: refs/heads/#{branch}\n")
      folder
    end

    test "a Claude session on this machine takes its issue from what its prompts named, and its repository from its folder",
         c do
      folder = checkout(c, "robert/1418-login")

      start_supervised!(
        {FakePoller,
         {:claude, %{sessions: [%{key: "main:s1", session_id: "s1", name: "login", cwd: folder}]}}}
      )

      start_supervised!(
        {FakePoller, {:usage, %{sessions: %{"s1" => %{issues: [%{repo: nil, number: 1418}]}}}}}
      )

      assert {:ok, facts, memory} = SessionIssues.poll(nil, nil, nil, @now)
      assert facts.sessions == %{"main:s1" => %{repo: "acme/shop", number: 1418}}
      assert {:issue, "acme/shop", 1418} in Map.keys(memory.reads)
    end

    test "until the usage reader has read this machine's Claude sessions, they wait rather than take their branch's issue",
         c do
      folder = checkout(c, "feature/checkout")

      start_supervised!(
        {FakePoller,
         {:claude, %{sessions: [%{key: "main:s1", session_id: "s1", name: "x", cwd: folder}]}}}
      )

      # As after a restart: the usage reader is still on its first read.
      start_supervised!({FakePoller, {:usage, nil, %{error: nil, fetched_at: nil}}})
      assert {:ok, %{sessions: none}, _} = SessionIssues.poll(nil, nil, nil, @now)
      assert none == %{}
      assert calls(c) == []

      # Once it has, and their prompts named nothing, the branch counts.
      stop_supervised!(:usage)
      start_supervised!({FakePoller, {:usage, %{sessions: %{}}}})
      assert {:ok, facts, _} = SessionIssues.poll(nil, nil, nil, @now)
      assert facts.sessions == %{"main:s1" => %{repo: "acme/shop", number: 77}}
    end

    test "when the usage reader's first read fails, or it is not running, the branch's issue still shows",
         c do
      folder = checkout(c, "feature/checkout")

      start_supervised!(
        {FakePoller,
         {:claude, %{sessions: [%{key: "main:s1", session_id: "s1", name: "x", cwd: folder}]}}}
      )

      # Not running at all: nothing to wait for.
      assert {:ok, facts, _} = SessionIssues.poll(nil, nil, nil, @now)
      assert facts.sessions == %{"main:s1" => %{repo: "acme/shop", number: 77}}

      # Its first read ended in an error.
      start_supervised!(
        {FakePoller, {:usage, nil, %{error: "the check hit an error", fetched_at: nil}}}
      )

      assert {:ok, facts, _} = SessionIssues.poll(nil, nil, nil, later(130))
      assert facts.sessions == %{"main:s1" => %{repo: "acme/shop", number: 77}}
    end

    test "a Codex session on this machine takes its issue from its card", c do
      folder = checkout(c, "main")

      card = %{
        key: "codex:t1",
        session_id: "t1",
        name: "fix",
        cwd: folder,
        issue_refs: [%{repo: nil, number: 1419}]
      }

      start_supervised!({FakePoller, {:codex, %{sessions: [card]}}})

      assert {:ok, facts, _} = SessionIssues.poll(nil, nil, nil, @now)
      assert facts.sessions == %{"codex:t1" => %{repo: "acme/shop", number: 1419}}
    end

    test "a session both on this machine and in a stream takes its issue from this machine", c do
      folder = checkout(c, "main")

      start_supervised!(
        {FakePoller,
         {:claude, %{sessions: [%{key: "main:s1", session_id: "s1", name: "login", cwd: folder}]}}}
      )

      start_supervised!(
        {FakePoller, {:usage, %{sessions: %{"s1" => %{issues: [%{repo: nil, number: 1418}]}}}}}
      )

      # A collector streams the same session, and a session of its own.
      other = %{repo: nil, number: 1419}

      start_supervised!(
        {FakeStream,
         [
           %{
             key: "stream:papa:s1",
             session_id: "s1",
             name: "login",
             gh_repo: "acme/shop",
             issue_refs: [other]
           },
           %{
             key: "stream:papa:s2",
             session_id: "s2",
             name: "away",
             gh_repo: "acme/shop",
             issue_refs: [other]
           }
         ]}
      )

      assert {:ok, facts, _} = SessionIssues.poll(nil, nil, nil, @now)

      assert facts.sessions == %{
               "main:s1" => %{repo: "acme/shop", number: 1418},
               "stream:papa:s2" => %{repo: "acme/shop", number: 1419}
             }
    end

    test "two machines streaming the same session id each keep their own card's issue" do
      start_supervised!({FakePoller, {:usage, %{sessions: %{}}}})

      start_supervised!(
        {FakeStream,
         [
           %{
             key: "stream:papa:s1",
             session_id: "s1",
             gh_repo: "acme/shop",
             issue_refs: [%{repo: nil, number: 1418}]
           },
           %{
             key: "stream:mama:s1",
             session_id: "s1",
             gh_repo: "acme/shop",
             issue_refs: [%{repo: nil, number: 1419}]
           }
         ]}
      )

      assert {:ok, facts, _} = SessionIssues.poll(nil, nil, nil, @now)

      assert facts.sessions == %{
               "stream:papa:s1" => %{repo: "acme/shop", number: 1418},
               "stream:mama:s1" => %{repo: "acme/shop", number: 1419}
             }
    end

    test "with no pollers running it finds nothing and asks nothing", c do
      assert {:ok, %{sessions: none}, _} = SessionIssues.poll(nil, nil, %{}, @now)
      assert none == %{}
      assert calls(c) == []
    end
  end

  describe "milestones (issue #144)" do
    setup do
      unless Process.whereis(Wallboard.MilestoneTitles),
        do: start_supervised!(Wallboard.MilestoneTitles)

      :ok
    end

    # What a line shows, without its title's revision.
    defp shown(facts),
      do: Enum.map(facts.milestones, &Map.take(&1, [:repo, :number, :done, :total]))

    defp seven(done), do: %{repo: "acme/shop", number: 7, done: done, total: 8}

    defp counts_calls(c), do: Enum.filter(calls(c), &(&1 =~ "milestone(number:"))

    test "a session's issue in a milestone gives one line's numbers, its issues only", c do
      {facts, memory} = SessionIssues.match([named("s1", 1430)], %{}, @now)

      # GitHub's REST counts take in pull requests (40 of 90 here); the
      # line counts the milestone's issues: 3 of 8.
      assert shown(facts) == [seven(3)]
      assert [%{sessions: ["s1"]}] = facts.milestones

      # The issue's read, then one read of the milestone's own counts, which
      # asks for totals and never for a list.
      assert [issue, counts] = calls(c)
      assert issue == "api repos/acme/shop/issues/1430"
      assert counts =~ "totalCount"
      refute counts =~ "nodes"

      # The title is kept apart, never in the facts or the memory, not even
      # as a hash.
      assert Wallboard.MilestoneTitles.get("acme/shop", 7) == "PLANTED milestone seven"
      refute inspect(facts) =~ "PLANTED"
      refute inspect(memory) =~ "PLANTED"
      hash = :erlang.phash2("PLANTED milestone seven")
      refute inspect({facts, memory}, limit: :infinity) =~ Integer.to_string(hash)
    end

    test "sessions in two milestones give two lines; two in one milestone give one, with both" do
      {facts, _} = SessionIssues.match([named("a", 1430), named("b", 1432)], %{}, @now)
      assert Enum.map(shown(facts), &{&1.number, &1.done, &1.total}) == [{7, 3, 8}, {8, 1, 2}]

      {facts, _} = SessionIssues.match([named("a", 1430), named("b", 1431)], %{}, @now)
      assert shown(facts) == [seven(3)]
      assert [%{sessions: ["a", "b"]}] = facts.milestones
    end

    test "the same milestone number in two repositories is two lines" do
      other = session("o", issue_refs: [%{repo: "acme/other", number: 2001}])
      {facts, _} = SessionIssues.match([named("a", 1430), other], %{}, @now)

      assert Enum.map(shown(facts), &{&1.repo, &1.number}) == [
               {"acme/other", 7},
               {"acme/shop", 7}
             ]
    end

    test "an issue in no milestone, or no session on an issue, gives no line", c do
      {facts, _} = SessionIssues.match([named("a", 1418)], %{}, @now)
      assert facts.sessions != %{}
      assert facts.milestones == []
      assert counts_calls(c) == []

      {facts, _} = SessionIssues.match([session("b", branch: "feature/nothing")], %{}, @now)
      assert facts == %{sessions: %{}, milestones: []}
    end

    test "an issue that closes in a shown milestone counts within two minutes", c do
      {_, memory} = SessionIssues.match([named("a", 1430)], %{}, @now)
      File.write!(Path.join(c.dir, "closed7"), "4")

      # Still fresh: not asked again.
      {facts, memory} = SessionIssues.match([named("a", 1430)], memory, later(60))
      assert shown(facts) == [seven(3)]
      assert length(counts_calls(c)) == 1

      {facts, _} = SessionIssues.match([named("a", 1430)], memory, later(121))
      assert shown(facts) == [seven(4)]
    end

    test "one milestone's counts are read once, however many sessions are in it", c do
      sessions = [named("a", 1430), named("b", 1431)]
      {_, memory} = SessionIssues.match(sessions, %{}, @now)
      {_, _} = SessionIssues.match(sessions, memory, later(121))
      assert length(counts_calls(c)) == 2
    end

    test "a branch's closing pull request gives its issue's milestone" do
      s = session("a", branch: "feature/milestoned")
      {facts, memory} = SessionIssues.match([s], %{}, @now)

      assert [%{number: 8, done: 1, total: 2}] = facts.milestones
      assert Wallboard.MilestoneTitles.get("acme/shop", 8) == "PLANTED milestone eight"
      refute inspect(facts) =~ "PLANTED"
      refute inspect(memory) =~ "PLANTED"
    end

    test "a read that fails keeps the milestone's last counts", c do
      sessions = [named("a", 1430), session("b", branch: "feature/milestoned")]
      {first, memory} = SessionIssues.match(sessions, %{}, @now)
      assert length(first.milestones) == 2

      File.write!(Path.join(c.dir, "down"), "")
      {down, _} = SessionIssues.match(sessions, memory, later(130))
      assert down.milestones == first.milestones
    end

    test "a failed read of an issue never rolls its milestone's count back", c do
      sessions = [named("a", 1430), named("b", 1431)]
      {_, memory} = SessionIssues.match(sessions, %{}, @now)
      File.write!(Path.join(c.dir, "closed7"), "4")

      # Both issues' reads fail; the milestone's own counts still come.
      File.write!(Path.join(c.dir, "rest_down"), "")
      {facts, memory} = SessionIssues.match(sessions, memory, later(130))
      assert shown(facts) == [seven(4)]

      # And with its counts read failing too, it keeps 4.
      File.write!(Path.join(c.dir, "graphql_down"), "")
      {facts, _} = SessionIssues.match(sessions, memory, later(260))
      assert shown(facts) == [seven(4)]
    end

    test "a renamed milestone changes the facts, so the page draws its new name", c do
      {first, memory} = SessionIssues.match([named("a", 1430)], %{}, @now)
      File.write!(Path.join(c.dir, "title7"), "PLANTED renamed seven")

      {renamed, memory} = SessionIssues.match([named("a", 1430)], memory, later(121))
      assert shown(renamed) == shown(first)
      assert renamed != first
      assert Wallboard.MilestoneTitles.get("acme/shop", 7) == "PLANTED renamed seven"

      # The same name again changes nothing.
      {again, _} = SessionIssues.match([named("a", 1430)], memory, later(242))
      assert again == renamed
    end
  end
end
