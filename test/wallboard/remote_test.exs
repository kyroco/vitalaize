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
    end

    test "a status without a usable session id is refused" do
      assert {:error, _} = Remote.event(%{"hook_event_name" => "Stop"}, "m", "a", 1)
      assert {:error, _} = Remote.event(%{"session_id" => "../x"}, "m", "a", 1)
      assert {:error, _} = Remote.event(%{"session_id" => @sid <> "\n"}, "m", "a", 1)
      assert {:error, _} = Remote.event(%{"session_id" => 123}, "m", "a", 1)
      assert {:error, _} = Remote.event(%{"session_id" => %{"a" => 1}}, "m", "a", 1)
      assert {:error, _} = Remote.event("text", "m", "a", 1)
    end

    test "a sender's text is cut to one short line" do
      assert String.length(ev(notice("permission_prompt", String.duplicate("a", 999)), 1).why) ==
               240

      assert ev(notice("permission_prompt", "one\n2026 [error] forged"), 1).why ==
               "one 2026 [error] forged"

      # Characters that are many bytes each still fit in 1,000 bytes.
      assert byte_size(ev(notice("permission_prompt", String.duplicate("é", 999)), 1).why) <=
               1_000

      assert byte_size(
               ev(notice("permission_prompt", "a" <> String.duplicate("́", 99_999)), 1).why
             ) <=
               1_000

      long = Map.put(notice("permission_prompt"), "cwd", "/x/" <> String.duplicate("b", 500))
      assert String.length(ev(long, 1).folder) == 64
    end

    test "machine and account names cannot climb out of the inbox or end in a newline" do
      refute Ingest.valid_name?(".")
      refute Ingest.valid_name?("..")
      refute Ingest.valid_name?("laptop\n")
      assert Ingest.valid_name?(".claude")
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

    test "when both carry the same time, done waiting wins" do
      {s, :same} = Remote.apply_event(%{}, ev(hook("PostToolUse"), 2_000), false)
      {s, :same} = Remote.apply_event(s, ev(notice("permission_prompt"), 2_000), false)
      assert Remote.board_sessions(s) == []

      {s, :started} = Remote.apply_event(s, ev(notice("permission_prompt"), 3_000), false)
      {s, :changed} = Remote.apply_event(s, ev(hook("PostToolUse"), 3_000), false)
      assert Remote.board_sessions(s) == []
    end

    test "a new question while still waiting shows its words, keeps the start, and is not a new wait" do
      {s, :started} = Remote.apply_event(%{}, ev(notice("permission_prompt", "A"), 1_000), false)
      {s, :changed} = Remote.apply_event(s, ev(notice("permission_prompt", "B"), 9_000), false)
      assert [%{why: "B", since: since}] = Remote.board_sessions(s)
      assert DateTime.to_unix(since, :millisecond) == 1_000
    end

    test "at most so many sessions are kept, the least recently heard from going first" do
      s =
        for n <- 1..5, into: %{} do
          {:ok, e} = Remote.event(notice("permission_prompt"), "m#{n}", "main", n)
          {e.key, %{e | received: n} |> Map.put(:since, n)}
        end

      kept = Remote.cap(s, 3)
      assert kept |> Map.values() |> Enum.map(& &1.machine) |> Enum.sort() == ~w(m3 m4 m5)
      assert Remote.cap(s, 5) == s
    end

    test "at most 20 alerts from other machines in 10 minutes" do
      sent =
        Enum.reduce(1..20, [], fn n, sent ->
          {true, sent} = Remote.alert_allowed?(sent, n * 1_000)
          sent
        end)

      assert {false, ^sent} = Remote.alert_allowed?(sent, 30_000)
      # Ten minutes after the first, one more may go.
      assert {true, _} = Remote.alert_allowed?(sent, 1_000 + 600_000)
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
    dir = Wallboard.Fixtures.tmp_path("wallboard-remote")
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Runs the upload script as Claude would: the hook's JSON on stdin, and a
  # throwaway Claude folder and temp folder, never the real ones. The PATH
  # holds only the system's own tools and dir/bin, where a test may put a
  # stand-in `claude`, so the real one is never run.
  defp run_hook(script, dir, hook, env \\ []) do
    input = Path.join(dir, "input.json")
    File.write!(input, Jason.encode!(hook))
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    System.cmd("sh", ["-c", ~s(sh "$0" < "$1"), script, input],
      env:
        [
          {"TMPDIR", dir},
          {"HOME", dir},
          {"CLAUDE_CONFIG_DIR", Path.join(dir, ".claude")},
          {"PATH", Enum.join([bin, "/usr/bin", "/bin", "/usr/sbin", "/sbin"], ":")}
        ] ++ env,
      stderr_to_stdout: true
    )
  end

  # A stand-in `claude` whose `agents --json` reports this session as
  # waiting or busy, whatever the test last set. It can take `delay`
  # seconds, reading the status only at the end, as a slow check would;
  # :fail makes every check fail.
  defp fake_claude(dir, status, delay \\ 0) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    agents = Path.join(dir, "agents.json")

    if status != :fail,
      do: File.write!(agents, Jason.encode!([%{"sessionId" => @sid, "status" => status}]))

    body =
      if status == :fail,
        do: "exit 1",
        else: "sleep #{delay}\ncat \"#{agents}\""

    path = Path.join(bin, "claude")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
  end

  # The loop's lock is a link to a process id, so look at the link itself.
  defp locked?(ctx), do: match?({:ok, _}, File.lstat(marker(ctx) <> ".watch"))

  # This test's loops for this session, not counting the short-lived copies
  # of a loop the shell makes for a check or a sleep (their parent is the
  # loop). A loop runs as `sh <script> --watch <session>`, and each test's
  # script sits in its own folder, so matching the script's full path sees
  # only this test's loops: never another test run's on the same machine,
  # nor a real collector's.
  defp loops(ctx), do: ctx |> loop_roots() |> length()

  defp loop_roots(ctx) do
    procs = loop_procs(ctx)
    pids = MapSet.new(procs, &elem(&1, 0))
    for {pid, ppid} <- procs, not MapSet.member?(pids, ppid), do: pid
  end

  defp loop_procs(ctx) do
    # -ww: never cut a long command line to the terminal's width.
    {out, 0} = System.cmd("ps", ["-axwwo", "pid=,ppid=,command="])
    mine = "#{ctx.script} --watch #{@sid}"

    for line <- String.split(out, "\n"),
        String.contains?(line, mine),
        [pid, ppid | _] <- [String.split(line)],
        do: {pid, ppid}
  end

  # Stops this test's loops and waits until they are gone, never signalling
  # a pattern the whole machine matches. A loop is started in its own
  # session, so its process group holds it and everything it runs (a check,
  # a sleep, the stand-in claude); the group is what is stopped. A loop
  # still there after five seconds is killed outright, and one that
  # survives even that fails the test rather than being left running.
  defp stop_loops(ctx) do
    with :running <- stop_loops(ctx, "-TERM"),
         :running <- stop_loops(ctx, "-KILL") do
      flunk("upload loops still running: #{inspect(loop_roots(ctx))}")
    end
  end

  defp stop_loops(ctx, signal) do
    case loop_roots(ctx) do
      [] ->
        :ok

      roots ->
        groups = Enum.map(roots, &("-" <> &1))
        System.cmd("kill", [signal, "--" | groups ++ roots], stderr_to_stdout: true)

        Enum.reduce_while(1..50, :running, fn _, _ ->
          if loops(ctx) == 0, do: {:halt, :ok}, else: {:cont, Process.sleep(100)}
        end)
    end
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
          alerts: %{ntfy_topic: "t1", ntfy_server: ntfy},
          # The alert waits one session check, here one second.
          claude: %{poll_seconds: 1}
        })
      end

      # Not named wallboard-upload.sh: copies of this file from before
      # VIT-32 stop every `upload.sh --watch <session>` on the machine, and
      # would stop this run's loops if they ran beside it.
      script = Path.join(dir, "upload-under-test")
      File.write!(script, Ingest.upload_script(hub, Ingest.token()))
      %{dir: dir, script: script, settings: settings, hub: hub}
    end

    defp marker(ctx), do: Path.join(ctx.dir, "wallboard-waiting-#{@sid}")

    test "approving a prompt ends the wait though no hook fires, and the hook never waits for the loop",
         ctx do
      ctx.settings.("the-hub")
      on_exit(fn -> stop_loops(ctx) end)
      fake_claude(ctx.dir, "waiting")
      quick = [{"WALLBOARD_WATCH_EVERY", "1"}]

      {micros, {"", 0}} =
        :timer.tc(fn -> run_hook(ctx.script, ctx.dir, notice("permission_prompt"), quick) end)

      assert micros < 2_000_000
      assert_receive {:remote, [_]}, 5_000
      Process.sleep(1_500)
      assert loops(ctx) == 1

      # A second prompt in the same session starts no second loop.
      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"), quick)
      Process.sleep(1_500)
      assert loops(ctx) == 1

      # Approved: the session is running again, and no hook said so.
      fake_claude(ctx.dir, "busy")
      assert_receive {:remote, []}, 5_000
      refute File.exists?(marker(ctx))
      Process.sleep(2_000)
      assert loops(ctx) == 0
      refute locked?(ctx)
    end

    test "a loop stops at its time limit even while the session still waits", ctx do
      ctx.settings.("the-hub")
      on_exit(fn -> stop_loops(ctx) end)
      fake_claude(ctx.dir, "waiting")
      env = [{"WALLBOARD_WATCH_EVERY", "1"}, {"WALLBOARD_WATCH_LIMIT", "2"}]

      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"), env)
      assert_receive {:remote, [_]}, 5_000
      Process.sleep(4_000)
      assert loops(ctx) == 0
      refute locked?(ctx)
      # The wait itself stays up for the hooks to end.
      assert File.exists?(marker(ctx))
    end

    test "without claude on the PATH no loop starts and the hooks still work", ctx do
      ctx.settings.("the-hub")
      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"))
      assert_receive {:remote, [_]}, 5_000
      Process.sleep(500)
      assert loops(ctx) == 0
      refute locked?(ctx)
    end

    test "while the loop watches, a tool that ran beside the prompt does not end the wait", ctx do
      ctx.settings.("the-hub")
      on_exit(fn -> stop_loops(ctx) end)
      fake_claude(ctx.dir, "waiting")
      quick = [{"WALLBOARD_WATCH_EVERY", "1"}]

      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"), quick)
      assert_receive {:remote, [_]}, 5_000
      Process.sleep(1_500)

      # A Grep beside the prompt finishes; claude agents still says waiting.
      assert {"", 0} = run_hook(ctx.script, ctx.dir, hook("PostToolUse"), quick)
      refute_receive {:remote, []}, 2_500
      assert [_] = Remote.sessions()

      fake_claude(ctx.dir, "busy")
      assert_receive {:remote, []}, 5_000
    end

    test "a new prompt that opens during a check is not taken for the one just answered", ctx do
      ctx.settings.("the-hub")
      on_exit(fn -> stop_loops(ctx) end)
      # Each check takes 1.5 seconds and reads the status only at its end.
      fake_claude(ctx.dir, "waiting", 1.5)
      quick = [{"WALLBOARD_WATCH_EVERY", "1"}]

      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt", "A"), quick)
      assert_receive {:remote, [%{why: "A"}]}, 5_000
      # Checks run from about 1 to 2.5 seconds (A seen waiting), then from
      # about 3.5 to 5: switch in the middle of that second check.
      Process.sleep(4_000)

      # A is approved and B opens at once, likely while a check is running.
      fake_claude(ctx.dir, "busy", 1.5)
      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt", "B"), quick)
      Process.sleep(4_000)

      assert [%{why: "B"}] = Remote.sessions()
      assert File.read!(marker(ctx)) =~ ~r/^notice: /

      # B, once seen waiting and then answered, still ends as usual.
      fake_claude(ctx.dir, "waiting", 0)
      Process.sleep(2_500)
      fake_claude(ctx.dir, "busy", 0)
      assert_receive {:remote, []}, 5_000
    end

    test "a prompt answered too fast for the loop to see still ends at its tool call", ctx do
      ctx.settings.("the-hub")
      on_exit(fn -> stop_loops(ctx) end)
      # claude agents never gets to show it waiting.
      fake_claude(ctx.dir, "busy")
      quick = [{"WALLBOARD_WATCH_EVERY", "1"}]

      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"), quick)
      assert_receive {:remote, [_]}, 5_000
      assert {"", 0} = run_hook(ctx.script, ctx.dir, hook("PostToolUse"), quick)
      assert_receive {:remote, []}, 5_000
    end

    test "a loop whose check keeps failing leaves after a while", ctx do
      ctx.settings.("the-hub")
      on_exit(fn -> stop_loops(ctx) end)
      fake_claude(ctx.dir, :fail)
      env = [{"WALLBOARD_WATCH_EVERY", "1"}, {"WALLBOARD_WATCH_PATIENCE", "2"}]

      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"), env)
      assert_receive {:remote, [_]}, 5_000
      Process.sleep(4_500)
      assert loops(ctx) == 0
      refute locked?(ctx)
    end

    test "a lock left by a loop that died is taken over", ctx do
      ctx.settings.("the-hub")
      on_exit(fn -> stop_loops(ctx) end)
      fake_claude(ctx.dir, "waiting")
      # A process id that is not running.
      File.ln_s!("999999", marker(ctx) <> ".watch")

      assert {"", 0} =
               run_hook(ctx.script, ctx.dir, notice("permission_prompt"), [
                 {"WALLBOARD_WATCH_EVERY", "1"}
               ])

      Process.sleep(1_000)
      assert loops(ctx) == 1
      assert {:ok, pid} = File.read_link(marker(ctx) <> ".watch")
      assert pid != "999999"
    end

    test "a prompt answered before the board's own check would see it sends no alert", ctx do
      ctx.settings.("the-hub")

      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"))
      assert_receive {:remote, [_]}, 5_000
      assert {"", 0} = run_hook(ctx.script, ctx.dir, hook("PostToolUse"))
      assert_receive {:remote, []}, 5_000
      refute_receive {:alert, _, _}, 2_000
    end

    test "a question clears only when its own tool call ends", ctx do
      ctx.settings.("the-hub")

      ask =
        Map.merge(hook("PreToolUse"), %{
          "tool_name" => "AskUserQuestion",
          "tool_use_id" => "toolu_ask",
          "tool_input" => %{"questions" => [%{"question" => "Which one?"}]}
        })

      done = fn id -> Map.put(hook("PostToolUse"), "tool_use_id", id) end

      assert {"", 0} = run_hook(ctx.script, ctx.dir, ask)
      assert_receive {:remote, [_]}, 5_000
      # Another tool finishing meanwhile leaves the question up.
      assert {"", 0} = run_hook(ctx.script, ctx.dir, done.("toolu_other"))
      refute_receive {:remote, _}, 500
      assert File.exists?(marker(ctx))

      assert {"", 0} = run_hook(ctx.script, ctx.dir, done.("toolu_ask"))
      assert_receive {:remote, []}, 5_000
    end

    test "a helper agent's tool call does not end the session's own wait", ctx do
      ctx.settings.("the-hub")

      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"))
      assert_receive {:remote, [_]}, 5_000

      helper = Map.merge(hook("PostToolUse"), %{"agent_id" => "a1b2", "tool_use_id" => "t1"})
      assert {"", 0} = run_hook(ctx.script, ctx.dir, helper)
      refute_receive {:remote, _}, 500

      assert {"", 0} = run_hook(ctx.script, ctx.dir, hook("UserPromptSubmit"))
      assert_receive {:remote, []}, 5_000
    end

    test "a done waiting the hub did not take is sent again by the next hook", ctx do
      ctx.settings.("the-hub")
      down = Path.join(ctx.dir, "down.sh")
      File.write!(down, Ingest.upload_script("http://127.0.0.1:1", "abc"))

      assert {"", 0} = run_hook(ctx.script, ctx.dir, notice("permission_prompt"))
      assert_receive {:remote, [_]}, 5_000

      # The hub is out of reach when the prompt is answered.
      assert {"", 0} = run_hook(down, ctx.dir, hook("PostToolUse"))
      assert File.exists?(marker(ctx))

      assert {"", 0} = run_hook(ctx.script, ctx.dir, hook("Stop"))
      assert_receive {:remote, []}, 5_000
      refute File.exists?(marker(ctx))
    end

    test "a status the hub cannot read is refused, never a crash", ctx do
      ctx.settings.("the-hub")

      post = fn body, query ->
        {out, 0} =
          System.cmd("curl", [
            "-s",
            "-g",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "-H",
            "Content-Type: application/json",
            "-X",
            "POST",
            "-H",
            "Authorization: Bearer #{Ingest.token()}",
            "--data-binary",
            body,
            "#{ctx.hub}/ingest/status?machine=laptop#{query}"
          ])

        out
      end

      assert post.(~s({"session_id":123,"hook_event_name":"Notification"}), "") == "422"
      assert post.(~s({"session_id":{"a":1}}), "") == "422"
      assert post.("not json", "") == "422"
      assert post.(~s({"session_id":"#{@sid}","hook_event_name":"Stop"}), "&at[x]=1") == "200"
      assert post.(~s({"session_id":"#{@sid}"}), "&account=..") == "422"
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
      refute_receive {:alert, _, _}, 1_500

      assert {"", 0} = run_hook(ctx.script, ctx.dir, hook("PostToolUse"))
      assert_receive {:remote, []}, 5_000
      assert Remote.sessions() == []
      refute File.exists?(marker(ctx))
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

      wanted = Jason.encode!(Ingest.hooks())

      args =
        if kind == :python,
          do: [file, settings_file, script, wanted],
          else: ["-l", "JavaScript", file, settings_file, script, wanted]

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

    test "the whole connect script gives Claude every hook and Codex only its two" do
      dir = tmp_dir()
      claude = Path.join(dir, ".claude")
      codex = Path.join(dir, ".codex")
      File.mkdir_p!(codex)
      install = Path.join(dir, "install.sh")
      File.write!(install, Ingest.install_script("http://192.168.1.20:4747", "abc"))

      assert {_, 0} =
               System.cmd("sh", [install],
                 env: [
                   {"HOME", dir},
                   {"CLAUDE_CONFIG_DIR", claude},
                   {"CODEX_HOME", codex}
                 ],
                 stderr_to_stdout: true
               )

      events = fn file ->
        file
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("hooks")
        |> Map.keys()
        |> Enum.sort()
      end

      assert events.(Path.join(claude, "settings.json")) ==
               Ingest.hooks() |> Enum.map(& &1["event"]) |> Enum.sort()

      assert events.(Path.join(codex, "hooks.json")) == ~w(SessionEnd Stop)
    end
  end
end
