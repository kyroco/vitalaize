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
    assert {pr.branch, pr.base} == {@branch, "main"}
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
            base: "main",
            created_at: at - 60,
            merged_at: at
          },
          %{
            repo: "acme/shop",
            number: 2,
            branch: "b",
            base: "main",
            created_at: at - 60,
            merged_at: at
          },
          %{
            repo: "acme/shop",
            number: 3,
            branch: "c",
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
