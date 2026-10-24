defmodule Wallboard.GitHubIssuesTest do
  # Milestones, issues and projects from GitHub (issue #143). The parsing
  # tests read made-up fixtures in GitHub's GraphQL shape; the rest run a
  # stand-in gh on the PATH that answers like GitHub and keeps what it was
  # asked. One at a time: the PATH is this whole test run's.
  use ExUnit.Case, async: false

  alias Wallboard.{Fixtures, Settings}
  alias Wallboard.Sources.GitHub
  alias WallboardWeb.SettingsLive

  # The fixtures' "now": milestone 3 and issue 12 closed within the day
  # before it, milestone 4 and issue 13 long before.
  @now ~U[2026-10-20 15:00:00Z]

  defp page_one do
    {:ok, read} = GitHub.parse_issues(Fixtures.read!("github/issues.json"), @now)
    read
  end

  defp milestones_page do
    {:ok, read} = GitHub.parse_milestones(Fixtures.read!("github/milestones.json"), @now)
    read
  end

  defp issue(read, number), do: Enum.find(read.issues, &(&1.number == number))

  describe "parse_milestones/2 (scenario 1)" do
    test "keeps the open milestones and those closed in the last day" do
      read = milestones_page()

      assert Enum.map(read.milestones, &{&1.number, &1.title, &1.state}) == [
               {1, "Checkout: 1. Pay by card", :open},
               {2, "Checkout: 2. Refunds", :open},
               {3, "Search: 1. Basic search", :closed}
             ]

      assert Enum.find(read.milestones, &(&1.number == 3)).closed_at == ~U[2026-10-20 09:00:00Z]
    end

    test "each milestone holds its issues with number, title, state, closed time and the start of the body" do
      [one, two, _] = milestones_page().milestones

      assert [card, brands] = one.issues

      assert {card.number, card.title, card.state, card.closed_at} ==
               {10, "Card form", :open, nil}

      assert String.length(card.body) == 600
      assert String.starts_with?(card.body, "Customers pay by card on the last step.")

      assert {brands.number, brands.state, brands.closed_at, brands.body} ==
               {11, :closed, ~U[2026-10-10 14:00:00Z], "Show the brand."}

      refute one.issues_cut
      # GitHub had more of milestone 2's issues than one page holds.
      assert two.issues_cut
    end

    test "the next page of open milestones starts where GitHub says" do
      assert milestones_page().next == "Y3Vyc29yOjM="

      {:ok, two} = GitHub.parse_milestones(Fixtures.read!("github/milestones_page_2.json"), @now)
      assert {Enum.map(two.milestones, & &1.number), two.next} == {[5], nil}
    end
  end

  describe "parse_issues/2: issue links (scenario 2)" do
    test "an open issue holds its projects, linked branches, open closing pull requests, open blockers and labels" do
      card = issue(page_one(), 10)

      assert card.milestone == 1
      assert card.labels == ["Feature"]

      assert card.projects == [
               %{id: "PVT_checkout", number: 7, title: "Checkout", owner: "acme", closed: false},
               %{id: "PVT_search", number: 9, title: "Search", owner: "acme", closed: true}
             ]

      # A linked branch that was deleted has no name, and is left out.
      assert card.branches == ["robin/10-card-form"]
      # Merged and closed pull requests no longer close it.
      assert card.closing_prs == [40]
      # A closed blocker no longer blocks it; one in another repository does.
      assert card.blocked_by == [%{repo: "acme/shop", number: 9}, %{repo: "acme/api", number: 3}]
      assert String.length(card.body) == 600
    end

    test "an issue closed in the last day is kept with its links, and one closed before is not" do
      read = page_one()

      box = issue(read, 12)
      assert {box.state, box.closed_at, box.milestone} == {:closed, ~U[2026-10-20 10:00:00Z], 3}
      assert [%{title: "Search"}] = box.projects

      refute issue(read, 13)
      assert read.issues |> Enum.map(& &1.number) |> Enum.sort() == [10, 12, 14, 15]
    end

    test "the next page starts where GitHub says, and a short list of closed issues is whole" do
      read = page_one()
      assert read.next == "Y3Vyc29yOjI="
      refute read.cut
    end
  end

  describe "parse_issues/2: issues closed in the last day" do
    # A full page of 100 closed issues, the most recently updated first:
    # `today` of them closed in the day before @now, the rest long ago but
    # updated since. The oldest update on the page is `last_updated`.
    defp closed_page(today, last_updated) do
      nodes =
        for n <- 1..100 do
          %{
            "number" => n,
            "title" => "Closed #{n}",
            "state" => "CLOSED",
            "closedAt" =>
              if(n <= today, do: "2026-10-20T10:00:00Z", else: "2026-09-01T10:00:00Z"),
            "updatedAt" => if(n == 100, do: last_updated, else: "2026-10-20T12:00:00Z")
          }
        end

      Jason.encode!(%{"data" => %{"repository" => %{"closedIssues" => %{"nodes" => nodes}}}})
    end

    test "a full page whose oldest update is from the last day may have left closures out" do
      # 70 closed today, and 30 closed long ago but commented on today: the
      # 101st most recently updated could have been closed today too.
      {:ok, read} = GitHub.parse_issues(closed_page(70, "2026-10-20T08:00:00Z"), @now)
      assert length(read.issues) == 70
      assert read.cut
    end

    test "a full page that reaches back past the day holds every closure of the day" do
      {:ok, read} = GitHub.parse_issues(closed_page(70, "2026-10-18T08:00:00Z"), @now)
      assert length(read.issues) == 70
      refute read.cut
    end
  end

  describe "parse_issues/2: parked issues (scenario 3)" do
    test "an open parked issue holds the first line of its newest comment as the reason" do
      read = page_one()

      assert issue(read, 14).parked_reason == "Waiting on the payment provider's answer."
      # Not parked: no reason, whatever its comments say.
      assert issue(read, 10).parked_reason == nil
    end

    test "the label is read in any letter case, and an empty newest comment gives no reason" do
      parked = issue(page_one(), 15)
      assert parked.labels == ["parked"]
      assert parked.parked_reason == nil
    end
  end

  describe "parse_project/1 (scenario 4)" do
    test "holds every issue in the project, open and closed, with its milestone" do
      {:ok, project} = GitHub.parse_project(Fixtures.read!("github/project.json"))

      assert {project.number, project.title, project.closed, project.next} ==
               {7, "Checkout", false, nil}

      # Archived items, pull requests and drafts are left out.
      assert Enum.map(project.issues, &{&1.repo, &1.number, &1.state}) == [
               {"acme/shop", 10, :open},
               {"acme/shop", 5, :closed},
               {"acme/api", 2, :open}
             ]

      # A shipped milestone is known from its closed issue alone.
      milestones = project.issues |> Enum.map(& &1.milestone) |> Enum.reject(&is_nil/1)

      assert Enum.map(milestones, &{&1.number, &1.title, &1.state}) == [
               {1, "Checkout: 1. Pay by card", :open},
               {0, "Checkout: 0. Cart", :closed}
             ]

      assert Enum.at(project.issues, 1).closed_at == ~U[2026-08-02 12:00:00Z]
    end
  end

  # ---------------------------------------------------------------------------
  # With a stand-in gh

  describe "with a stand-in gh" do
    setup do
      dir = Fixtures.tmp_path("wallboard-gh-issues")
      File.mkdir_p!(dir)
      fixtures = Path.expand("../fixtures/github", __DIR__)

      # Each call is written to `asked` as one word: the REST path, or what
      # the GraphQL query is for. Without the scope file, a query that asks
      # for projects is refused as GitHub refuses it.
      File.write!(Path.join(dir, "gh"), """
      #!/bin/sh
      if [ "$2" = "graphql" ]; then
        case "$4" in
          *ProjectV2*) what=project ;;
          *openMilestones*'after: $after'*) what=milestones_page_2 ;;
          *openMilestones*) what=milestones ;;
          *'after: $after'*) what=issues_page_2 ;;
          *openIssues*) what=issues ;;
          *mergeQueue*) what=queue ;;
          *) what=other ;;
        esac
        case "$4" in *projectsV2*) what="$what+projects" ;; esac
        echo "$what" >> "$WALLBOARD_TEST_GH/asked"
        case "$4" in
          *projectsV2*)
            if [ -f "$WALLBOARD_TEST_GH/no_scope" ]; then
              echo '{"errors": [{"type": "INSUFFICIENT_SCOPES"}]}'
              echo "gh: Your token has not been granted the required scopes to execute this query. The 'projectsV2' field requires one of the following scopes: ['read:project'], but your token has only been granted the: ['repo'] scopes." >&2
              exit 1
            fi ;;
        esac
        case "$what" in
          milestones_page_2) cat "#{fixtures}/milestones_page_2.json" ;;
          milestones) cat "#{fixtures}/milestones.json" ;;
          issues_page_2*) cat "#{fixtures}/issues_page_2.json" ;;
          issues+projects) cat "#{fixtures}/issues.json" ;;
          issues) cat "#{fixtures}/issues_no_projects.json" ;;
          project) cat "#{fixtures}/project.json" ;;
          queue) echo '{"data": {"repository": {"mergeQueue": null, "pullRequests": {"nodes": []}}}}' ;;
          *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
        esac
        exit 0
      fi
      echo "$2" >> "$WALLBOARD_TEST_GH/asked"
      case "$2" in
        *"/actions/runs?"*) echo '{"total_count": 0, "workflow_runs": []}' ;;
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

      settings =
        Settings.merge(Settings.defaults(), %{
          github: %{
            repo: "acme/shop",
            gate_workflow: nil,
            deploy_workflows: [],
            dev_deploy: nil,
            prod_deploy: nil
          }
        })

      %{dir: dir, settings: settings, gh: hd(Settings.github_repos(settings))}
    end

    # What gh was asked since the last look.
    defp asked(dir) do
      file = Path.join(dir, "asked")

      if File.exists?(file) do
        lines = file |> File.read!() |> String.split("\n", trim: true)
        File.rm!(file)
        lines
      else
        []
      end
    end

    defp facts({:ok, %{repos: [%{facts: facts}]}, _memory}), do: facts

    test "milestones, issues and projects are read at most every two minutes; runs and pull requests every poll (scenario 6)",
         c do
      first = facts(GitHub.poll(c.settings, nil, %{}, @now))
      calls = asked(c.dir)
      assert "milestones" in calls
      assert "issues+projects" in calls
      assert [_, _, _] = first.milestones
      assert first.issues_checked_at == @now

      # A minute later: runs and pull requests again, but not the issues.
      later = DateTime.add(@now, 60, :second)
      prev = %{repos: [%{repo: "acme/shop", facts: first, error: nil}]}
      second = facts(GitHub.poll(c.settings, prev, %{}, later))
      calls = asked(c.dir)

      assert Enum.any?(calls, &String.contains?(&1, "/actions/runs?"))
      assert "queue" in calls
      refute Enum.any?(calls, &String.starts_with?(&1, "issues"))
      refute Enum.any?(calls, &String.starts_with?(&1, "milestones"))
      refute "project" in calls
      assert second.milestones == first.milestones
      assert second.issues == first.issues
      assert second.issues_checked_at == @now

      # Past two minutes they are read again.
      prev = %{repos: [%{repo: "acme/shop", facts: second, error: nil}]}
      third = facts(GitHub.poll(c.settings, prev, %{}, DateTime.add(@now, 130, :second)))
      calls = asked(c.dir)
      assert "milestones" in calls
      assert "issues+projects" in calls
      assert third.issues_checked_at == DateTime.add(@now, 130, :second)
    end

    test "when issues were read less than two minutes ago, the issue keys do not count as news",
         c do
      first = facts(GitHub.poll(c.settings, nil, %{}, @now))
      moved = %{first | issues_checked_at: DateTime.add(@now, 1, :second)}

      assert GitHub.fingerprint(%{repos: [%{repo: "acme/shop", facts: first, error: nil}]}) ==
               GitHub.fingerprint(%{repos: [%{repo: "acme/shop", facts: moved, error: nil}]})
    end

    test "one page of each by default: more open milestones or issues than it holds are marked cut",
         c do
      read = GitHub.fetch_issues(c.gh, nil, @now)

      assert asked(c.dir) == ["milestones", "issues+projects"]
      assert read.issues_cut
      refute issue(read, 16)
      assert read.milestones_cut
      assert Enum.map(read.milestones, & &1.number) == [1, 2, 3]
    end

    test "with issue_pages 2, the second page is read and an issue on both is kept once", c do
      read = GitHub.fetch_issues(%{c.gh | issue_pages: 2}, nil, @now)

      assert asked(c.dir) == [
               "milestones",
               "milestones_page_2",
               "issues+projects",
               "issues_page_2+projects"
             ]

      refute read.issues_cut
      refute read.milestones_cut
      assert Enum.map(read.milestones, & &1.number) == [1, 2, 3, 5]
      assert issue(read, 16).title == "Saved cards"
      assert Enum.count(read.issues, &(&1.number == 10)) == 1
      assert read.project_scope == :ok
    end

    test "without the read:project scope, milestones and issues still load (scenario 5)", c do
      File.write!(Path.join(c.dir, "no_scope"), "")

      read = GitHub.fetch_issues(c.gh, nil, @now)
      assert asked(c.dir) == ["milestones", "issues+projects", "issues"]

      assert read.project_scope == :missing
      assert Enum.map(read.milestones, & &1.number) == [1, 2, 3]
      assert issue(read, 10).branches == ["robin/10-card-form"]
      assert issue(read, 10).projects == nil
      assert issue(read, 14).parked_reason == "Waiting on the payment provider's answer."

      # Two minutes on, still missing: asked for with projects, then without.
      again = GitHub.fetch_issues(c.gh, read, DateTime.add(@now, 130, :second))
      assert asked(c.dir) == ["milestones", "issues+projects", "issues"]
      assert again.project_scope == :missing
    end

    test "once the scope is added, the next read finds projects, so the Settings note goes within two minutes",
         c do
      File.write!(Path.join(c.dir, "no_scope"), "")
      read = GitHub.fetch_issues(c.gh, nil, @now)
      assert read.project_scope == :missing

      # The person runs gh auth refresh -s read:project, as the note says.
      File.rm!(Path.join(c.dir, "no_scope"))
      asked(c.dir)

      next = GitHub.fetch_issues(c.gh, read, DateTime.add(@now, 130, :second))
      assert asked(c.dir) == ["milestones", "issues+projects"]
      assert next.project_scope == :ok
      assert [%{title: "Checkout"}, %{title: "Search"}] = issue(next, 10).projects
    end

    test "a failed read keeps the last milestones and issues", c do
      read = GitHub.fetch_issues(c.gh, nil, @now)

      File.write!(
        Path.join(c.dir, "gh"),
        "#!/bin/sh\necho 'gh: Server Error (HTTP 502)' >&2\nexit 1\n"
      )

      failed = GitHub.fetch_issues(c.gh, read, DateTime.add(@now, 130, :second))
      assert failed.milestones == read.milestones
      assert failed.issues == read.issues
      assert failed.issues_checked_at == DateTime.add(@now, 130, :second)
    end

    test "fetch_project/2 reads the project it is given (scenario 4)", c do
      assert {:ok, project} = GitHub.fetch_project("PVT_checkout", 1)
      assert asked(c.dir) == ["project"]
      assert project.id == "PVT_checkout"
      assert project.cut == false
      assert Enum.map(project.issues, & &1.number) == [10, 5, 2]
    end
  end

  describe "Settings page (scenario 5)" do
    defp settings_html(missing?) do
      settings = Settings.merge(Settings.defaults(), %{approve_devices: false})

      %{
        __changed__: nil,
        connected?: true,
        allowed?: true,
        notice: nil,
        linked: nil,
        linked_readable?: true,
        confirm_disconnect: nil,
        settings: settings,
        values: Settings.shown(settings),
        machines: [],
        devices: [],
        ignored_repos: [],
        no_project_scope?: missing?
      }
      |> SettingsLive.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
    end

    test "says which scope to add when the sign-in lacks read:project" do
      html = settings_html(true)
      assert html =~ "lacks the read:project scope"
      assert html =~ "gh auth refresh -s read:project"
    end

    test "the note promises nothing the board does not show yet" do
      # No page draws milestones or issues until the Project tab is built.
      refute settings_html(true) =~ "still show"
    end

    test "says nothing about it when the scope is there" do
      refute settings_html(false) =~ "read:project"
    end
  end

  describe "Settings page: finding the missing scope (scenario 5)" do
    # Stands in for the :github poller: answers the snapshot with the
    # facts it was given.
    defmodule FakeGitHub do
      use GenServer

      def start_link(facts), do: GenServer.start_link(__MODULE__, facts, name: :github)

      @impl true
      def init(facts), do: {:ok, facts}

      @impl true
      def handle_call(:snapshot, _from, facts),
        do:
          {:reply, %{facts: facts, meta: %{fetched_at: nil, error: nil, interval: 30_000}}, facts}
    end

    defp repos(scopes) do
      %{
        repos:
          for {scope, i} <- Enum.with_index(scopes) do
            %{repo: "acme/repo#{i}", facts: %{project_scope: scope}, error: nil}
          end
      }
    end

    test "the note shows when a repository's last read found the scope missing" do
      start_supervised!({FakeGitHub, repos([:ok, :missing])})
      assert SettingsLive.no_project_scope?()
    end

    test "no note when every read found the scope, before the first read, or with no poller" do
      refute SettingsLive.no_project_scope?()

      start_supervised!({FakeGitHub, %{repos: [%{repo: "acme/shop", facts: nil, error: "down"}]}})
      refute SettingsLive.no_project_scope?()
      stop_supervised!(FakeGitHub)

      start_supervised!({FakeGitHub, repos([:ok, :ok])})
      refute SettingsLive.no_project_scope?()
    end
  end

  describe "the issue_pages setting" do
    defp pages(value) do
      Settings.defaults()
      |> Settings.merge(%{github: %{issue_pages: value}})
      |> Settings.normalize()
      |> get_in([:github, :issue_pages])
    end

    test "a whole number of 1 or more is kept" do
      assert pages(3) == 3
    end

    test "text, a fraction, zero or nothing reads one page, so the poll never crashes on it" do
      for value <- ["2", 2.5, 0, -1, nil], do: assert(pages(value) == 1, inspect(value))
    end
  end
end
