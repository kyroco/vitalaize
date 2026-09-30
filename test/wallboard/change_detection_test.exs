defmodule Wallboard.ChangeDetectionTest do
  @moduledoc "The board is told about new facts only when something it shows changed."
  use ExUnit.Case, async: true

  alias Wallboard.{Fixtures, Poller}
  alias Wallboard.Sources.{Claude, GitHub}

  defp repo_facts do
    {:ok, runs} = GitHub.parse_runs(Fixtures.read!("github/runs_24h.json"))
    {:ok, repo} = GitHub.parse_graphql(Fixtures.read!("github/graphql.json"), "ci")

    %{
      runs: runs,
      deploys: [],
      deploys_checked_at: ~U[2026-09-28 21:52:00Z],
      queue: repo.queue,
      prs: repo.prs,
      jobs: %{}
    }
  end

  defp github_facts(facts \\ repo_facts()),
    do: %{repos: [%{repo: "acme/shop", facts: facts, error: nil}]}

  defp claude_facts do
    {:ok, agents} = Claude.parse_agents(Fixtures.read!("claude/agents_busy.json"))
    sessions = Enum.map(agents, &Claude.build_session(&1, nil, nil, nil))
    {annotated, _, _} = Claude.track(sessions, nil, ~U[2026-09-28 21:52:00Z])
    %{sessions: annotated, problems: []}
  end

  test "the first result always counts as a change" do
    assert Poller.changed?(GitHub, nil, github_facts())
  end

  test "the same GitHub output twice is not a change" do
    refute Poller.changed?(GitHub, github_facts(), github_facts())
  end

  test "only re-checking the deploys is not a change" do
    a = repo_facts()

    refute Poller.changed?(
             GitHub,
             github_facts(a),
             github_facts(%{a | deploys_checked_at: ~U[2026-09-28 21:54:00Z]})
           )
  end

  test "a new run is a change" do
    a = repo_facts()
    [first | rest] = a.runs
    b = %{a | runs: [%{first | id: 1, status: :in_progress, conclusion: nil} | [first | rest]]}
    assert Poller.changed?(GitHub, github_facts(a), github_facts(b))
  end

  test "a pull request's gate turning red is a change" do
    a = repo_facts()
    b = %{a | prs: Enum.map(a.prs, &%{&1 | gate: :failed})}
    assert Poller.changed?(GitHub, github_facts(a), github_facts(b))
  end

  test "one repository's read failing is a change, and another repository's run is too" do
    a = github_facts()
    failed = %{a | repos: [%{hd(a.repos) | error: "gh: timed out"}]}
    assert Poller.changed?(GitHub, a, failed)

    second = %{a | repos: a.repos ++ [%{repo: "acme/api", facts: repo_facts(), error: nil}]}
    assert Poller.changed?(GitHub, a, second)
  end

  test "the same Claude sessions twice is not a change" do
    refute Poller.changed?(Claude, claude_facts(), claude_facts())
  end

  test "a Claude session starting to wait on you is a change" do
    a = claude_facts()

    b = %{
      a
      | sessions: Enum.map(a.sessions, &%{&1 | status: :needs, why: "It asked you a question"})
    }

    assert Poller.changed?(Claude, a, b)
  end
end
