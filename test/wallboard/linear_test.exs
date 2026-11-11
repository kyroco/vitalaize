defmodule Wallboard.LinearTest do
  # Which Linear issue a live session is on, and how far down its milestone
  # or project is. A stand-in answers like Linear's API and writes down
  # every question. One at a time: the key and the stand-in are this whole
  # test run's.
  use ExUnit.Case, async: false

  alias Wallboard.Collector.Proto
  alias Wallboard.{MilestoneTitles, Secrets}
  alias Wallboard.Sources.SessionIssues

  @now ~U[2026-11-11 15:00:00Z]

  @milestone "11111111-1111-4111-8111-111111111111"
  @project "22222222-2222-4222-8222-222222222222"
  @big "33333333-3333-4333-8333-333333333333"

  # The workspace has teams VIT and MAST. VIT-41 is in a milestone of the
  # project "PLANTED project", VIT-42 in the project "PLANTED loose" with
  # no milestone, VIT-43 in neither, and VIT-44 in a project with 300
  # issues. Linear ties the branch robert/vit-41-linear to VIT-41.
  @issues %{
    {"VIT", 41} => %{
      "identifier" => "VIT-41",
      "title" => "PLANTED issue text",
      "project" => %{"id" => @project},
      "projectMilestone" => %{"id" => @milestone}
    },
    {"VIT", 42} => %{
      "identifier" => "VIT-42",
      "project" => %{"id" => @project},
      "projectMilestone" => nil
    },
    {"VIT", 43} => %{"identifier" => "VIT-43", "project" => nil, "projectMilestone" => nil},
    {"VIT", 44} => %{
      "identifier" => "VIT-44",
      "project" => %{"id" => @big},
      "projectMilestone" => nil
    }
  }

  setup do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    {:ok, down} = Agent.start_link(fn -> false end)

    Application.put_env(:wallboard, :linear_post, fn query, vars, key_fun ->
      Agent.update(calls, &[{query, vars, key_fun.()} | &1])

      if Agent.get(down, & &1),
        do: :failed,
        else: {:ok, Jason.encode!(%{data: answer(query, vars)})}
    end)

    # The key as a read of the settings leaves it, held in a function.
    :persistent_term.put({Secrets, :linear}, {:ok, fn -> "lin_api_PLANTEDKEY" end})
    unless Process.whereis(MilestoneTitles), do: start_supervised!(MilestoneTitles)

    on_exit(fn ->
      Application.delete_env(:wallboard, :linear_post)
      :persistent_term.erase({Secrets, :linear})
    end)

    %{calls: calls, down: down}
  end

  defp answer(query, vars) do
    cond do
      query =~ "teams(" ->
        %{teams: %{nodes: [%{key: "VIT"}, %{key: "MAST"}]}}

      query =~ "issueVcsBranchSearch" ->
        for {"b" <> _ = name, branch} <- vars, into: %{} do
          {name, if(branch == "robert/vit-41-linear", do: @issues[{"VIT", 41}])}
        end

      query =~ "i0: issues(" ->
        for {"t" <> i, team} <- vars, into: %{} do
          {"i" <> i, %{nodes: List.wrap(@issues[{team, vars["n" <> i]}])}}
        end

      true ->
        counts(query, vars)
    end
  end

  # A milestone's or a project's issues, 250 to a page, as their kinds of
  # status. The filter leaves canceled ones out, so none is answered.
  defp counts(query, %{"fid" => id} = vars) do
    {named, states} =
      case id do
        @milestone ->
          {%{name: "PLANTED milestone", project: %{name: "PLANTED project"}},
           ~w(completed completed started unstarted backlog)}

        @project ->
          {%{name: "PLANTED loose"}, ~w(completed started)}

        @big ->
          {%{name: "PLANTED big"},
           List.duplicate("completed", 120) ++ List.duplicate("backlog", 180)}
      end

    true = query =~ ~s(nin: ["canceled", "duplicate"])
    from = String.to_integer(vars["after"] || "0")
    page = states |> Enum.drop(from) |> Enum.take(250)
    more? = from + 250 < length(states)

    issues = %{
      nodes: Enum.map(page, &%{state: %{type: &1}}),
      pageInfo: %{hasNextPage: more?, endCursor: if(more?, do: "#{from + 250}")}
    }

    if query =~ "named:", do: %{named: named, issues: issues}, else: %{issues: issues}
  end

  defp asked(c), do: c.calls |> Agent.get(& &1) |> Enum.reverse()

  # The questions asked, without the one for the teams.
  defp questions(c), do: for({q, vars, _} <- asked(c), not (q =~ "teams("), do: {q, vars})

  defp session(id, fields), do: Map.merge(%{key: id, session_id: id}, Map.new(fields))

  defp named(id, n, fields \\ []),
    do: session(id, [issue_refs: [%{team: "VIT", number: n}]] ++ fields)

  test "the Linear issue a prompt named, and the milestone it is in", c do
    {facts, memory} = SessionIssues.match([named("s1", 41)], %{}, @now)

    assert facts.sessions == %{"s1" => %{linear: "VIT-41"}}

    assert [%{source: :linear, kind: :milestone, number: @milestone, done: 2, total: 5} = m] =
             facts.milestones

    assert m.repo == "Linear"
    assert m.sessions == ["s1"]

    # The names are Linear text: kept for the box, and nowhere else.
    assert MilestoneTitles.get("linear", @milestone) == "PLANTED milestone"
    assert MilestoneTitles.get("linear project", @milestone) == "PLANTED project"
    refute inspect({facts, memory}) =~ "PLANTED"

    # The key goes with each question and into nothing that is kept.
    assert Enum.all?(asked(c), fn {_, _, key} -> key == "lin_api_PLANTEDKEY" end)

    assert [{issue, %{"t0" => "VIT", "n0" => 41}}, {_counts, %{"fid" => @milestone}}] =
             questions(c)

    refute issue =~ "title"
  end

  test "an issue in a project with no milestone shows the project" do
    {facts, _} = SessionIssues.match([named("s1", 42)], %{}, @now)

    assert [%{source: :linear, kind: :project, number: @project, done: 1, total: 2}] =
             facts.milestones

    assert MilestoneTitles.get("linear", @project) == "PLANTED loose"
    assert MilestoneTitles.get("linear project", @project) == nil
  end

  test "an issue in no project has its card's id and no box" do
    {facts, _} = SessionIssues.match([named("s1", 43)], %{}, @now)
    assert facts == %{sessions: %{"s1" => %{linear: "VIT-43"}}, milestones: []}
  end

  test "a project with more than 250 issues is counted page by page", c do
    {facts, _} = SessionIssues.match([named("s1", 44)], %{}, @now)
    assert [%{number: @big, done: 120, total: 300}] = facts.milestones
    assert [_issue, {first, _}, {second, %{"after" => "250"}}] = questions(c)
    assert first =~ "named:"
    refute second =~ "named:"
  end

  test "a word written like an issue of no team here is never asked about", c do
    refs = [%{team: "UTF", number: 8}, %{team: "VIT", number: 41}]
    {facts, _} = SessionIssues.match([session("s1", issue_refs: refs)], %{}, @now)

    assert facts.sessions == %{"s1" => %{linear: "VIT-41"}}
    refute Enum.any?(questions(c), fn {_, vars} -> "UTF" in Map.values(vars) end)
  end

  test "a named number that is no issue falls back to the branch Linear knows", c do
    s = named("s1", 999, branch: "robert/vit-41-linear")
    {facts, _} = SessionIssues.match([s], %{}, @now)

    assert facts.sessions == %{"s1" => %{linear: "VIT-41"}}
    assert Enum.any?(questions(c), fn {_, vars} -> vars == %{"b0" => "robert/vit-41-linear"} end)
  end

  test "a named issue never asks about the branch, and main is never asked about", c do
    sessions = [named("s1", 41, branch: "robert/vit-41-linear"), session("s2", branch: "main")]
    {facts, _} = SessionIssues.match(sessions, %{}, @now)

    assert facts.sessions == %{"s1" => %{linear: "VIT-41"}}
    refute Enum.any?(questions(c), fn {q, _} -> q =~ "issueVcsBranchSearch" end)
  end

  test "sessions on the same milestone share one box and one count", c do
    sessions = [named("s1", 41), session("s2", branch: "robert/vit-41-linear")]
    {facts, _} = SessionIssues.match(sessions, %{}, @now)

    assert [%{number: @milestone, sessions: ["s1", "s2"]}] = facts.milestones
    assert Enum.count(questions(c), fn {_, vars} -> vars["fid"] == @milestone end) == 1
  end

  test "answers stand for two minutes, and the teams for ten", c do
    {facts, memory} = SessionIssues.match([named("s1", 41)], %{}, @now)
    before = length(asked(c))

    assert {^facts, memory} =
             SessionIssues.match([named("s1", 41)], memory, DateTime.add(@now, 60))

    assert length(asked(c)) == before

    {^facts, _} = SessionIssues.match([named("s1", 41)], memory, DateTime.add(@now, 180))
    again = Enum.drop(asked(c), before)
    assert length(again) == 2
    refute Enum.any?(again, fn {q, _, _} -> q =~ "teams(" end)
  end

  test "while Linear cannot be reached, what was read before stays", c do
    {facts, memory} = SessionIssues.match([named("s1", 41)], %{}, @now)
    Agent.update(c.down, fn _ -> true end)

    assert {^facts, _} = SessionIssues.match([named("s1", 41)], memory, DateTime.add(@now, 900))
  end

  test "an issue Linear could not be asked about waits: its branch does not stand in", c do
    Agent.update(c.down, fn _ -> true end)
    s = named("s1", 41, branch: "robert/vit-41-linear")

    assert {%{sessions: none, milestones: []}, _} = SessionIssues.match([s], %{}, @now)
    assert none == %{}
  end

  test "with no Linear key, Linear is never asked and nothing changes", c do
    :persistent_term.erase({Secrets, :linear})
    s = named("s1", 41, branch: "robert/vit-41-linear")

    assert {%{sessions: none, milestones: []}, _} = SessionIssues.match([s], %{}, @now)
    assert none == %{}
    assert asked(c) == []
  end

  test "a collector sends the Linear issues a session named, apart from GitHub's" do
    sum = %Proto.Summary{
      issues: [%Proto.IssueRef{repo: "", number: 7}],
      linear_issues: [
        %Proto.LinearRef{team: "VIT", number: 41},
        %Proto.LinearRef{team: "not a team", number: 1}
      ]
    }

    back = sum |> Proto.Summary.encode() |> Proto.Summary.decode()
    assert back.linear_issues == sum.linear_issues

    # A hub from before the field reads only the GitHub ones.
    assert [%Proto.IssueRef{number: 7}] = back.issues
  end

  test "words written like an issue before the real one do not crowd it out" do
    refs =
      Wallboard.IssueRef.keep(
        [],
        "Fix the UTF-8 decoding of ISO-8601 dates, SHA-256 too, per VIT-41"
      )

    {facts, _} = SessionIssues.match([session("s1", issue_refs: refs)], %{}, @now)
    assert facts.sessions == %{"s1" => %{linear: "VIT-41"}}

    # A later prompt's issue still counts after such words.
    later =
      []
      |> Wallboard.IssueRef.keep("UTF-8, ISO-8601 and SHA-256")
      |> Wallboard.IssueRef.keep("VIT-42")

    {facts, _} = SessionIssues.match([session("s2", issue_refs: later)], %{}, @now)
    assert facts.sessions == %{"s2" => %{linear: "VIT-42"}}
  end

  test "a session is asked about at most three Linear issues, whatever it named", c do
    refs = for n <- [999, 998, 997, 41], do: %{team: "VIT", number: n}
    {facts, _} = SessionIssues.match([session("s1", issue_refs: refs)], %{}, @now)

    assert facts.sessions == %{}
    asked = for {_, vars} <- questions(c), {"n" <> _, n} <- vars, do: n
    assert Enum.sort(asked) == [997, 998, 999]
  end

  describe "a board that starts while Linear cannot be reached" do
    setup c do
      # A stand-in gh: an open pull request from any branch closes issue 77.
      dir = Wallboard.Fixtures.tmp_path("wallboard-linear-gh")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "gh"), """
      #!/bin/sh
      echo called >> "#{dir}/calls"
      echo '{"data": {"repository": {"b0": {"nodes": [{"headRepository": {"nameWithOwner": "acme/shop"}, "closingIssuesReferences": {"nodes": [{"number": 77, "repository": {"nameWithOwner": "acme/shop"}}]}}]}}}}'
      """)

      File.chmod!(Path.join(dir, "gh"), 0o755)
      path = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> path)

      on_exit(fn ->
        System.put_env("PATH", path)
        File.rm_rf!(dir)
      end)

      Agent.update(c.down, fn _ -> true end)
      %{gh: dir}
    end

    test "a named Linear issue waits: its branch's GitHub issue does not stand in", c do
      s = named("s1", 41, repo: "acme/shop", branch: "feature/checkout")

      assert {%{sessions: none, milestones: []}, memory} = SessionIssues.match([s], %{}, @now)
      assert none == %{}
      refute File.exists?(Path.join(c.gh, "calls"))

      # Once Linear answers, the issue the prompt named shows.
      Agent.update(c.down, fn _ -> false end)
      {facts, _} = SessionIssues.match([s], memory, DateTime.add(@now, 180))
      assert facts.sessions == %{"s1" => %{linear: "VIT-41"}}
    end

    test "a session that named nothing still takes its branch's GitHub issue" do
      s = session("s1", repo: "acme/shop", branch: "feature/checkout")
      {facts, _} = SessionIssues.match([s], %{}, @now)
      assert facts.sessions == %{"s1" => %{repo: "acme/shop", number: 77}}
    end
  end

  describe "many sessions from a collector" do
    # How many issues or branches each question to Linear held.
    defp sizes(c, kind) do
      for {q, vars} <- questions(c),
          q =~ kind,
          do: Enum.count(vars, fn {k, _} -> k =~ ~r/^[tb]\d+$/ end)
    end

    test "never make one question to Linear larger than 25 issues, and this machine's come first",
         c do
      mine = named("mine", 41, local?: true)
      theirs = for n <- 100..160, do: named("stream:far:#{n}", n)

      {facts, _} = SessionIssues.match(theirs ++ [mine], %{}, @now)

      assert facts.sessions["mine"] == %{linear: "VIT-41"}
      assert sizes(c, "i0: issues(") != []
      assert Enum.max(sizes(c, "i0: issues(")) <= 25

      # This machine's issue is in a question with none of the collector's
      # beyond what fills it, and that question is asked.
      assert Enum.any?(questions(c), fn {_, vars} -> vars["t0"] == "VIT" and vars["n0"] == 41 end)
    end

    test "never make one question to Linear larger than 25 branches", c do
      theirs = for n <- 1..60, do: session("stream:far:#{n}", branch: "feature/far-#{n}")
      SessionIssues.match(theirs, %{}, @now)

      assert sizes(c, "issueVcsBranchSearch") != []
      assert Enum.max(sizes(c, "issueVcsBranchSearch")) <= 25
    end

    test "a branch name that could not be a git branch is never sent to Linear", c do
      odd = ["feature/a b", "feature/\n$b0", "feature/" <> <<0>>, "x\ty", <<255, 254>>]
      sessions = for {b, i} <- Enum.with_index(odd), do: session("stream:far:#{i}", branch: b)
      SessionIssues.match(sessions, %{}, @now)

      assert sizes(c, "issueVcsBranchSearch") == []
    end
  end

  describe "the 1Password address in a settings file" do
    alias Wallboard.Settings

    defp linear(section),
      do: Settings.normalize(Settings.merge(Settings.defaults(), %{linear: section})).linear

    test "is kept when it is an op:// address" do
      ref = "op://Private/Linear/credential"
      assert linear(%{api_key_ref: ref}) == %{api_key: nil, api_key_ref: ref}
      assert linear(%{api_key_ref: "  " <> ref <> " "}).api_key_ref == ref
    end

    test "is dropped when it is anything else, a key pasted there above all" do
      for wrong <- ["lin_api_PLANTEDKEY", "https://linear.app", 42, "", %{a: 1}] do
        assert linear(%{api_key_ref: wrong, api_key: "x", other: 1}) ==
                 %{api_key: nil, api_key_ref: nil},
               inspect(wrong)
      end
    end
  end
end
