defmodule Wallboard.CodexTest do
  use ExUnit.Case, async: false

  alias Wallboard.Archive.{CodexTranscript, Collector, Transcript}
  alias Wallboard.Store

  @id "01a0c9db-3044-75f0-99fe-345bf658a60b"

  # Lines shaped like codex-cli 0.155.1 writes them, with made-up content.
  defp lines do
    [
      %{
        type: "session_meta",
        payload: %{
          id: @id,
          cwd: "/Users/r/projects/app",
          originator: "Claude Code",
          cli_version: "0.155.1",
          source: "vscode",
          git: %{branch: "main"}
        }
      },
      %{type: "turn_context", payload: %{model: "gpt-6-astra", effort: "xhigh"}},
      %{type: "event_msg", payload: %{type: "task_started"}},
      %{
        type: "event_msg",
        payload: %{
          type: "item_completed",
          item: %{type: "UserMessage", content: [%{type: "text", text: "fix the flaky test"}]}
        }
      },
      %{
        type: "token_usage_record",
        payload: %{
          response_id: "resp_1",
          usage: %{input_tokens: 20_000, cached_input_tokens: 15_000, output_tokens: 400}
        }
      },
      %{
        type: "token_usage_record",
        payload: %{
          response_id: "resp_2",
          usage: %{input_tokens: 30_000, cached_input_tokens: 29_000, output_tokens: 100}
        }
      },
      %{
        type: "event_msg",
        payload: %{
          type: "token_count",
          info: %{last_token_usage: %{input_tokens: 30_000}, model_context_window: 258_400},
          rate_limits: %{primary: %{used_percent: 70.0}}
        }
      },
      %{
        type: "event_msg",
        payload: %{
          type: "item_completed",
          item: %{
            type: "CommandExecution",
            command: ["/bin/zsh", "-lc", "mix test"],
            status: "failed"
          }
        }
      },
      %{
        type: "event_msg",
        payload: %{
          type: "item_completed",
          item: %{
            type: "FileChange",
            status: "completed",
            changes: %{
              "/Users/r/projects/app/a.ex" => %{
                type: "update",
                unified_diff: "@@ -1,2 +1,3 @@\n-old\n+new\n+more\n same"
              },
              "/Users/r/projects/app/b.ex" => %{type: "add", content: "one\ntwo\n"}
            }
          }
        }
      },
      %{
        type: "event_msg",
        payload: %{
          type: "item_completed",
          item: %{
            type: "McpToolCall",
            server: "korium",
            tool: "agent_search",
            status: "completed",
            result: %{content: [%{type: "text", text: ~s({"result_count":2})}]}
          }
        }
      },
      %{type: "event_msg", payload: %{type: "task_complete", duration_ms: 36_150}}
    ]
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {l, i} ->
      Jason.encode!(
        Map.put(l, :timestamp, "2026-09-29T13:00:#{String.pad_leading("#{i}", 2, "0")}Z")
      )
    end)
  end

  test "a Codex session file reads into the same tally as a Claude one" do
    t = CodexTranscript.read_lines(lines())

    assert t.thread_id == @id
    assert {t.model, t.effort, t.originator} == {"gpt-6-astra", "xhigh", "Claude Code"}
    assert {t.turns, t.turn_ms, t.prompts, t.running} == {1, 36_150, 1, false}
    assert t.first_prompt == "fix the flaky test"

    # Cached input is part of Codex's input count; fresh input is the rest.
    assert t.requests["resp_1"].input == 5_000
    assert t.requests["resp_1"].cache_read == 15_000
    assert map_size(t.requests) == 2

    assert {t.added, t.removed, MapSet.size(t.files)} == {4, 1, 2}
    assert t.tools["shell"] == %{calls: 1, errors: 1}
    assert {t.korium.searches, t.korium.search_hits} == {1, 1}
    assert {t.last_context, t.context_window, t.plan_used} == {30_000, 258_400, 70.0}
  end

  test "a turn that started and has not finished counts as running" do
    t =
      CodexTranscript.read_lines(
        lines()
        |> String.split("\n")
        |> Enum.drop(-1)
        |> Enum.join("\n")
      )

    assert t.running
  end

  test "the thread id comes from a session file's name" do
    assert CodexTranscript.id_from_path("/x/rollout-2026-09-22T12-03-00-#{@id}.jsonl") == @id
    assert CodexTranscript.id_from_path("/x/#{@id}.jsonl") == @id
  end

  test "a Codex session saves as a codex row, its helper agents as subagents" do
    start_supervised!({Store, path: ":memory:"})
    dir = Path.join(System.tmp_dir!(), "codex-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    main = Path.join(dir, "rollout-2026-09-29T13-00-00-#{@id}.jsonl")
    File.write!(main, lines() <> "\n")

    sub = Path.join(dir, "rollout-2026-09-29T13-01-00-01a0c648-422d-7230-af67-c78769e243f6.jsonl")
    File.write!(sub, lines() <> "\n")

    ctx = %{
      prices: %{},
      machine: "papa",
      account: "codex",
      title: "Fix the flaky test",
      size: 1,
      mtime: 1,
      now: 1
    }

    assert Collector.save_codex(main, [{sub, "Halley"}], ctx)

    [row] = Store.list_sessions()

    assert {row.tool, row.session_id, row.title, row.account} ==
             {"codex", @id, "Fix the flaky test", "codex"}

    assert {row.requests, row.subagents, row.context_window} == {4, 1, 258_400}
    File.rm_rf!(dir)
  end

  test "Claude sessions still save as claude rows" do
    t = Transcript.empty()

    ctx = %{
      prices: %{},
      machine: "papa",
      session_id: "s",
      account: "main",
      path: "p",
      size: 1,
      mtime: 1,
      now: 1
    }

    {session, _} = Transcript.to_record(t, [], ctx)
    assert session.tool == "claude"
  end

  test "Trends keeps each tool's counts apart and shares Korium's" do
    alias Wallboard.Archive.Trends

    claude = Trends.by_tool(%{tool: "claude", sessions: 3, tokens: 900, ks: 2})
    codex = Trends.by_tool(%{tool: "codex", sessions: 1, tokens: 100, ks: 5})
    day = Trends.merge([claude, codex])

    assert {day.sessions, day.codex_sessions} == {3, 1}
    assert {day.tokens, day.codex_tokens} == {900, 100}
    assert day.ks == 7
  end

  test "tokens per 1,000 lines added, and nothing when no lines were added" do
    alias Wallboard.Archive.Trends
    assert Trends.per_kline(3_000_000, 1_500) == 2_000_000.0
    assert Trends.per_kline(3_000_000, 0) == nil
  end

  test "GitHub says it is loading until its runs and their job times are saved" do
    alias Wallboard.Archive.Trends
    start_supervised!({Store, path: ":memory:"})
    settings = %{github: %{repo: "o/r"}}

    assert Trends.github_loading(settings) == "Loading…"

    Store.put_meta("github_backfill:o/r", "2026-09-29")
    Store.put_runs([%{repo: "o/r", run_id: 1, attempt: 1, status: "completed"}])
    assert Trends.github_loading(settings) == "Loading job times, 1 run to go"

    Store.put_jobs("o/r", 1, [])
    assert Trends.github_loading(settings) == nil
  end
end
