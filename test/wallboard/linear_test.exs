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
end
