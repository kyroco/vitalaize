defmodule Wallboard.ArchiveTest do
  use ExUnit.Case, async: false

  alias Wallboard.Archive.{StatusRecorder, Transcript}
  alias Wallboard.Store
  alias WallboardWeb.BoardLive

  # Lines shaped like real transcript lines (checked 2026-09-29), trimmed to
  # the fields the reader uses.
  @lines [
    ~s({"type":"custom-title","customTitle":"Fix the board"}),
    ~s({"type":"user","timestamp":"2026-09-29T13:00:00Z","cwd":"/Users/r/wallboard","gitBranch":"main","version":"2.1.284","message":{"role":"user","content":"Why does the prod tile say behind?"}}),
    ~s({"type":"user","isMeta":true,"timestamp":"2026-09-29T13:00:01Z","message":{"role":"user","content":"<system-reminder>not a prompt</system-reminder>"}}),
    ~s({"type":"assistant","requestId":"req_1","effort":"high","timestamp":"2026-09-29T13:00:05Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens":50},"content":[{"type":"tool_use","id":"t1","name":"mcp__claude_ai_korium__agent_search","input":{"query":"prod tile"}},{"type":"tool_use","id":"t2","name":"mcp__claude_ai_korium__code_locate","input":{"query":"prod_tile"}}]}}),
    ~s({"type":"user","timestamp":"2026-09-29T13:00:06Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"{\\"result_count\\":3,\\"thoughts\\":[]}"}]},{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"{\\"results\\":[]}"}]}]}}),
    ~s({"type":"assistant","requestId":"req_2","timestamp":"2026-09-29T13:00:10Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":5,"cache_read_input_tokens":1500,"cache_creation_input_tokens":0,"output_tokens":20},"content":[{"type":"tool_use","id":"t3","name":"mcp__korium__agent_capture","input":{}},{"type":"tool_use","id":"t4","name":"mcp__korium__agent_capture","input":{}},{"type":"tool_use","id":"t5","name":"Edit","input":{"file_path":"/Users/r/wallboard/lib/a.ex"}}]}}),
    ~s({"type":"user","timestamp":"2026-09-29T13:00:11Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"{\\"queued\\":true}"},{"type":"tool_result","tool_use_id":"t4","is_error":true,"content":"PreToolUse:mcp__korium__agent_capture hook error: Blocked: this write copies words"}]}}),
    ~s({"type":"user","timestamp":"2026-09-29T13:00:12Z","toolUseResult":{"structuredPatch":[{"lines":["+a","+b","-c"]}]},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t5","content":"ok"}]}}),
    ~s({"type":"assistant","requestId":"req_2","timestamp":"2026-09-29T13:00:13Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":5,"cache_read_input_tokens":1500,"cache_creation_input_tokens":0,"output_tokens":20},"content":[{"type":"text","text":"same request, second block"}]}}),
    ~s({"type":"system","subtype":"api_error","retryAttempt":1,"timestamp":"2026-09-29T13:00:14Z"}),
    ~s({"type":"system","subtype":"compact_boundary","timestamp":"2026-09-29T13:00:15Z"}),
    ~s({"type":"system","subtype":"turn_duration","durationMs":15000,"timestamp":"2026-09-29T13:00:16Z"}),
    ~s({"type":"pr-link","prNumber":905,"prUrl":"https://github.com/acme/wallboard/pull/905","prRepository":"acme/wallboard","timestamp":"2026-09-29T13:00:17Z"}),
    ~s({"type":"cost-state","totalAPIDuration":9000,"totalToolDuration":2000}),
    ~s({"type":"last-prompt","lastPrompt":"Why does the prod tile say behind?"})
  ]

  defp tally, do: Transcript.read_lines(Enum.join(@lines, "\n"))

  test "keeps every branch a session worked on, in the order first seen" do
    lines = [
      ~s({"type":"user","timestamp":"2026-09-29T13:00:00Z","gitBranch":"worktree-41","message":{"role":"user","content":"go"}}),
      ~s({"type":"user","timestamp":"2026-09-29T13:01:00Z","gitBranch":"robert/41-sign-in","message":{"role":"user","content":"push"}}),
      ~s({"type":"user","timestamp":"2026-09-29T13:02:00Z","gitBranch":"main","message":{"role":"user","content":"back"}}),
      ~s({"type":"user","timestamp":"2026-09-29T13:03:00Z","gitBranch":"robert/41-sign-in","message":{"role":"user","content":"again"}})
    ]

    ctx = %{
      machine: "m",
      session_id: "b",
      account: "main",
      path: "/tmp/b.jsonl",
      size: 1,
      mtime: 1,
      now: 1,
      prices: default_prices()
    }

    {session, _} = Transcript.to_record(Transcript.read_lines(Enum.join(lines, "\n")), [], ctx)

    assert session.git_branch == "robert/41-sign-in"
    assert session.detail.branches == ["worktree-41", "robert/41-sign-in", "main"]
  end

  test "reads prompts, requests once per id, and tool calls" do
    t = tally()
    assert t.prompts == 1
    assert t.first_prompt == "Why does the prod tile say behind?"
    assert map_size(t.requests) == 2
    assert t.tools["Edit"] == %{calls: 1, errors: 0}
    assert t.tools["mcp__korium__agent_capture"] == %{calls: 2, errors: 1}
    assert MapSet.to_list(t.files) == ["/Users/r/wallboard/lib/a.ex"]
    assert {t.added, t.removed} == {2, 1}
    assert {t.api_errors, t.retries, t.compactions, t.turns, t.turn_ms} == {1, 1, 1, 1, 15_000}
    assert t.peak_context == 1505
  end

  test "Korium searches count hits and misses, saves count failures and why" do
    k = tally().korium
    assert {k.searches, k.search_hits} == {1, 1}
    assert {k.code_searches, k.code_hits} == {1, 0}
    assert {k.saves, k.save_errors} == {2, 1}
    assert tally().save_failures == %{"blocked" => 1}
  end

  test "sorts failed saves into blocked, bad input and refused" do
    assert Transcript.save_failure("PreToolUse:x hook error: Blocked: no") == "blocked"
    assert Transcript.save_failure("Blocked: this write goes into a memory") == "blocked"
    assert Transcript.save_failure("<tool_use_error>InputValidationError: x") == "invalid"
    assert Transcript.save_failure("thought_type is required") == "invalid"
    assert Transcript.save_failure("This capture is filed under 'reviewer'") == "refused"
  end

  test "knows a Korium tool from any Korium server name" do
    assert Transcript.korium_tool("mcp__claude_ai_korium__agent_search") == "agent_search"
    assert Transcript.korium_tool("mcp__korium__code_locate") == "code_locate"
    assert Transcript.korium_tool("mcp__claude-in-chrome__computer") == nil
    assert Transcript.korium_tool("Bash") == nil
  end

  test "a status change, and a session leaving, are each recorded once" do
    s = fn id, status -> %{session_id: id, name: id, status: status} end
    {first, last} = StatusRecorder.changes(%{}, [s.("a", :working), s.("b", :idle)])
    assert Enum.sort(first) == [{"a", "a", :working}, {"b", "b", :idle}]

    {again, last} = StatusRecorder.changes(last, [s.("a", :working), s.("b", :idle)])
    assert again == []

    {next, _} = StatusRecorder.changes(last, [s.("a", :needs)])
    assert Enum.sort(next) == [{"a", "a", :needs}, {"b", "b", :gone}]
  end

  test "time waiting on you adds up from the status history" do
    events = [
      %{status: "working", at: 0},
      %{status: "needs", at: 100},
      %{status: "working", at: 160},
      %{status: "needs", at: 200},
      %{status: "idle", at: 230}
    ]

    assert BoardLive.waited_seconds(events) == 90
  end

  test "saves a session with its requests and reads it back" do
    start_supervised!({Store, path: ":memory:"})
    prices = default_prices()

    ctx = %{
      prices: prices,
      machine: "papa",
      session_id: "abc",
      account: "main",
      path: "/tmp/abc.jsonl",
      size: 10,
      mtime: 20,
      now: 30
    }

    {session, requests} = Transcript.to_record(tally(), [], ctx)
    assert session.title == "Fix the board"
    assert session.requests == 2
    assert session.korium_save_errors == 1
    assert :ok = Store.put_session(session, requests)

    assert Store.captured("papa") == %{"/tmp/abc.jsonl" => {10, 20}}
    [row] = Store.list_sessions()
    assert row.session_id == "abc" and row.requests == 2

    Store.put_status("papa", "abc", "Fix the board", :needs, 100)
    Store.put_status("papa", "abc", "Fix the board", :idle, 160)
    got = Store.get_session("papa", "abc")
    assert got.detail["korium_save_failures"] == %{"blocked" => 1}
    assert got.detail["prs"] |> hd() |> Map.get("number") == 905
    assert Enum.map(got.events, & &1.status) == ["needs", "idle"]

    :ok = Store.mark_deleted("papa", ["abc"], 40)
    assert Store.counts().deleted == 1
    assert Store.captured("papa") == %{}
  end

  defp default_prices do
    %{
      "claude-opus-5-5" => %{
        label: "Opus 5.5",
        input: 4.0,
        output: 20.0,
        cache_read: 0.2,
        context: 1_000_000
      }
    }
  end
end
