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

  describe "needs you, from the hook" do
    alias Wallboard.Sources.Codex

    # A turn that started at 13:00:00 and is still running.
    defp running_tally do
      CodexTranscript.read_lines(
        lines()
        |> String.split("\n")
        |> Enum.drop(-1)
        |> Enum.join("\n")
      )
    end

    defp at(time), do: DateTime.to_unix(~U[2026-09-29 13:00:00Z]) + time

    # The fixture was started by Claude; these were started by a person.
    defp by_person(t), do: %{t | originator: "Codex Desktop"}

    test "a message that ends on a question is one" do
      assert Codex.question("Done.\n\nWhich color do you like?") == "Which color do you like?"
      assert Codex.question("Should I open the PR?**\n") == "Should I open the PR?**"
      assert Codex.question(~s[Ship it now ("yes" or "no")?]) =~ "Ship it now"

      assert Codex.question("Is this right?\nI think\nit is?") ==
               "Is this right? I think it is?"

      # A question earlier in the message, then a finished answer, is not.
      assert Codex.question("Why did it fail?\n\nThe test had a typo; fixed.") == nil
      assert Codex.question("All green.") == nil
      assert Codex.question(nil) == nil
    end

    test "an approval request needs you, and says what it wants to run" do
      t = running_tally()
      mark = %{"hook_event_name" => "PermissionRequest", "at" => at(30)}

      assert Codex.waiting(Map.put(mark, "tool_input", %{"command" => "git push"}), t) ==
               "Asks to run git"

      assert Codex.waiting(
               Map.put(mark, "tool_input", %{"command" => ["/bin/zsh", "-lc", "rm -r x"]}),
               t
             ) == "Asks to run rm"

      assert Codex.waiting(Map.put(mark, "tool_name", "mcp__linear__save_issue"), t) ==
               "Asks for your approval to use mcp__linear__save_issue"

      assert Codex.waiting(mark, t) == "Asks for your approval"

      # Odd arguments are left out rather than failing the whole poll.
      assert Codex.waiting(Map.put(mark, "tool_input", %{"command" => ["ls", %{"x" => 1}]}), t) ==
               "Asks to run ls"

      # Only the program shows: the rest of a command can hold a secret.
      for {command, name} <- [
            {~s[curl -H "Authorization: Bearer sk-live-1" https://x], "curl"},
            {"TOKEN=abc ./bin/deploy.sh prod", "deploy.sh"},
            {~s[PGPASSWORD="hunter2 horse" psql], "psql"},
            {["bash", "-lc", ~s[API_KEY="a b" deploy]], "deploy"},
            {["/bin/zsh", "-lc", "rm -r x"], "rm"},
            {["bash", "-lc", "set\nAPI_KEY=sk-live-abc\ndeploy prod"], "set"},
            {["bash", "-lc", "tee x <<'EOF'\nDon't stop\nEOF"], "tee"},
            {~s[bash -c "psql postgres://u:pw@h"], "psql"},
            {"grep -c x file", "grep"}
          ] do
        why = Codex.waiting(Map.put(mark, "tool_input", %{"command" => command}), t)
        assert why == "Asks to run " <> name
        refute why =~ "sk-live" or why =~ "pw@" or why =~ "horse" or why =~ " b"
      end

      assert Codex.waiting(Map.put(mark, "tool_input", %{"command" => "  "}), t) ==
               "Asks for your approval"
    end

    test "an approval request is over once it ran, or its turn ends" do
      t = running_tally()

      ask = %{
        "hook_event_name" => "PermissionRequest",
        "turn_id" => "t1",
        "tool_input" => %{"command" => "mix test"},
        "at" => at(20)
      }

      assert Codex.waiting(ask, t, []) == "Asks to run mix"

      # The hook keeps the agent's latest call only, so its next call (the
      # command ran, the turn ended, the person typed) takes the request's
      # place, and that is not waiting on you.
      for event <- ["PostToolUse", "UserPromptSubmit", "Interrupt", "SessionEnd"] do
        assert Codex.waiting(%{ask | "hook_event_name" => event, "at" => at(90)}, t, []) == nil
      end

      # Turned down and the turn ended, per the session's own file.
      assert Codex.waiting(ask, %{t | running: false}, []) == nil
    end

    test "a helper's approval request is over when the person interrupts or quits" do
      t = running_tally()
      ask = %{"hook_event_name" => "PermissionRequest", "agent_id" => "a1", "at" => at(20)}
      assert Codex.waiting(ask, t, []) == "Asks for your approval"

      # An interrupt from before the request is older news.
      assert Codex.waiting(ask, t, [%{"hook_event_name" => "Interrupt", "at" => at(20)}])

      for event <- ["Interrupt", "SessionEnd"] do
        assert Codex.waiting(ask, t, [%{"hook_event_name" => event, "at" => at(25)}]) == nil
      end

      # The session's own turn ending says nothing about the helper.
      assert Codex.waiting(ask, t, [%{"hook_event_name" => "Stop", "at" => at(25)}]) ==
               "Asks for your approval"
    end

    test "a command splits like a shell's, and never fails" do
      assert Codex.shell_words(~s[PGPASSWORD="a b" psql -c 'x y']) ==
               ["PGPASSWORD=a b", "psql", "-c", "x y"]

      assert Codex.shell_words("set\nAPI_KEY=k\tdeploy prod") ==
               ["set", "API_KEY=k", "deploy", "prod"]

      assert Codex.shell_words("cd x && make; ls|wc") == ["cd", "x", "make", "ls", "wc"]
      assert Codex.shell_words("'a\\' b") == ["a\\", "b"]
      assert Codex.shell_words("tee x <<'EOF'\nDon't stop\nEOF") |> hd() == "tee"
      assert Codex.shell_words(~s[echo "unclosed]) == ["echo", "unclosed"]
      assert Codex.shell_words(<<"ls ", 0xFF, " x\\">>) |> hd() == "ls"
      assert Codex.shell_words("") == []
    end

    test "a turn that ended on a question needs you; any later hook call clears it" do
      t = by_person(CodexTranscript.read_lines(lines()))
      stop = %{"hook_event_name" => "Stop", "at" => at(30)}

      assert Codex.waiting(Map.put(stop, "last_assistant_message", "Which one?"), t) ==
               "Which one?"

      assert Codex.waiting(Map.put(stop, "last_assistant_message", "Done."), t) == nil

      for event <- ["UserPromptSubmit", "PostToolUse", "SessionEnd"] do
        assert Codex.waiting(%{"hook_event_name" => event, "at" => at(30)}, t) == nil
      end

      assert Codex.waiting(nil, t) == nil
    end

    test "a question from a session run by a script or by Claude does not count" do
      stop = %{"hook_event_name" => "Stop", "at" => at(30), "last_assistant_message" => "Ok?"}
      t = CodexTranscript.read_lines(lines())

      assert Codex.waiting(stop, t) == nil
      assert Codex.waiting(stop, %{t | originator: "codex_exec"}) == nil
      assert Codex.waiting(stop, by_person(t)) == "Ok?"
    end

    test "a hook call from before the current turn started is out of date" do
      t = running_tally()

      mark = %{
        "hook_event_name" => "Stop",
        "last_assistant_message" => "Which one?",
        "at" => at(-60)
      }

      assert Codex.waiting(mark, t) == nil
    end

    test "the card shows needs you, why, and since when" do
      t = Map.merge(running_tally(), %{mtime: at(40), path: "p"})

      mark = %{
        "hook_event_name" => "PermissionRequest",
        "tool_input" => %{"command" => "git push"},
        "at" => at(30)
      }

      card = Codex.card(t, [], "Fix it", at(45), %{@id => [mark]})
      assert {card.status, card.why} == {:needs, "Asks to run git"}
      assert card.since == DateTime.from_unix!(at(30))
      assert card.waiting_since == card.since

      plain = Codex.card(t, [], "Fix it", at(45))
      assert {plain.status, plain.why, plain.waiting_since} == {:working, nil, nil}

      # A helper's call, under the session's id, does not replace the
      # session's own approval request.
      done = %{"hook_event_name" => "PostToolUse", "agent_id" => "a1", "at" => at(31)}
      card = Codex.card(t, [], "Fix it", at(45), %{@id => [mark, done]})
      assert card.status == :needs

      # A helper asking for approval shows on the session that started it,
      # whether its calls come under the session's id or its own.
      kid = Map.merge(running_tally(), %{thread_id: "kid", parent_id: @id, mtime: at(40)})
      helper = Map.put(mark, "agent_id", "a1")
      card = Codex.card(t, [], "Fix it", at(45), %{@id => [helper]})
      assert {card.status, card.why} == {:needs, "Asks to run git"}

      # The session's own activity says nothing about the helper: a later
      # line, a finished turn or a new turn in the session leave it waiting.
      busy = %{t | last_at: DateTime.from_unix!(at(40))}
      assert Codex.waiting(helper, busy) == "Asks to run git"
      assert Codex.waiting(helper, %{t | running: false}) == "Asks to run git"
      assert Codex.waiting(helper, %{t | turn_started_at: DateTime.from_unix!(at(35))})

      card = Codex.card(t, [kid], "Fix it", at(45), %{"kid" => [mark]})
      assert {card.status, card.why} == {:needs, "Asks to run git"}

      # Its questions go to that session, not to you.
      question = %{"hook_event_name" => "Stop", "last_assistant_message" => "?", "at" => at(30)}
      done_kid = %{by_person(kid) | running: false}
      card = Codex.card(t, [done_kid], "Fix it", at(45), %{"kid" => [question]})
      assert card.status == :working

      card =
        Codex.card(by_person(t), [], "Fix it", at(45), %{
          @id => [Map.put(question, "agent_id", "a1")]
        })

      assert card.status == :working
    end

    test "a turn that another hook sent on does not count until it ends" do
      stop = %{"hook_event_name" => "Stop", "at" => at(30), "last_assistant_message" => "Ok?"}
      assert Codex.waiting(stop, by_person(running_tally())) == nil
    end

    test "only a session that newly needs you is texted, and none on the first poll" do
      a = %{key: "codex:a", status: :needs}
      b = %{key: "codex:b", status: :needs}
      c = %{key: "codex:c", status: :idle}

      {newly, keys} = Codex.newly_needing([a, c], nil)
      assert newly == []
      assert keys == MapSet.new(["codex:a"])

      {newly, keys} = Codex.newly_needing([a, b, c], keys)
      assert newly == [b]
      assert keys == MapSet.new(["codex:a", "codex:b"])
    end

    test "the board keeps the hook in place and reads its calls from each Codex folder" do
      dir = Wallboard.Fixtures.tmp_path("codex-hook")
      marks = Path.join(dir, "vitalaize")
      File.mkdir_p!(marks)
      on_exit(fn -> File.rm_rf!(dir) end)

      now = DateTime.utc_now()
      now_s = DateTime.to_unix(now)

      File.write!(
        Path.join(marks, "#{@id}.json"),
        Jason.encode!(%{session_id: @id, hook_event_name: "Stop", last_assistant_message: "Ok?"})
      )

      stale = Path.join(marks, "old.json")
      File.write!(stale, Jason.encode!(%{session_id: "old", hook_event_name: "Stop"}))
      File.touch!(stale, now_s - 3 * 3600)

      gone = Path.join(marks, "gone.json")
      File.write!(gone, Jason.encode!(%{session_id: "gone", hook_event_name: "Stop"}))
      File.touch!(gone, now_s - 8 * 24 * 3600)

      File.write!(Path.join(marks, "bad.json"), "not json")

      # A copy the hook never finished, because Codex stopped it.
      half = Path.join(marks, ".hook.AbC123")
      File.write!(half, "{")
      File.touch!(half, now_s - 2 * 3600)

      settings = %{codex: %{enabled: true, dirs: [dir], idle_minutes: 120}, alerts: %{phone: nil}}

      # An approval request from six hours ago is still out: Codex writes
      # nothing while it waits. One from 13 hours ago is let go.
      asking = Path.join(marks, "asking.json")

      File.write!(
        asking,
        Jason.encode!(%{session_id: "asking", hook_event_name: "PermissionRequest"})
      )

      File.touch!(asking, now_s - 6 * 3600)

      too_old = Path.join(marks, "too-old.json")

      File.write!(
        too_old,
        Jason.encode!(%{session_id: "too-old", hook_event_name: "PermissionRequest"})
      )

      File.touch!(too_old, now_s - 13 * 3600)

      # A helper's calls sit beside the session's own.
      File.write!(
        Path.join(marks, "#{@id}.a1.json"),
        Jason.encode!(%{session_id: @id, agent_id: "a1", hook_event_name: "PostToolUse"})
      )

      {found, read} = Codex.marks(settings, now)
      assert Enum.sort(Map.keys(found)) == Enum.sort([@id, "asking"])
      assert Codex.asking(found) == MapSet.new(["asking"])
      [own] = Enum.reject(found[@id], & &1["agent_id"])
      assert own["last_assistant_message"] == "Ok?"
      assert is_integer(own["at"])
      assert length(found[@id]) == 2
      assert File.exists?(stale)
      refute File.exists?(gone)
      refute File.exists?(half)

      # A file already read is not read again until it changes.
      path = Path.join(marks, "#{@id}.json")
      {stamp, _} = read[path]

      {again, _} =
        Codex.marks(settings, now, %{
          read
          | path => {stamp, %{"session_id" => "kept", "at" => now_s}}
        })

      assert Map.has_key?(again, "kept")

      # A poll puts the shipped hook next to the calls, and puts it back.
      {:ok, %{sessions: []}, memory} = Codex.poll(settings, nil, nil, now)
      hook = Path.join(marks, "hook.sh")
      assert File.read!(hook) == Codex.hook_script()
      File.rm!(hook)
      Codex.poll(settings, nil, memory, now)
      assert File.read!(hook) == Codex.hook_script()

      # A folder that is not there is not made.
      missing = Path.join(dir, "no-codex-here")
      Codex.poll(put_in(settings.codex.dirs, [missing]), nil, nil, now)
      refute File.exists?(missing)
    end
  end

  test "the thread id comes from a session file's name" do
    assert CodexTranscript.id_from_path("/x/rollout-2026-09-22T12-03-00-#{@id}.jsonl") == @id
    assert CodexTranscript.id_from_path("/x/#{@id}.jsonl") == @id
  end

  test "a Codex session saves as a codex row, its helper agents as subagents" do
    start_supervised!({Store, path: ":memory:"})
    dir = Wallboard.Fixtures.tmp_path("codex-test")
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
