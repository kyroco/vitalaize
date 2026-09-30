defmodule Wallboard.CodexUploadTest do
  use ExUnit.Case, async: false

  alias Wallboard.Archive.Ingest
  alias Wallboard.Store

  @main "01a0c9db-3044-75f0-99fe-345bf658a60b"
  @helper "01a0c9e3-b1ca-7bc3-807a-7505e0b45634"
  @other "01a0c648-422d-7230-af67-c78769e243f6"

  # Lines shaped like codex-cli 0.155.1 writes them, with made-up content.
  defp meta(id, parent) do
    source =
      if parent,
        do: %{
          subagent: %{
            thread_spawn: %{parent_thread_id: parent, depth: 1, agent_nickname: "Aquinas"}
          }
        },
        else: "vscode"

    %{
      timestamp: "2026-09-29T13:00:00Z",
      type: "session_meta",
      payload: %{id: id, cwd: "/Users/r/app", originator: "Codex Desktop", source: source}
    }
  end

  defp session(id, parent \\ nil, extra \\ []) do
    [
      meta(id, parent),
      %{type: "turn_context", payload: %{model: "gpt-6-astra", effort: "high"}},
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
          response_id: "resp_#{id}",
          usage: %{input_tokens: 20_000, cached_input_tokens: 15_000, output_tokens: 400}
        }
      }
      | extra
    ]
    |> Enum.map_join("\n", &Jason.encode!/1)
    |> Kernel.<>("\n")
  end

  defp started(kid) do
    %{
      type: "event_msg",
      payload: %{
        type: "item_completed",
        item: %{type: "SubAgentActivity", kind: "started", agent_thread_id: kid}
      }
    }
  end

  defp name(id, time \\ "2026-09-29T13-00-00"), do: "rollout-#{time}-#{id}.jsonl"

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "codex-upload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "an upload holds one Codex session, its own helpers and its index lines, nothing else" do
    main = {name(@main), session(@main)}
    helper = {name(@helper), session(@helper, @main)}
    index = {"session_index.jsonl", ~s({"id":"#{@main}","thread_name":"Fix it"}\n)}

    assert {:ok, up} = Ingest.sort_codex_files([main, helper, index])
    assert up.id == @main
    assert [{_, _, "Aquinas"}] = up.helpers
    assert up.title == "Fix it"

    assert {:error, _} = Ingest.sort_codex_files([main, {"../" <> name(@helper), "x"}])
    assert {:error, _} = Ingest.sort_codex_files([main, {"sessions/" <> name(@helper), "x"}])
    assert {:error, _} = Ingest.sort_codex_files([main, {"notes.txt", "x"}])
    assert {:error, _} = Ingest.sort_codex_files([main, index, index])
    # A helper of another session, a second main, and a helper alone.
    assert {:error, _} =
             Ingest.sort_codex_files([main, {name(@helper), session(@helper, @other)}])

    assert {:error, _} = Ingest.sort_codex_files([main, {name(@other), session(@other)}])
    assert {:error, _} = Ingest.sort_codex_files([helper])
    # A file whose name and contents disagree, and one that is not Codex's.
    assert {:error, _} = Ingest.sort_codex_files([{name(@other), session(@main)}])
    assert {:error, _} = Ingest.sort_codex_files([{name(@main), ~s({"type":"user"}\n)}])
  end

  describe "the Codex upload script" do
    setup do
      dir = tmp_dir()
      home = Path.join(dir, ".codex")
      day1 = Path.join([home, "sessions", "2026", "09", "29"])
      day2 = Path.join([home, "sessions", "2026", "09", "30"])
      File.mkdir_p!(day1)
      File.mkdir_p!(day2)

      main = Path.join(day1, name(@main))
      File.write!(main, session(@main, nil, [started(@helper), started(@other)]))
      # The helper started the next day, so its file is in another folder.
      helper = Path.join(day2, name(@helper, "2026-09-30T00-01-00"))
      File.write!(helper, session(@helper, @main))
      # Named by the main session, but started by another one: left out.
      File.write!(Path.join(day2, name(@other)), session(@other, @helper))

      File.write!(Path.join(home, "session_index.jsonl"), """
      {"id":"#{@other}","thread_name":"Something else"}
      {"id":"#{@main}","thread_name":"First name"}
      {"id":"#{@main}","thread_name":"Fix the flaky test"}
      """)

      # A curl that keeps what it was asked to send instead of sending it.
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)
      out = Path.join(dir, "out")

      File.write!(Path.join(bin, "curl"), """
      #!/bin/sh
      for a in "$@"; do
        case "$a" in
          @*) cp "${a#@}" "#{out}.tgz" ;;
          http*) printf '%s' "$a" > "#{out}.url" ;;
        esac
      done
      """)

      File.chmod!(Path.join(bin, "curl"), 0o755)
      script = Path.join(dir, "upload.sh")
      File.write!(script, Ingest.codex_upload_script("http://hub.test:4747", "k3y"))

      %{dir: dir, bin: bin, out: out, script: script, main: main, helper: helper}
    end

    defp run(ctx, path, event) do
      File.rm(ctx.out <> ".tgz")
      # Pretty-printed, so the script does not depend on how Codex spaces it.
      input =
        Jason.encode!(
          %{session_id: @main, transcript_path: path, hook_event_name: event, cwd: "/x"},
          pretty: true
        )

      input_file = Path.join(ctx.dir, "input.json")
      File.write!(input_file, input)

      System.cmd("sh", ["-c", "sh \"$0\" < \"$1\"", ctx.script, input_file],
        env: [{"PATH", ctx.bin <> ":" <> System.get_env("PATH")}, {"TMPDIR", ctx.dir}]
      )
    end

    test "sends the session, its helpers and its title, and the hub saves them", ctx do
      assert {"{}\n", 0} = run(ctx, ctx.main, "Stop")

      url = File.read!(ctx.out <> ".url")
      assert url =~ "http://hub.test:4747/ingest/transcript?tool=codex&machine="
      assert String.ends_with?(url, "&account=.codex")

      {:ok, files} = :erl_tar.extract(ctx.out <> ".tgz", [:compressed, :memory])

      assert files |> Enum.map(&to_string(elem(&1, 0))) |> Enum.sort() ==
               Enum.sort([
                 name(@main),
                 name(@helper, "2026-09-30T00-01-00"),
                 "session_index.jsonl"
               ])

      start_supervised!({Store, path: ":memory:"})

      settings = %{
        archive: %{path: Path.join(ctx.dir, "hub/wallboard.db")},
        usage: %{prices: %{}}
      }

      tar = File.read!(ctx.out <> ".tgz")
      assert {:ok, @main} = Ingest.receive_codex(tar, "probe-mac", ".codex", settings)
      [row] = Store.list_sessions()

      assert {row.tool, row.session_id, row.machine, row.account, row.title, row.subagents} ==
               {"codex", @main, "probe-mac", nil, "Fix the flaky test", 1}

      assert File.exists?(Path.join([ctx.dir, "hub/inbox/probe-mac/.codex", name(@main)]))
    end

    test "sends at most once a minute while running, and always at the end", ctx do
      run(ctx, ctx.main, "Stop")
      assert File.exists?(ctx.out <> ".tgz")

      run(ctx, ctx.main, "Stop")
      refute File.exists?(ctx.out <> ".tgz")

      run(ctx, ctx.main, "SessionEnd")
      assert File.exists?(ctx.out <> ".tgz")
    end

    test "a helper agent's own stop sends nothing", ctx do
      assert {"{}\n", 0} = run(ctx, ctx.helper, "Stop")
      refute File.exists?(ctx.out <> ".tgz")
    end
  end

  describe "the connect command" do
    setup do
      dir = tmp_dir()
      claude = Path.join(dir, ".claude")
      codex = Path.join(dir, ".codex")
      File.mkdir_p!(claude)
      script = Path.join(dir, "connect.sh")
      File.write!(script, Ingest.install_script("http://hub.test:4747", "k3y"))
      %{dir: dir, claude: claude, codex: codex, script: script}
    end

    defp connect(ctx) do
      System.cmd("sh", [ctx.script],
        env: [{"CLAUDE_CONFIG_DIR", ctx.claude}, {"CODEX_HOME", ctx.codex}],
        stderr_to_stdout: true
      )
    end

    defp commands(file, event) do
      file
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["hooks", event])
      |> Enum.flat_map(& &1["hooks"])
      |> Enum.map(& &1["command"])
    end

    test "hooks up Codex next to Claude, keeps its own hooks, and says to trust them", ctx do
      File.mkdir_p!(ctx.codex)
      mine = %{"hooks" => [%{"type" => "command", "command" => "python3 mine.py"}]}
      File.write!(Path.join(ctx.codex, "hooks.json"), Jason.encode!(%{hooks: %{Stop: [mine]}}))

      assert {out, 0} = connect(ctx)
      assert out =~ "/hooks in Codex"

      upload = Path.join(ctx.codex, "wallboard-upload.sh")
      hooks = Path.join(ctx.codex, "hooks.json")
      assert commands(hooks, "Stop") == ["python3 mine.py", upload]
      assert commands(hooks, "SessionEnd") == [upload]
      assert File.read!(upload) == Ingest.codex_upload_script("http://hub.test:4747", "k3y")
      assert File.exists?(hooks <> ".before-wallboard")

      claude_upload = Path.join(ctx.claude, "wallboard-upload.sh")
      assert commands(Path.join(ctx.claude, "settings.json"), "Stop") == [claude_upload]

      # Connecting again adds nothing twice.
      assert {_, 0} = connect(ctx)
      assert commands(hooks, "Stop") == ["python3 mine.py", upload]
    end

    test "leaves Codex alone on a machine without it", ctx do
      assert {out, 0} = connect(ctx)
      refute out =~ "Codex"
      refute File.exists?(ctx.codex)
    end
  end
end
