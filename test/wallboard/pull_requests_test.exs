defmodule Wallboard.PullRequestsTest do
  # Merged pull requests, the sessions behind each, and the Shipped cards.
  use ExUnit.Case, async: false

  alias Wallboard.Archive.{GitHubCollector, PullRequests, Transcript, Trends}
  alias Wallboard.{Fixtures, Settings, Store}

  @branch "dev/shop-0035-a-change"
  # 2026-10-01 19:25:11 UTC, when #35 in the fixture merged.
  @merged 1_790_882_711

  test "reads closed pull requests from a real reply" do
    {:ok, prs} =
      GitHubCollector.parse_prs(Fixtures.read!("github/pulls_closed.json"), "acme/shop")

    pr = hd(prs)

    assert length(prs) == 6
    assert pr.number == 35
    assert {pr.branch, pr.head_repo, pr.base} == {@branch, "acme/shop", "main"}
    assert pr.merged_at == @merged
    assert pr.created_at == @merged - 122
    assert pr.updated_at == @merged + 30
    assert pr.url == "https://github.com/acme/shop/pull/35"

    assert GitHubCollector.parse_prs(~s({"message": "Not Found"}), "acme/shop") ==
             {:error, "GitHub returned pull requests in an unexpected shape"}
  end

  describe "tying sessions to pull requests" do
    defp pr(number, branch, merged_at, extra \\ %{}) do
      Map.merge(
        %{
          repo: "acme/shop",
          number: number,
          title: "Shop change #{number}",
          url: "https://github.com/acme/shop/pull/#{number}",
          branch: branch,
          head_repo: "acme/shop",
          base: "main",
          created_at: merged_at - 3600,
          merged_at: merged_at
        },
        extra
      )
    end

    defp session(id, extra) do
      Map.merge(
        %{
          machine: "m",
          session_id: id,
          tool: "claude",
          repo: "acme/shop",
          branch: nil,
          started_at: @merged - 7200,
          cost: 0.0,
          tokens: 0,
          prs: []
        },
        extra
      )
    end

    test "a session counts for the pull request it opened, from its pr-link" do
      [pr] =
        PullRequests.link([pr(35, @branch, @merged)], [
          session("opener", %{
            branch: "main",
            cost: 4.0,
            tokens: 1000,
            prs: [%{"repo" => "Acme/Shop", "number" => 35, "url" => "u"}]
          })
        ])

      assert [%{session_id: "opener", share: 1.0}] = pr.sessions
      assert {pr.cost, pr.tokens, pr.claude_sessions} == {4.0, 1000.0, 1}
    end

    test "a session on the branch counts when it started before the merge, Codex included" do
      [pr] =
        PullRequests.link([pr(35, @branch, @merged)], [
          session("codex", %{tool: "codex", repo: "ACME/shop", branch: @branch, tokens: 500}),
          session("after", %{branch: @branch, started_at: @merged + 60, cost: 9.0}),
          session("other-repo", %{repo: "acme/web", branch: @branch, cost: 9.0}),
          session("no-repo", %{repo: nil, branch: @branch, cost: 9.0})
        ])

      assert Enum.map(pr.sessions, & &1.session_id) == ["codex"]
      assert {pr.cost, pr.codex_tokens, pr.codex_sessions} == {0, 500.0, 1}
    end

    test "a reused branch name goes to the first pull request merged after the session began" do
      old = pr(30, @branch, @merged - 10 * 86_400)
      new = pr(35, @branch, @merged)

      [old_pr, new_pr] = PullRequests.link([old, new], [session("s", %{branch: @branch})])

      assert old_pr.sessions == []
      assert [%{session_id: "s"}] = new_pr.sessions
    end

    test "a session behind two pull requests splits its spending between them" do
      prs = [pr(35, @branch, @merged), pr(34, "dev/other", @merged - 600)]

      [a, b] =
        PullRequests.link(prs, [
          session("both", %{
            branch: @branch,
            cost: 6.0,
            tokens: 900,
            prs: [
              %{"repo" => "acme/shop", "number" => 34},
              %{"repo" => "acme/shop", "number" => 35}
            ]
          })
        ])

      assert {a.cost, b.cost} == {3.0, 3.0}
      assert {a.tokens, b.tokens} == {450.0, 450.0}
      assert [%{share: 0.5}] = a.sessions
    end

    test "a pull request from a fork's main does not claim every session on main" do
      [pr] =
        PullRequests.link([pr(36, "main", @merged)], [session("on-main", %{branch: "main"})])

      assert pr.sessions == []
    end

    test "a release pull request from main does not claim the sessions that worked on main" do
      # #76 is a feature merged into main by a session that ran on main;
      # #77 then took main into production.
      [feature, release] =
        PullRequests.link(
          [
            pr(76, @branch, @merged - 600),
            pr(77, "main", @merged, %{base: "production"})
          ],
          [
            session("on-main", %{
              branch: "main",
              cost: 8.0,
              prs: [%{"repo" => "acme/shop", "number" => 76}]
            })
          ]
        )

      assert {feature.cost, release.sessions} == {8.0, []}

      # Long-lived branches are known from every saved pull request, not
      # only those in the window.
      [release] =
        PullRequests.link(
          [pr(77, "main", @merged, %{base: "production"})],
          [session("on-main", %{branch: "main"})],
          MapSet.new([{"acme/shop", "main"}])
        )

      assert release.sessions == []
    end

    test "a fork's pull request does not claim sessions on a branch of the same name here" do
      [pr] =
        PullRequests.link(
          [pr(40, "patch-1", @merged, %{head_repo: "someone/shop"})],
          [session("local", %{branch: "patch-1"})]
        )

      assert pr.sessions == []
    end
  end

  describe "from the database" do
    setup do
      start_supervised!({Store, path: ":memory:"})
      :ok
    end

    defp put_session(id, row) do
      ended = row[:ended_at] || @merged - 600

      :ok =
        Store.put_session(
          Map.merge(
            %{
              machine: "m",
              session_id: id,
              tool: "claude",
              started_at: @merged - 7200,
              ended_at: ended,
              input_tokens: 0,
              output_tokens: 0,
              cache_read_tokens: 0,
              cache_write_tokens: 0,
              cost: 0.0
            },
            row
          )
        )
    end

    test "a session saved before its repository was recorded is found from this machine's folder" do
      dir = Path.join(System.tmp_dir!(), "vitalaize-old-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, ".git"))

      File.write!(Path.join([dir, ".git", "config"]), """
      [remote "origin"]
      \turl = https://github.com/acme/shop.git
      """)

      on_exit(fn -> File.rm_rf!(dir) end)

      :ok =
        Store.put_prs([
          %{
            repo: "acme/shop",
            number: 35,
            branch: @branch,
            head_repo: "acme/shop",
            base: "main",
            created_at: @merged - 3600,
            merged_at: @merged
          }
        ])

      # Both rows have no repo. The first ran on this machine; the second
      # came from another one, whose folder cannot be read here.
      put_session("own", %{tool: "codex", cwd: dir, git_branch: @branch, output_tokens: 50})

      put_session("streamed", %{
        tool: "codex",
        source: "stream",
        cwd: dir,
        git_branch: @branch,
        output_tokens: 70
      })

      settings = Settings.merge(%{github: %{repo: "acme/shop"}}, %{})
      [pr] = PullRequests.merged(settings, @merged - 86_400)

      assert Enum.map(pr.sessions, & &1.session_id) == ["own"]
      assert pr.codex_tokens == 50.0
    end

    test "only the tracked repositories' merged pull requests are read, with their sessions" do
      {:ok, prs} =
        GitHubCollector.parse_prs(Fixtures.read!("github/pulls_closed.json"), "acme/shop")

      :ok = Store.put_prs(Enum.map(prs, &Map.delete(&1, :updated_at)))

      :ok =
        Store.put_prs([
          %{repo: "acme/web", number: 1, branch: @branch, base: "main", merged_at: @merged},
          %{repo: "acme/shop", number: 99, branch: "x", base: "main", closed_at: @merged}
        ])

      put_session("opener", %{
        git_branch: "main",
        repo: "acme/shop",
        cost: 2.0,
        input_tokens: 100,
        output_tokens: 20,
        detail: %{prs: [%{number: 35, repo: "acme/shop", url: "u", at: nil}]}
      })

      put_session("fixer", %{
        tool: "codex",
        source: "stream",
        git_branch: @branch,
        repo: "acme/shop",
        cache_read_tokens: 300
      })

      settings = Settings.merge(%{github: %{repo: "acme/shop"}}, %{})
      merged = PullRequests.merged(settings, @merged - 86_400)

      # Six merged in the fixture; acme/web is not tracked, #99 never merged.
      assert merged |> Enum.map(& &1.number) |> Enum.sort() == [30, 31, 32, 33, 34, 35]

      pr = Enum.find(merged, &(&1.number == 35))
      assert pr.sessions |> Enum.map(& &1.session_id) |> Enum.sort() == ["fixer", "opener"]
      assert {pr.cost, pr.tokens, pr.codex_tokens} == {2.0, 120.0, 300.0}
    end

    test "the Shipped cards and the comparison, per merged pull request" do
      now = DateTime.utc_now()
      at = DateTime.to_unix(now) - 3600

      :ok =
        Store.put_prs([
          %{
            repo: "acme/shop",
            number: 1,
            branch: "a",
            head_repo: "acme/shop",
            base: "main",
            created_at: at - 60,
            merged_at: at
          },
          %{
            repo: "acme/shop",
            number: 2,
            branch: "b",
            head_repo: "acme/shop",
            base: "main",
            created_at: at - 60,
            merged_at: at
          },
          %{
            repo: "acme/shop",
            number: 3,
            branch: "c",
            head_repo: "acme/shop",
            base: "main",
            created_at: at - 60,
            merged_at: at
          }
        ])

      session = fn id, tool, branch, cost, tokens ->
        put_session(id, %{
          tool: tool,
          git_branch: branch,
          repo: "acme/shop",
          started_at: at - 7200,
          ended_at: at - 120,
          cost: cost,
          output_tokens: tokens
        })
      end

      session.("a1", "claude", "a", 3.0, 1_000)
      session.("a2", "claude", "a", 1.0, 1_000)
      session.("b1", "codex", "b", 0.0, 4_000)
      # #3 was merged by hand: no session.

      settings = %{
        archive: %{backfill_days: 14},
        codex: %{enabled: true},
        github: %{
          repo: "acme/shop",
          gate_workflow: "ci.yml",
          dev_deploy: "deploy-staging.yml",
          prod_deploy: "deploy-production.yml"
        }
      }

      t = Trends.build(settings, 7, now)
      card = fn key -> Enum.find(t.cards, &(&1.key == key)) end

      assert card.(:merged_prs).value == 3
      assert card.(:merged_prs).sub == "1.5 sessions per PR"
      assert card.(:pr_cost).value == 4.0
      assert card.(:pr_cost).sub == "1 of 3 matched to Claude sessions"
      assert card.(:pr_tokens).value == 3_000.0
      assert card.(:pr_tokens).sub == "2 of 3 matched to sessions"
      assert card.(:pr_cost).group == :shipped

      # All three merged on one day: today, or yesterday just after midnight.
      assert card.(:merged_prs).series |> Enum.reject(&(&1 in [nil, 0])) == [3]

      [lead | _] = t.compare
      assert lead.key == :tokens_per_pr
      assert {lead.claude, lead.codex} == {2_000.0, 4_000.0}
      refute Enum.any?(t.compare, &(&1.key == :tokens_per_kline))
    end

    test "Shipped says it is loading until every repository's pull requests are saved" do
      settings = %{github: %{repo: "o/r"}}
      assert Trends.shipped_loading(settings) == "Loading…"
      Store.put_meta("github_prs_backfill:o/r", "2026-10-05")
      assert Trends.shipped_loading(settings) == nil
    end

    test "after an upgrade only Shipped waits for its pull requests; every other card keeps its change" do
      now = DateTime.utc_now()
      today = Date.utc_today()
      day = 86_400
      at = DateTime.to_unix(now)

      # A board that has saved sessions and runs for 90 days, upgraded today:
      # its first pull request round has just saved 14 days of them.
      Store.put_meta("claude_since", Date.to_iso8601(Date.add(today, -90)))
      Store.put_meta("github_backfill:acme/shop", Date.to_iso8601(Date.add(today, -90)))
      Store.put_meta("github_prs_backfill:acme/shop", Date.to_iso8601(today))

      for {id, ago} <- [{"now", 2}, {"before", 20}] do
        put_session(id, %{started_at: at - ago * day - 60, ended_at: at - ago * day, prompts: 1})
      end

      :ok =
        Store.put_prs(
          for {n, ago} <- [{1, 2}, {2, 20}],
              do: %{
                repo: "acme/shop",
                number: n,
                branch: "b#{n}",
                base: "main",
                created_at: at - ago * day - 60,
                merged_at: at - ago * day
              }
        )

      t = Trends.build(full_settings(), 14, now)
      card = fn key -> Enum.find(t.cards, &(&1.key == key)) end

      assert t.history_start == Date.add(today, -90)
      assert card.(:sessions).change == 0.0
      # The 14 days before reach past the pull requests' first saved day.
      assert card.(:merged_prs).change == nil
    end
  end

  describe "the GitHub round" do
    setup do
      start_supervised!({Store, path: ":memory:"})

      dir = Path.join(System.tmp_dir!(), "vitalaize-gh-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      pulls = Path.join(dir, "pulls.json")

      # A stand-in for `gh api`: the pull requests from a file, and no runs.
      File.write!(Path.join(dir, "gh"), """
      #!/bin/sh
      case "$2" in
        *pulls*) cat "#{pulls}" ;;
        *actions/runs\\?*) echo '{"workflow_runs": [], "total_count": 0}' ;;
        *) echo '{}' ;;
      esac
      """)

      File.chmod!(Path.join(dir, "gh"), 0o755)
      path = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> path)

      on_exit(fn ->
        System.put_env("PATH", path)
        File.rm_rf!(dir)
      end)

      %{pulls: pulls}
    end

    test "a pull request merged while the board was off for a weekend is still saved", %{
      pulls: pulls
    } do
      # The board's last good round was Friday 5:00 PM Eastern; a pull
      # request merged at 6:30 PM and nothing touched it again. The board
      # comes back Monday 9:00 AM Eastern.
      friday = DateTime.to_unix(~U[2026-10-02 21:00:00Z])
      monday = ~U[2026-10-05 13:00:00Z]

      File.write!(
        pulls,
        Jason.encode!([
          %{
            number: 50,
            state: "closed",
            title: "Shop change 50",
            html_url: "https://github.com/acme/shop/pull/50",
            created_at: "2026-10-02T20:00:00Z",
            updated_at: "2026-10-02T22:30:05Z",
            closed_at: "2026-10-02T22:30:00Z",
            merged_at: "2026-10-02T22:30:00Z",
            head: %{ref: "dev/shop-0050", sha: "abc"},
            base: %{ref: "main"}
          }
        ])
      )

      Store.put_meta("github_backfill:acme/shop", "2026-09-20")
      Store.put_meta("github_prs_backfill:acme/shop", "2026-09-20")
      Store.put_meta("github_prs_through:acme/shop", Integer.to_string(friday))

      assert {:ok, 0, 0} = GitHubCollector.round(full_settings(), monday)
      assert [%{number: 50}] = Store.query("SELECT number FROM gh_prs", [])

      # The next round starts from this one.
      assert Store.get_meta("github_prs_through:acme/shop") ==
               Integer.to_string(DateTime.to_unix(monday))
    end
  end

  defp full_settings do
    %{
      archive: %{backfill_days: 14, github_jobs_per_round: 10},
      codex: %{enabled: true},
      github: %{
        repo: "acme/shop",
        gate_workflow: "ci.yml",
        dev_deploy: "deploy-staging.yml",
        prod_deploy: "deploy-production.yml"
      }
    }
  end

  test "this machine's session records the GitHub repository of its folder" do
    dir = Path.join(System.tmp_dir!(), "vitalaize-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".git"))

    File.write!(Path.join([dir, ".git", "config"]), """
    [remote "origin"]
    \turl = git@github.com:acme/shop.git
    """)

    on_exit(fn -> File.rm_rf!(dir) end)

    ctx = %{
      prices: Settings.defaults().usage.prices,
      machine: "m",
      session_id: "s",
      account: "main",
      path: nil,
      size: 0,
      mtime: 0,
      now: 0
    }

    tally = %{Transcript.empty() | cwd: dir}
    assert {%{repo: "acme/shop"}, _} = Transcript.to_record(tally, [], ctx)

    # An upload's folder is on the machine that sent it, so it is not read here.
    assert {%{repo: nil}, _} = Transcript.to_record(tally, [], Map.put(ctx, :source, "upload"))
  end
end
