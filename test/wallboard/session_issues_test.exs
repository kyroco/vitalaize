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
      case "$*" in
        *"issues("*|*"milestones("*) echo "$*" >> "$WALLBOARD_TEST_GH/listed" ;;
      esac
      if [ -f "$WALLBOARD_TEST_GH/down" ]; then
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

  defp session(id, fields), do: Map.merge(%{session_id: id, repo: "acme/shop"}, Map.new(fields))

  defp later(s), do: DateTime.add(@now, s)

  # A session whose prompts named #n in its own repository.
  defp named(id, n, fields \\ []), do: session(id, [issue_ref: %{repo: nil, number: n}] ++ fields)

  describe "match/3" do
    test "the issue a prompt named, when it is an issue here, numbers only", c do
      {facts, _} = SessionIssues.match([named("s1", 1418)], %{}, @now)
      assert facts == %{sessions: %{"s1" => %{repo: "acme/shop", number: 1418}}}
      assert calls(c) == ["api repos/acme/shop/issues/1418"]
      refute inspect(facts) =~ "PLANTED"
    end

    test "a linked issue is checked in the link's repository, whatever the session's" do
      ref = %{repo: "acme/shop", number: 1418}

      sessions = [
        session("a", repo: "acme/other", issue_ref: ref),
        %{session_id: "b", issue_ref: ref}
      ]

      {facts, _} = SessionIssues.match(sessions, %{}, @now)

      assert facts == %{
               sessions: %{
                 "a" => %{repo: "acme/shop", number: 1418},
                 "b" => %{repo: "acme/shop", number: 1418}
               }
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
      assert facts == %{sessions: %{"s1" => %{repo: "acme/shop", number: 77}}}
    end

    test "a named issue never asks about the branch", c do
      s = named("s1", 1418, branch: "feature/checkout")
      {facts, _} = SessionIssues.match([s], %{}, @now)
      assert facts == %{sessions: %{"s1" => %{repo: "acme/shop", number: 1418}}}
      assert calls(c) == ["api repos/acme/shop/issues/1418"]
    end

    test "a name or a branch with a number in it names nothing", c do
      sessions = [
        session("a", name: "1418-issue", branch: "robert/issue-1418-login"),
        session("b", name: "#1418")
      ]

      {facts, _} = SessionIssues.match(sessions, %{}, @now)
      assert facts == %{sessions: %{}}
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
      assert facts == %{sessions: %{"a" => %{repo: "acme/shop", number: 77}}}

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
      assert facts == %{sessions: %{"a" => %{repo: "Acme/Shop", number: 77}}}
    end

    test "a repository name that is not owner/name, such as dot parts or a line break, asks nothing",
         c do
      sessions = [
        named("a", 1418, repo: "../.."),
        named("b", 1418, repo: "acme/.."),
        named("c", 1418, repo: "acme/shop\n"),
        session("d", issue_ref: %{repo: "../..", number: 1418})
      ]

      assert {%{sessions: none}, _} = SessionIssues.match(sessions, %{}, @now)
      assert none == %{}
      assert calls(c) == []
    end

    test "a session with no repository, or no issue named and no branch, asks nothing", c do
      sessions = [
        %{session_id: "x", issue_ref: %{repo: nil, number: 1418}},
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
      assert facts == %{sessions: %{}}
      refute Enum.any?(calls(c), &(&1 =~ "graphql"))

      # Two minutes on, GitHub answers again.
      File.rm!(Path.join(c.dir, "rest_down"))
      {facts, _} = SessionIssues.match([s], memory, later(130))
      assert facts == %{sessions: %{"s1" => %{repo: "acme/shop", number: 1418}}}
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
    defmodule FakePoller do
      use GenServer

      def child_spec({name, facts}),
        do: %{id: name, start: {__MODULE__, :start_link, [{name, facts}]}}

      def start_link({name, facts}), do: GenServer.start_link(__MODULE__, facts, name: name)
      def init(facts), do: {:ok, facts}
      def handle_call(:snapshot, _from, facts), do: {:reply, %{facts: facts, meta: %{}}, facts}
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
        {FakePoller, {:claude, %{sessions: [%{session_id: "s1", name: "login", cwd: folder}]}}}
      )

      start_supervised!(
        {FakePoller, {:usage, %{sessions: %{"s1" => %{issue: %{repo: nil, number: 1418}}}}}}
      )

      assert {:ok, facts, memory} = SessionIssues.poll(nil, nil, nil, @now)
      assert facts == %{sessions: %{"s1" => %{repo: "acme/shop", number: 1418}}}
      assert {:issue, "acme/shop", 1418} in Map.keys(memory.reads)
    end

    test "a Codex session on this machine takes its issue from its card", c do
      folder = checkout(c, "main")

      card = %{session_id: "t1", name: "fix", cwd: folder, issue_ref: %{repo: nil, number: 1419}}
      start_supervised!({FakePoller, {:codex, %{sessions: [card]}}})

      assert {:ok, facts, _} = SessionIssues.poll(nil, nil, nil, @now)
      assert facts == %{sessions: %{"t1" => %{repo: "acme/shop", number: 1419}}}
    end

    test "a session both on this machine and in a stream takes its issue from this machine", c do
      folder = checkout(c, "main")

      start_supervised!(
        {FakePoller, {:claude, %{sessions: [%{session_id: "s1", name: "login", cwd: folder}]}}}
      )

      start_supervised!(
        {FakePoller, {:usage, %{sessions: %{"s1" => %{issue: %{repo: nil, number: 1418}}}}}}
      )

      # A collector streams the same session, and a session of its own.
      other = %{repo: nil, number: 1419}

      start_supervised!(
        {FakeStream,
         [
           %{session_id: "s1", name: "login", gh_repo: "acme/shop", issue_ref: other},
           %{session_id: "s2", name: "away", gh_repo: "acme/shop", issue_ref: other}
         ]}
      )

      assert {:ok, facts, _} = SessionIssues.poll(nil, nil, nil, @now)

      assert facts == %{
               sessions: %{
                 "s1" => %{repo: "acme/shop", number: 1418},
                 "s2" => %{repo: "acme/shop", number: 1419}
               }
             }
    end

    test "with no pollers running it finds nothing and asks nothing", c do
      assert {:ok, %{sessions: none}, _} = SessionIssues.poll(nil, nil, %{}, @now)
      assert none == %{}
      assert calls(c) == []
    end
  end
end
