defmodule Wallboard.RemoteTest do
  use ExUnit.Case, async: false

  alias Wallboard.{Remote, Settings, Store}
  alias Wallboard.Archive.Ingest

  @sid "9f8651f6-634b-47b7-a4db-b27994e624eb"
  @permission "Claude needs your permission to use Bash"

  defp notice(type, message \\ @permission) do
    %{
      "session_id" => @sid,
      "transcript_path" => "/nowhere/#{@sid}.jsonl",
      "cwd" => "/Users/someone/projects/vitalaize",
      "hook_event_name" => "Notification",
      "notification_type" => type,
      "message" => message
    }
  end

  defp hook(event), do: %{"session_id" => @sid, "hook_event_name" => event}

  defp ev(hook, at) do
    {:ok, e} = Remote.event(hook, "laptop", "main", at)
    %{e | received: at}
  end

  describe "what counts as waiting" do
    test "a permission prompt, an MCP form and a subagent's question" do
      for type <-
            ~w(permission_prompt elicitation_dialog elicitation_url_dialog agent_needs_input) do
        assert %{waiting?: true, why: @permission, folder: "vitalaize"} = ev(notice(type), 1)
      end
    end

    test "a question from AskUserQuestion, in its own words" do
      ask = %{
        "session_id" => @sid,
        "hook_event_name" => "PreToolUse",
        "tool_name" => "AskUserQuestion",
        "tool_input" => %{"questions" => [%{"question" => "Which branch should I use?"}]}
      }

      assert %{waiting?: true, why: "Which branch should I use?"} = ev(ask, 1)
    end

    test "Claude's idle reminder and other tools say nothing either way" do
      assert %{waiting?: nil} = ev(notice("idle_prompt"), 1)
      assert %{waiting?: nil} = ev(Map.put(hook("PreToolUse"), "tool_name", "Bash"), 1)
      assert %{waiting?: nil} = ev(hook("SubagentStop"), 1)
    end

    test "a tool finishing, a new prompt or the end of a turn means done waiting" do
      for e <- ~w(PostToolUse UserPromptSubmit Stop SessionEnd),
          do: assert(%{waiting?: false} = ev(hook(e), 1))

      assert %{waiting?: false} = ev(notice("elicitation_complete"), 1)
    end

    test "a status without a usable session id is refused" do
      assert {:error, _} = Remote.event(%{"hook_event_name" => "Stop"}, "m", "a", 1)
      assert {:error, _} = Remote.event(%{"session_id" => "../x"}, "m", "a", 1)
      assert {:error, _} = Remote.event("text", "m", "a", 1)
    end

    test "a long question is cut to fit an alert" do
      assert String.length(ev(notice("permission_prompt", String.duplicate("a", 999)), 1).why) ==
               240
    end
  end

  describe "keeping them" do
    test "a session starts waiting once, moves on, and can wait again" do
      {s, :started} = Remote.apply_event(%{}, ev(notice("permission_prompt"), 1_000), false)
      {s, :same} = Remote.apply_event(s, ev(notice("permission_prompt"), 2_000), false)
      assert [%{status: :needs, why: @permission}] = Remote.board_sessions(s)

      {s, :changed} = Remote.apply_event(s, ev(hook("PostToolUse"), 3_000), false)
      assert Remote.board_sessions(s) == []
      {s, :same} = Remote.apply_event(s, ev(hook("PostToolUse"), 3_500), false)

      {s, :started} = Remote.apply_event(s, ev(notice("permission_prompt"), 4_000), false)
      assert [_] = Remote.board_sessions(s)
    end

    test "an older status that arrives late never overrides a newer one" do
      # The prompt was answered at once, and "done waiting" beat "waiting" to the hub.
      {s, :same} = Remote.apply_event(%{}, ev(hook("PostToolUse"), 2_000), false)
      {s, :same} = Remote.apply_event(s, ev(notice("permission_prompt"), 1_000), false)
      assert Remote.board_sessions(s) == []

      {s, :started} = Remote.apply_event(s, ev(notice("permission_prompt"), 5_000), false)
      {s, :same} = Remote.apply_event(s, ev(hook("Stop"), 4_000), false)
      assert [_] = Remote.board_sessions(s)
    end

    test "this machine's own sessions are left to its own check" do
      assert {%{}, :same} = Remote.apply_event(%{}, ev(notice("permission_prompt"), 1), true)
    end

    test "a card nobody hears about for a day is dropped" do
      day = 24 * 3600 * 1000
      {s, :started} = Remote.apply_event(%{}, ev(notice("permission_prompt"), 1_000), false)
      assert {^s, false} = Remote.sweep(s, 1_000 + day)
      assert {%{}, true} = Remote.sweep(s, 1_001 + day)
    end

    test "a card is marked with the machine, and the account when it is not the main one" do
      {:ok, e} = Remote.event(notice("permission_prompt"), "laptop", "work", 1_000)

      {s, :started} = Remote.apply_event(%{}, e, false)

      assert [
               %{
                 name: "vitalaize",
                 machine: "laptop",
                 account: "laptop · work",
                 session_id: @sid,
                 tool: :claude
               }
             ] = Remote.board_sessions(s)
    end
  end

  # ---------------------------------------------------------------------------
  # End to end: the real upload script, run by sh, posting to the board's
  # real router, which alerts on ntfy (a local stand-in).

  defmodule Catcher do
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{test: test}) do
      {:ok, body, conn} = read_body(conn)
      send(test, {:alert, conn.request_path, body})
      send_resp(conn, 200, "ok")
    end
  end

  # The endpoint's own parsing in front of the real router, without the
  # rest of the endpoint (sessions, static files), which needs a server.
  defmodule Hub do
    use Plug.Builder
    plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
    plug WallboardWeb.Router
  end

  defp serve(plug) do
    {:ok, pid} = Bandit.start_link(plug: plug, ip: :loopback, port: 0, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "wallboard-remote-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Runs the upload script as Claude would: the hook's JSON on stdin, and a
  # throwaway Claude folder and temp folder, never the real ones.
  defp run_hook(script, dir, hook) do
    input = Path.join(dir, "input.json")
    File.write!(input, Jason.encode!(hook))

    System.cmd("sh", ["-c", ~s(sh "$0" < "$1"), script, input],
      env: [
        {"TMPDIR", dir},
        {"HOME", dir},
        {"CLAUDE_CONFIG_DIR", Path.join(dir, ".claude")}
      ],
      stderr_to_stdout: true
    )
  end

  defp this_machine do
    {out, 0} = System.cmd("sh", ["-c", "scutil --get LocalHostName 2>/dev/null || hostname -s"])
    out |> String.trim() |> String.replace(~r/[^A-Za-z0-9._-]/, "-") |> String.slice(0, 64)
  end

  describe "from the collector's hook to the hub's alert" do
    setup do
      old = Settings.get()
      on_exit(fn -> :persistent_term.put({Wallboard.Settings, :settings}, old) end)
      dir = tmp_dir()
      start_supervised!({Store, path: ":memory:"})
      start_supervised!(Remote)
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Wallboard.Poller.topic())
      hub = serve(Hub)
      ntfy = serve({Catcher, %{test: self()}})

      settings = fn machine ->
        Settings.put(%{
          archive: %{enabled: true, path: Path.join(dir, "wallboard.db"), machine: machine},
          alerts: %{ntfy_topic: "t1", ntfy_server: ntfy}
        })
      end

      script = Path.join(dir, "wallboard-upload.sh")
      File.write!(script, Ingest.upload_script(hub, Ingest.token()))
      %{dir: dir, script: script, settings: settings}
    end

    test "a waiting session shows on the hub and alerts once, then clears", ctx do
      ctx.settings.("the-hub")
      machine = this_machine()

      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"))
      assert_receive {:remote, [%{machine: ^machine, why: @permission}]}, 5_000
      assert_receive {:alert, "/t1", text}, 5_000
      assert text =~ "vitalaize on #{machine} needs you. #{@permission}"
      assert File.exists?(Path.join(ctx.dir, "wallboard-waiting-#{@sid}"))

      # Asking again while it already waits sends no second alert.
      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"))
      refute_receive {:alert, _, _}, 500

      assert {"", 0} = run_hook(ctx.script, ctx.dir, hook("PostToolUse"))
      assert_receive {:remote, []}, 5_000
      assert Remote.sessions() == []
      refute File.exists?(Path.join(ctx.dir, "wallboard-waiting-#{@sid}"))
    end

    test "a question from AskUserQuestion alerts with the question", ctx do
      ctx.settings.("the-hub")

      ask =
        hook("PreToolUse")
        |> Map.merge(%{
          "tool_name" => "AskUserQuestion",
          "tool_input" => %{"questions" => [%{"question" => ~s(Ship it? "yes" or 'no')}]}
        })

      assert {"", 0} = run_hook(ctx.script, ctx.dir, ask)
      assert_receive {:alert, "/t1", text}, 5_000
      assert text =~ ~s(needs you. Ship it? "yes" or 'no')
    end

    test "tool calls with nothing waiting send nothing at all", ctx do
      ctx.settings.("the-hub")
      # Another tool's PreToolUse and a plain PostToolUse: no status posted.
      assert {"", 0} =
               run_hook(ctx.script, ctx.dir, Map.put(hook("PreToolUse"), "tool_name", "Bash"))

      assert {"", 0} = run_hook(ctx.script, ctx.dir, hook("PostToolUse"))
      refute_receive {:remote, _}, 500
      refute_receive {:alert, _, _}, 100
    end

    test "sessions on the hub's own machine are left to its own check", ctx do
      ctx.settings.(this_machine())

      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"))
      refute_receive {:alert, _, _}, 1_000
      assert Remote.sessions() == []
    end

    test "a wrong key is turned away", ctx do
      ctx.settings.("the-hub")
      hub = ctx.script |> File.read!() |> then(&Regex.run(~r/HUB="([^"]+)"/, &1)) |> List.last()
      bad = Path.join(ctx.dir, "bad.sh")
      File.write!(bad, Ingest.upload_script(hub, "not-the-key"))

      assert {"", 0} = run_hook(bad, ctx.dir, notice("permission_prompt"))
      refute_receive {:alert, _, _}, 1_000
      assert Remote.sessions() == []
    end
  end

  test "a hub that cannot be reached costs the hook a moment and no error" do
    dir = tmp_dir()
    script = Path.join(dir, "wallboard-upload.sh")
    File.write!(script, Ingest.upload_script("http://127.0.0.1:1", "abc"))

    {micros, {out, code}} =
      :timer.tc(fn -> run_hook(script, dir, notice("permission_prompt")) end)

    assert {out, code} == {"", 0}
    assert micros < 5_000_000

    {micros, {"", 0}} = :timer.tc(fn -> run_hook(script, dir, hook("PostToolUse")) end)
    assert micros < 5_000_000
  end

  describe "connecting a machine" do
    defp settings_after_connect(kind, settings_file, script) do
      install = Ingest.install_script("http://192.168.1.20:4747", "abc")

      {tag, cmd} =
        case kind do
          :python -> {"WALLBOARD_PY", "python3"}
          :javascript -> {"WALLBOARD_JS", "osascript"}
        end

      [_, rest] = String.split(install, "<<'#{tag}'\n", parts: 2)
      [code, _] = String.split(rest, "\n#{tag}", parts: 2)
      file = Path.join(Path.dirname(settings_file), "connect.#{kind}")
      File.write!(file, code)

      args =
        if kind == :python,
          do: [file, settings_file, script],
          else: ["-l", "JavaScript", file, settings_file, script]

      {out, 0} = System.cmd(cmd, args, stderr_to_stdout: true)
      assert out == ""
      Jason.decode!(File.read!(settings_file))
    end

    for kind <- [:python, :javascript] do
      test "adds every hook once, in the background, beside what was there (#{kind})" do
        kind = unquote(kind)
        cmd = %{python: "python3", javascript: "osascript"}[kind]

        if System.find_executable(cmd) do
          dir = tmp_dir()
          file = Path.join(dir, "settings.json")
          script = Path.join(dir, "wallboard-upload.sh")
          mine = %{"hooks" => [%{"type" => "command", "command" => "echo mine"}]}
          File.write!(file, Jason.encode!(%{"model" => "opus", "hooks" => %{"Stop" => [mine]}}))

          s = settings_after_connect(kind, file, script)
          # Connecting again (to add hooks a newer hub knows) adds no copies.
          assert settings_after_connect(kind, file, script) == s

          assert s["model"] == "opus"
          assert mine in s["hooks"]["Stop"]

          for %{"event" => event, "matcher" => matcher} <- Ingest.hooks() do
            ours =
              for m <- s["hooks"][event],
                  h <- m["hooks"],
                  h["command"] == script,
                  do: {m["matcher"], h["async"]}

            assert ours == [{matcher, true}], "#{event}: #{inspect(ours)}"
          end
        end
      end
    end
  end
end
