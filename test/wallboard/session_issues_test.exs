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
    # One line for each call, the query's line breaks and all.
    printf '%s' "$*" | tr '\\n' ' ' >> "$WALLBOARD_TEST_GH/calls"
    echo >> "$WALLBOARD_TEST_GH/calls"
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
    if [ -f "$WALLBOARD_TEST_GH/down" ]; then
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

  describe "number/1" do
    test "the name first, then the branch" do
      assert SessionIssues.number(%{name: "1418-issue", branch: "robert/99-other"}) == 1418
      assert SessionIssues.number(%{name: "checkout", branch: "robert/1418-short-title"}) == 1418
      assert SessionIssues.number(%{name: "#1418"}) == 1418
      assert SessionIssues.number(%{branch: "fix_1418"}) == 1418
    end

    test "when there are two numbers, the first wins" do
      assert SessionIssues.number(%{branch: "robert/1418-fix-1420"}) == 1418
      assert SessionIssues.number(%{name: "12-then-13"}) == 12
    end

    test "a name with spaces is a title or a prompt, not a name picked for the issue" do
      # Codex and streamed sessions are named from their first prompt.
      s = %{name: "fix the 3 failing tests", branch: "robert/1418-fix"}
      assert SessionIssues.number(s) == 1418
      assert SessionIssues.number(%{name: "Bump node to 20 and fix CI"}) == nil
    end

    test "a number inside a word, an id or a version is not an issue" do
      for text <- ["4d6407ac", "v0.4.2", "shop2", "release-v2", "checkout", "", nil] do
        assert SessionIssues.number(%{name: text, branch: text}) == nil, inspect(text)
      end
    end

    test "a name that is only the start of the session's id is passed over" do
      s = %{session_id: "12345678-aaaa", name: "12345678", branch: "robert/1418-x"}
      assert SessionIssues.number(s) == 1418
    end
  end

  describe "match/3" do
    test "a number that is an issue here gives that issue, numbers only", c do
      {facts, _} = SessionIssues.match([session("s1", name: "1418-issue")], %{}, @now)
      assert facts == %{sessions: %{"s1" => %{repo: "acme/shop", number: 1418}}}
      assert calls(c) == ["api repos/acme/shop/issues/1418"]
      refute inspect(facts) =~ "PLANTED"
    end

    test "a number that is a pull request, or no issue at all, gives no issue" do
      sessions = [
        session("pr", name: "1420-review"),
        session("gone", branch: "robert/5555-old")
      ]

      assert {%{sessions: none}, _} = SessionIssues.match(sessions, %{}, @now)
      assert none == %{}
    end

    test "a session named from its prompt takes the issue from its branch", c do
      s = session("s1", name: "fix the 3 failing tests", branch: "robert/1418-fix")
      {facts, _} = SessionIssues.match([s], %{}, @now)
      assert facts == %{sessions: %{"s1" => %{repo: "acme/shop", number: 1418}}}
      assert calls(c) == ["api repos/acme/shop/issues/1418"]
    end

    test "a number in the name that is not an issue falls back to the branch's number" do
      s = session("s1", name: "5555-old", branch: "robert/1418-fix")
      {facts, _} = SessionIssues.match([s], %{}, @now)
      assert facts == %{sessions: %{"s1" => %{repo: "acme/shop", number: 1418}}}
    end

    test "a number in the name that is not an issue never asks for the branch's pull request" do
      s = session("s1", name: "5555-old", branch: "feature/checkout")
      assert {%{sessions: none}, _} = SessionIssues.match([s], %{}, @now)
      assert none == %{}
    end

    test "with no number, an open pull request from the branch that closes an issue gives it",
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

    test "a session with no repository, or no number and no branch, asks nothing", c do
      sessions = [
        %{session_id: "x", name: "1418-issue"},
        %{session_id: "y", name: "1418-issue", repo: "not a repo"},
        session("z", name: "checkout")
      ]

      assert {%{sessions: none}, _} = SessionIssues.match(sessions, %{}, @now)
      assert none == %{}
      assert calls(c) == []
    end

    test "an issue or a branch is read at most every two minutes", c do
      sessions = [
        session("a", name: "1418-issue"),
        session("b", name: "checkout", branch: "feature/checkout")
      ]

      {first, memory} = SessionIssues.match(sessions, %{}, @now)
      assert length(calls(c)) == 2

      {again, memory} = SessionIssues.match(sessions, memory, later(60))
      assert again == first
      assert length(calls(c)) == 2

      {third, _} = SessionIssues.match(sessions, memory, later(130))
      assert third == first
      assert length(calls(c)) == 4
    end

    test "a read that fails keeps what was read before", c do
      sessions = [
        session("a", name: "1418-issue"),
        session("b", name: "checkout", branch: "feature/checkout")
      ]

      {first, memory} = SessionIssues.match(sessions, %{}, @now)
      File.write!(Path.join(c.dir, "down"), "")

      {down, _} = SessionIssues.match(sessions, memory, later(130))
      assert down == first

      # Nothing read before, and GitHub down: no issue, and nothing breaks.
      assert {%{sessions: none}, _} = SessionIssues.match(sessions, %{}, later(130))
      assert none == %{}
    end

    test "what is remembered is only what live sessions still point at" do
      {_, memory} = SessionIssues.match([session("a", name: "1418-issue")], %{}, @now)
      assert Map.keys(memory.reads) == [{:issue, "acme/shop", 1418}]

      {_, memory} = SessionIssues.match([], memory, later(10))
      assert memory.reads == %{}
    end

    test "no repository's whole list of issues or milestones is ever asked for", c do
      sessions =
        for {name, branch} <- [
              {"1418-issue", nil},
              {"1420-pr", nil},
              {"checkout", "feature/checkout"},
              {"plain", "feature/none"}
            ],
            do: session(name, name: name, branch: branch)

      SessionIssues.match(sessions, %{}, @now)
      listed = Path.join(c.dir, "listed")
      if File.exists?(listed), do: flunk("asked for a list: " <> File.read!(listed))
      refute Enum.any?(calls(c), &(&1 =~ ~r{/issues(\?|$)|/milestones}))
    end
  end

  describe "poll/4" do
    # Stands in for the Claude poller, which holds this machine's sessions.
    defmodule FakePoller do
      use GenServer
      def start_link(facts), do: GenServer.start_link(__MODULE__, facts, name: :claude)
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

    test "a session on this machine has its repository and branch read from its folder", c do
      folder = checkout(c, "robert/1418-login")

      start_supervised!(
        {FakePoller, %{sessions: [%{session_id: "s1", name: "login", cwd: folder}]}}
      )

      assert {:ok, facts, memory} = SessionIssues.poll(nil, nil, nil, @now)
      assert facts == %{sessions: %{"s1" => %{repo: "acme/shop", number: 1418}}}
      assert Map.keys(memory.reads) == [{:issue, "acme/shop", 1418}]
    end

    test "a session both on this machine and in a stream takes its issue from this machine", c do
      folder = checkout(c, "robert/1418-login")

      start_supervised!(
        {FakePoller, %{sessions: [%{session_id: "s1", name: "login", cwd: folder}]}}
      )

      # A collector streams the same session, its branch read from the
      # transcript, and a session of its own.
      start_supervised!(
        {FakeStream,
         [
           %{session_id: "s1", name: "login", gh_repo: "acme/shop", branch: "robert/1419-old"},
           %{session_id: "s2", name: "away", gh_repo: "acme/shop", branch: "robert/1419-old"}
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
