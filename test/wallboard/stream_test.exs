defmodule Wallboard.StreamTest do
  # A throwaway collector and a throwaway hub in one test process, joined
  # by the real link on a local port. One hub at a time: it has one name
  # and one database.
  use ExUnit.Case, async: false

  alias Wallboard.Archive.Ingest
  alias Wallboard.Collector.{Outbox, Sender, Watcher}
  alias Wallboard.Fixtures
  alias Wallboard.Link.{Authority, Hub, Sessions}
  alias Wallboard.Settings
  alias Wallboard.Sources.Claude
  alias Wallboard.Store

  @moduletag :capture_log

  @claude_id "d299768e-2531-4395-a7ec-bf457e22c263"
  @helper_file @claude_id <> "/subagents/agent-a1.jsonl"
  @codex_id "01a0c9db-3044-75f0-99fe-345bf658a60b"
  @codex_name "rollout-2026-09-29T14-00-00-" <> @codex_id <> ".jsonl"
  @codex_file "2026/09/29/" <> @codex_name

  # Quick waits, so a test that loses the hub does not sit for a second.
  @fast [base_ms: 40, cap_ms: 300, back_soon_ms: 300]

  # What the archive is compared on: the numbers Archive and Trends add up.
  @totals ~w(tool requests input_tokens output_tokens cache_read_tokens cache_write_tokens cost
    tool_calls tool_errors lines_added lines_removed prompts turns turn_ms compactions
    api_errors retries aborted denials subagents subagent_cost peak_context model effort
    cwd git_branch account korium_searches korium_search_hits korium_saves code_searches)a

  # The texts are the same words. A collector cuts a text at 500 characters
  # where the transcript reader keeps one more for a Codex prompt.
  @texts ~w(title first_prompt last_prompt)a

  setup do
    dir = Fixtures.tmp_path("wallboard-stream")
    home = Path.join(dir, "home")
    File.mkdir_p!(Path.join(home, ".claude/projects/-Users-r-projects-shop"))
    File.mkdir_p!(Path.join(home, ".codex/sessions/2026/09/29"))
    on_exit(fn -> File.rm_rf!(dir) end)

    old = Settings.get()
    on_exit(fn -> :persistent_term.put({Wallboard.Settings, :settings}, old) end)

    # The hub's settings: two alert channels, both pointed at this test.
    sink = alert_sink()

    Settings.put(%{
      claude: %{poll_seconds: 1},
      archive: %{path: Path.join(dir, "wallboard.db"), machine: "the-hub"},
      alerts: %{
        slack_webhook: "http://127.0.0.1:#{sink}/slack",
        ntfy_topic: "topic",
        ntfy_server: "http://127.0.0.1:#{sink}"
      }
    })

    collector =
      Settings.defaults()
      |> Settings.merge(%{role: "collector", collector: %{dir: Path.join(dir, "collector")}})
      |> Settings.normalize()

    {:ok, world} = Agent.start_link(fn -> %{agents: %{}} end)

    %{
      dir: dir,
      home: home,
      link: Path.join(dir, "link"),
      port: free_port(),
      collector: collector,
      world: world
    }
  end

  # ---------------------------------------------------------------------------
  # The two sides

  defp start_hub(c) do
    once({Store, path: Path.join(c.dir, "wallboard.db")})
    once({Sessions, save_ms: 100})
    once({Hub, dir: c.link, port: c.port})
    :ok
  end

  # Started under the test's supervisor, which must not start it again
  # when the test kills it. Left to restart, the hub can find its port
  # still held by the one just killed; it is then neither running nor
  # stopped, and `stop_supervised/1` fails on it. These tests say when
  # each side comes back.
  defp once(child, opts \\ []) do
    spec = Supervisor.child_spec(child, Keyword.put(opts, :restart, :temporary))
    start_supervised!(spec)
  end

  # The hub, its sessions and its database, gone at once.
  defp kill_hub do
    for name <- [Hub, Sessions, Store] do
      pid = Process.whereis(name)
      # The hub's name belongs to its list of machines; its supervisor is
      # what holds the port too.
      pid = if name == Hub, do: pid |> Process.info(:links) |> elem(1) |> hd(), else: pid
      kill(pid)
      stop_supervised(name)
    end
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}, 5_000
  end

  # Gives the collector what pairing would: its certificate and the hub's
  # address, in its own folder.
  defp pair(c, machine \\ "papa") do
    {:ok, files} = Authority.issue(c.link, machine)
    into = c.collector.collector.dir
    File.mkdir_p!(into)

    for {name, key} <- [{"cert.pem", :cert_pem}, {"key.pem", :key_pem}, {"ca.pem", :ca_pem}],
        do: File.write!(Path.join(into, name), Map.fetch!(files, key))

    File.write!(
      Path.join(into, "hub.json"),
      Jason.encode!(%{host: "127.0.0.1", link_port: c.port, machine: machine})
    )
  end

  defp start_collector(c) do
    dir = c.collector.collector.dir
    world = c.world
    outbox = once({Outbox, dir: Path.join(dir, "outbox"), name: nil}, id: :outbox)

    watcher =
      once(
        {Watcher,
         name: nil,
         outbox: outbox,
         home: c.home,
         timer: false,
         settings: fn -> c.collector end,
         claude: fn folder -> Agent.get(world, &Map.get(&1.agents, folder, {:ok, []})) end},
        id: :watcher
      )

    sender =
      once(
        {Sender,
         name: nil,
         dir: dir,
         outbox: outbox,
         watcher: watcher,
         tick_ms: 30,
         client: [name: :"stream-client-#{System.unique_integer([:positive])}", backoff: @fast]},
        id: :sender
      )

    %{outbox: outbox, watcher: watcher, sender: sender}
  end

  # The collector, gone at once, with whatever it had in hand. In one
  # test process its connection has to be cut by hand; a real collector's
  # goes with its program.
  defp kill_collector(w) do
    conn =
      case :sys.get_state(w.sender) do
        %{client: nil} -> nil
        %{client: client} -> :sys.get_state(client).conn
      end

    kill(w.sender)

    if conn do
      Process.exit(conn.pid, :kill)

      try do
        GRPC.Client.Connection.disconnect(conn.ref)
      catch
        _, _ -> :ok
      end
    end

    kill(w.watcher)
    kill(w.outbox)
    for id <- [:sender, :watcher, :outbox], do: stop_supervised(id)
  end

  # ---------------------------------------------------------------------------
  # Sessions on the collector's machine

  defp lines(name), do: name |> Fixtures.read!() |> String.split("\n", trim: true)

  defp add(path, lines) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(lines, &(&1 <> "\n")), [:append])
  end

  defp claude_dir(c), do: Path.join(c.home, ".claude")

  defp claude_path(c, name),
    do: Path.join([claude_dir(c), "projects/-Users-r-projects-shop", name])

  defp codex_path(c), do: Path.join([c.home, ".codex/sessions", @codex_file])

  # What `claude agents` reports for each session, as the board reads it.
  defp agents(c, list) do
    sessions =
      for {id, fields} <- list do
        json =
          Jason.encode!([
            Map.merge(
              %{
                "pid" => 91_796,
                "id" => String.slice(id, 0, 8),
                "cwd" => "/Users/r/projects/shop",
                "kind" => "interactive",
                "startedAt" => 1_790_631_608_517,
                "sessionId" => id
              },
              fields
            )
          ])

        {:ok, [agent]} = Claude.parse_agents(json)
        Claude.build_session(agent, nil, nil, nil)
      end

    Agent.update(c.world, &put_in(&1.agents[claude_dir(c)], {:ok, sessions}))
  end

  # What Codex's hook leaves for the session.
  defp mark(c, body) do
    path = Path.join([c.home, ".codex/vitalaize", @codex_id <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(Map.put(body, "session_id", @codex_id)))
  end

  defp look(w), do: :ok = Watcher.tick(w.watcher)

  # ---------------------------------------------------------------------------
  # Looking at the hub

  defp card(id), do: Enum.find(Sessions.cards(), &(&1.session_id == id))

  defp wait_until(fun, left \\ 100) do
    cond do
      fun.() -> :ok
      left == 0 -> flunk("waited too long")
      true -> Process.sleep(50) && wait_until(fun, left - 1)
    end
  end

  # Everything the collector made is at the hub and confirmed.
  defp drained(w) do
    wait_until(fn ->
      stats = Outbox.stats(w.outbox)
      stats.acked == stats.seq and sender_idle?(w)
    end)
  end

  defp sender_idle?(w) do
    case :sys.get_state(w.sender) do
      %{client: nil} -> false
      %{client: client} -> Wallboard.Link.Client.status(client).waiting == 0
    end
  end

  defp saved(machine, id) do
    :ok = Sessions.save()
    Store.get_session(machine, id)
  end

  defp requests(machine, id) do
    Store.query(
      "SELECT request_id, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost, subagent FROM requests WHERE machine = ?1 AND session_id = ?2 ORDER BY request_id",
      [machine, id]
    )
  end

  defp same_words(streamed, uploaded) do
    for key <- @texts do
      cut = fn text -> text && String.slice(text, 0, 499) end
      assert {key, cut.(Map.fetch!(streamed, key))} == {key, cut.(Map.fetch!(uploaded, key))}
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # A small web server that takes every alert and tells the test: the path
  # says which channel it came by.
  defp alert_sink do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    test = self()
    spawn_link(fn -> accept(listen, test) end)
    port
  end

  defp accept(listen, test) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        request = read_request(socket, "")
        [first | _] = String.split(request, "\r\n")
        [_, path | _] = String.split(first, " ")
        [_, body] = String.split(request, "\r\n\r\n", parts: 2)
        send(test, {:alert, path, body})
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
        :gen_tcp.close(socket)
        accept(listen, test)

      _ ->
        :ok
    end
  end

  defp read_request(socket, acc) do
    with [head, body] <- String.split(acc, "\r\n\r\n", parts: 2),
         [_, n] <- Regex.run(~r/content-length: (\d+)/i, head),
         true <- byte_size(body) >= String.to_integer(n) do
      acc
    else
      _ ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_request(socket, acc <> data)
          _ -> acc
        end
    end
  end

  # The transcripts sent the old way: as a .tar.gz to the upload path.
  defp tar(c, files) do
    path = Path.join(c.dir, "up-#{System.unique_integer([:positive])}.tgz")
    entries = for {name, body} <- files, do: {String.to_charlist(name), body}
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.read!(path)
  end

  defp both_sessions(c) do
    add(claude_path(c, @claude_id <> ".jsonl"), lines("collector/claude_session.jsonl"))
    add(claude_path(c, @helper_file), lines("collector/claude_subagent.jsonl"))
    add(codex_path(c), lines("collector/codex_rollout.jsonl"))
  end

  # ---------------------------------------------------------------------------

  describe "live on the board" do
    test "a Claude and a Codex session show as cards, change status, and alert once per channel",
         c do
      start_hub(c)
      start_supervised!(Wallboard.Remote)
      pair(c)
      w = start_collector(c)
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Wallboard.Poller.topic())

      {first, rest} = Enum.split(lines("collector/claude_session.jsonl"), 3)
      add(claude_path(c, @claude_id <> ".jsonl"), first)
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      {running, later} = Enum.split(lines("collector/codex_rollout.jsonl"), 12)
      add(codex_path(c), running)

      # Both appear within a few seconds of the collector seeing them.
      began = System.monotonic_time(:millisecond)
      look(w)
      wait_until(fn -> card(@claude_id) != nil and card(@codex_id) != nil end)
      assert System.monotonic_time(:millisecond) - began < 5_000
      # The board is told, too.
      assert_receive {:stream, [_ | _]}, 2_000

      claude = card(@claude_id)
      assert %{status: :working, tool: :claude, machine: "papa", stale: false} = claude
      assert claude.account == "papa"
      assert claude.key == "stream:papa:" <> @claude_id
      assert %{status: :working, tool: :codex, machine: "papa"} = card(@codex_id)
      refute_receive {:alert, _, _}, 300

      # The rest of the Claude session's lines fill its card in: what it
      # works on, its repository, context, model, cost and lines.
      add(claude_path(c, @claude_id <> ".jsonl"), rest)
      look(w)
      wait_until(fn -> card(@claude_id).detail.added > 0 end)
      claude = card(@claude_id)
      assert claude.detail.cost > 0
      assert is_binary(claude.detail.model_label)
      assert is_integer(claude.detail.context_pct)
      assert claude.detail.removed >= 0
      assert claude.folder == "shop"
      assert is_binary(claude.name) and is_binary(claude.task)

      # The Claude session starts waiting: its card says so, and one alert
      # goes out on each channel.
      agents(c, [{@claude_id, %{"status" => "waiting", "waitingFor" => "permission prompt"}}])
      look(w)
      wait_until(fn -> card(@claude_id).status == :needs end)
      assert card(@claude_id).why == "A permission prompt is waiting for your approval"
      assert_receive {:alert, "/slack", slack}, 4_000
      assert_receive {:alert, "/topic", ntfy}, 4_000
      assert slack =~ "on papa needs you"
      assert ntfy =~ "A permission prompt is waiting for your approval"

      # The same machine still runs the old hooks, which report the same
      # wait. That sends nothing more, and shows no second card.
      hook = %{
        "hook_event_name" => "Notification",
        "notification_type" => "permission_prompt",
        "message" => "Claude needs your permission",
        "session_id" => @claude_id
      }

      :ok = Wallboard.Remote.report(hook, "papa-mac", "main", System.os_time(:millisecond))
      refute_receive {:alert, _, _}, 1_800

      # Codex asks to run something.
      mark(c, %{
        "hook_event_name" => "PermissionRequest",
        "tool_name" => "shell",
        "tool_input" => %{"command" => "git push --token PLANTED_COMMAND_SECRET"}
      })

      look(w)
      wait_until(fn -> card(@codex_id).status == :needs end)
      assert card(@codex_id).why == "Asks for your approval to use shell"
      assert_receive {:alert, "/slack", _}, 4_000
      assert_receive {:alert, "/topic", _}, 4_000
      refute_receive {:alert, _, _}, 1_500

      # Both move on.
      agents(c, [{@claude_id, %{"status" => "idle"}}])
      mark(c, %{"hook_event_name" => "PostToolUse", "tool_name" => "shell"})
      look(w)

      wait_until(fn ->
        card(@claude_id).status == :idle and card(@codex_id).status == :working
      end)

      add(codex_path(c), later)
      look(w)
      wait_until(fn -> card(@codex_id).status == :idle end)
      assert card(@codex_id).detail.tokens > 0

      # Both end: their cards come down.
      agents(c, [])
      mark(c, %{"hook_event_name" => "SessionEnd"})
      look(w)
      wait_until(fn -> Sessions.cards() == [] end)
      refute_receive {:alert, _, _}, 300

      # Each status change is in the archive's history.
      drained(w)
      :ok = Sessions.save()
      # (This test's changes fall within one second, so their order in
      # the history, which is kept by the second, is not looked at.)
      history = Store.get_session("papa", @claude_id).events |> Enum.map(& &1.status)
      assert Enum.sort(history) == ~w(gone idle needs working)
      history = Store.get_session("papa", @codex_id).events |> Enum.map(& &1.status)
      assert Enum.sort(Enum.uniq(history)) == ~w(gone idle needs working)
    end
  end

  describe "saved in the archive" do
    test "the same totals as the upload path gives for the same transcripts, counted once", c do
      start_hub(c)
      both_sessions(c)
      settings = Settings.get()

      # The old way first: the transcripts as an upload, from a machine
      # that names itself.
      up =
        tar(c, [
          {@claude_id <> ".jsonl", File.read!(claude_path(c, @claude_id <> ".jsonl"))},
          {@helper_file, File.read!(claude_path(c, @helper_file))}
        ])

      assert {:ok, @claude_id} = Ingest.receive(up, "papa-mac", ".claude", settings)
      codex_up = tar(c, [{@codex_name, File.read!(codex_path(c))}])
      assert {:ok, @codex_id} = Ingest.receive_codex(codex_up, "papa-mac", ".codex", settings)

      uploaded = %{
        @claude_id => Store.get_session("papa-mac", @claude_id),
        @codex_id => Store.get_session("papa-mac", @codex_id)
      }

      uploaded_requests = %{
        @claude_id => requests("papa-mac", @claude_id),
        @codex_id => requests("papa-mac", @codex_id)
      }

      # Then the stream.
      pair(c)
      w = start_collector(c)
      agents(c, [{@claude_id, %{"status" => "idle"}}])
      look(w)
      agents(c, [])
      mark(c, %{"hook_event_name" => "SessionEnd"})
      look(w)
      drained(w)

      for id <- [@claude_id, @codex_id] do
        streamed = saved("papa", id)
        assert streamed.source == "stream"

        for key <- @totals do
          assert {key, Map.fetch!(streamed, key)} == {key, Map.fetch!(uploaded[id], key)}
        end

        assert streamed.detail["models"] == uploaded[id].detail["models"]
        same_words(streamed, uploaded[id])

        # Tool by tool too. A tool whose name is not a plain name never
        # leaves a collector; its calls are counted under "other".
        named = fn tools -> Map.filter(tools, fn {name, _} -> name =~ ~r/\A\w+\z/ end) end

        assert named.(Map.delete(streamed.detail["tools"], "other")) ==
                 named.(uploaded[id].detail["tools"])

        assert requests("papa", id) == uploaded_requests[id]

        # The uploaded copy is gone, so the session is in the archive once.
        assert [%{machine: "papa"}] =
                 Store.query("SELECT machine FROM sessions WHERE session_id = ?1", [id])

        assert Store.query("SELECT 1 AS n FROM requests WHERE machine = 'papa-mac'", []) == []
      end

      # An upload that comes after the stream is taken and not saved.
      assert {:ok, :streamed} = Ingest.receive(up, "papa-mac", ".claude", settings)
      assert {:ok, :streamed} = Ingest.receive_codex(codex_up, "papa-mac", ".codex", settings)
      assert Store.counts().total == 2
    end
  end

  describe "killing and restarting either side" do
    # The rows the transcript reader gives for the two sessions' whole
    # files, which is what the upload path saves.
    defp undisturbed(c) do
      ctx = %{
        prices: Settings.get().usage.prices,
        machine: "ref",
        account: "main",
        size: 0,
        mtime: 0,
        now: 0
      }

      true =
        Wallboard.Archive.Collector.save_session(
          claude_path(c, @claude_id <> ".jsonl"),
          [claude_path(c, @helper_file)],
          ctx
        )

      true = Wallboard.Archive.Collector.save_codex(codex_path(c), [], %{ctx | account: nil})

      for id <- [@claude_id, @codex_id], into: %{} do
        {id, {Map.take(Store.get_session("ref", id), @totals), requests("ref", id)}}
      end
    end

    defp same_as_whole(c) do
      expected = undisturbed(c)

      for id <- [@claude_id, @codex_id] do
        {totals, reqs} = expected[id]
        streamed = saved("papa", id)

        assert Map.take(streamed, @totals) == totals
        same_words(streamed, Store.get_session("ref", id))
        assert requests("papa", id) == reqs
      end

      # Nothing is there twice: one row per line that told something, and
      # per status.
      rows = Store.collector_events("papa")
      keys = Enum.map(rows, &{&1.session_id, &1.file, &1.position, &1.at, &1.kind})
      assert keys == Enum.uniq(keys)
      rows
    end

    # The two sessions, written and reported a part at a time, with
    # `between` run at two points on the way.
    defp in_parts(c, w, between) do
      {c1, c2} = Enum.split(lines("collector/claude_session.jsonl"), 8)
      {x1, x2} = Enum.split(lines("collector/codex_rollout.jsonl"), 12)

      add(claude_path(c, @claude_id <> ".jsonl"), c1)
      add(codex_path(c), x1)
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      look(w)
      w = between.(w, 1)

      add(claude_path(c, @claude_id <> ".jsonl"), c2)
      add(claude_path(c, @helper_file), lines("collector/claude_subagent.jsonl"))
      agents(c, [{@claude_id, %{"status" => "waiting", "waitingFor" => "input needed"}}])
      look(w)
      w = between.(w, 2)

      add(codex_path(c), x2)
      agents(c, [])
      mark(c, %{"hook_event_name" => "SessionEnd"})
      look(w)
      drained(w)
      w
    end

    test "the hub, killed twice mid-stream, loses nothing and doubles nothing", c do
      start_hub(c)
      pair(c)
      w = start_collector(c)

      in_parts(c, w, fn w, _n ->
        kill_hub()
        # The collector carries on while the hub is away.
        look(w)
        start_hub(c)
        w
      end)

      rows = same_as_whole(c)
      assert Enum.count(rows, &(&1.kind == "end")) == 2
      # The cards came down with the sessions' ends, after two restarts.
      assert Sessions.cards() == []
    end

    test "the collector, killed twice mid-stream, loses nothing and doubles nothing", c do
      start_hub(c)
      pair(c)
      w = start_collector(c)

      in_parts(c, w, fn w, _n ->
        kill_collector(w)
        start_collector(c)
      end)

      same_as_whole(c)
    end

    test "a hub that lost everything it had is sent it all again", c do
      start_hub(c)
      pair(c)
      w = start_collector(c)
      both_sessions(c)
      agents(c, [{@claude_id, %{"status" => "idle"}}])
      look(w)
      drained(w)
      assert saved("papa", @claude_id) != nil

      # The database is gone; the certificates are not.
      kill_hub()
      for file <- Path.wildcard(Path.join(c.dir, "wallboard.db*")), do: File.rm(file)
      start_hub(c)

      wait_until(fn ->
        Store.collector_events("papa", @claude_id) != [] and
          Store.collector_events("papa", @codex_id) != []
      end)

      # The collector says each live session's status again, so the cards
      # are back too, with their lines.
      look(w)
      wait_until(fn -> card(@claude_id) != nil and card(@codex_id) != nil end)
      wait_until(fn -> card(@claude_id).detail.cost > 0 end)

      look(w)
      agents(c, [])
      mark(c, %{"hook_event_name" => "SessionEnd"})
      look(w)
      drained(w)
      same_as_whole(c)
    end
  end

  describe "a collector that disappears" do
    test "shows stale with the status it had, then live again on reconnect", c do
      start_hub(c)
      pair(c)
      w = start_collector(c)
      add(claude_path(c, @claude_id <> ".jsonl"), lines("collector/claude_session.jsonl"))
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      look(w)
      wait_until(fn -> card(@claude_id) != nil end)
      assert %{stale: false, status: :working, stale_since: nil} = card(@claude_id)

      kill_collector(w)
      wait_until(fn -> card(@claude_id).stale end)
      # Stale, not idle: the hub does not know what happened since.
      assert %{status: :working, stale_since: %DateTime{}} = card(@claude_id)
      # A cut-off collector's word no longer stands in for the old hooks'.
      refute Sessions.live?(@claude_id)

      w = start_collector(c)
      wait_until(fn -> not card(@claude_id).stale end)
      assert card(@claude_id).status == :working

      # What happened meanwhile arrives once it is back.
      agents(c, [{@claude_id, %{"status" => "idle"}}])
      look(w)
      wait_until(fn -> card(@claude_id).status == :idle end)
    end

    test "a hub that restarts shows the sessions it knew as stale until their machine is back",
         c do
      start_hub(c)
      pair(c)
      w = start_collector(c)
      add(claude_path(c, @claude_id <> ".jsonl"), lines("collector/claude_session.jsonl"))
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      look(w)
      wait_until(fn -> card(@claude_id) != nil end)
      drained(w)

      kill_collector(w)
      kill_hub()
      start_hub(c)
      wait_until(fn -> card(@claude_id) != nil end)
      assert %{stale: true, status: :working} = card(@claude_id)
      # Reading what it knew back sends no alert.
      refute_receive {:alert, _, _}, 1_500

      start_collector(c)
      wait_until(fn -> not card(@claude_id).stale end)
    end
  end

  describe "what the hub is told by hand" do
    defp status_row(id, state, opts) do
      event = Wallboard.Collector.Filter.status(%{session_id: id}, state, opts)

      %{
        session_id: id,
        file: "",
        position: 0,
        at: event.at,
        kind: "status",
        event: Wallboard.Collector.Proto.Event.encode(event)
      }
    end

    defp tell(rows), do: :ok = Store.put_collector_events("mama", rows, System.os_time(:second))

    test "a new wait that follows an old one in the same batch still alerts, once", c do
      start_hub(c)
      # As if its stream were open.
      Phoenix.PubSub.broadcast(Wallboard.PubSub, "link", {:link, :up, "mama"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      at = &DateTime.add(now, &1)

      tell([status_row("s-1", :needs, why: :question, since: at.(0), at: at.(0))])

      tell([
        status_row("s-1", :working, at: at.(1)),
        status_row("s-1", :needs, why: :question, since: at.(2), at: at.(2))
      ])

      assert_receive {:alert, "/slack", _}, 4_000
      assert_receive {:alert, "/topic", _}, 4_000
      # The same wait said again, as after a reconnect, sends nothing more.
      tell([status_row("s-1", :needs, why: :question, since: at.(9), at: at.(9))])
      refute_receive {:alert, _, _}, 1_800
      assert Sessions.cards() |> hd() |> Map.fetch!(:waiting_since) == at.(2)
    end

    test "an event the hub cannot add up costs that event, not the hub", c do
      start_hub(c)
      pid = Process.whereis(Sessions)
      now = DateTime.utc_now()

      bad = %Wallboard.Collector.Proto.Event{
        session_id: "s-2",
        file: "s-2.jsonl",
        position: 10,
        at: 1,
        items: [
          %Wallboard.Collector.Proto.Item{
            body: {:request, %Wallboard.Collector.Proto.Request{request_id: "r", cost: :nan}}
          }
        ]
      }

      tell([
        %{
          session_id: "s-2",
          file: "s-2.jsonl",
          position: 10,
          at: 1,
          kind: "file",
          event: Wallboard.Collector.Proto.Event.encode(bad)
        },
        status_row("s-2", :working, at: now),
        status_row("s-3", :working, at: now)
      ])

      wait_until(fn -> Enum.any?(Sessions.cards(), &(&1.session_id == "s-3")) end)
      :ok = Sessions.save()
      assert Process.whereis(Sessions) == pid
    end

    test "a wait whose machine is cut off before the alert is due still alerts, once", c do
      start_hub(c)
      Phoenix.PubSub.broadcast(Wallboard.PubSub, "link", {:link, :up, "mama"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      tell([status_row("s-4", :needs, why: :question, since: now, at: now)])
      wait_until(fn -> Sessions.cards() != [] end)

      Phoenix.PubSub.broadcast(Wallboard.PubSub, "link", {:link, :down, "mama"})
      wait_until(fn -> hd(Sessions.cards()).stale end)
      assert_receive {:alert, "/slack", _}, 4_000
      assert_receive {:alert, "/topic", _}, 4_000

      # Back, and saying the same wait again: nothing more.
      Phoenix.PubSub.broadcast(Wallboard.PubSub, "link", {:link, :up, "mama"})
      later = DateTime.add(now, 30)
      tell([status_row("s-4", :needs, why: :question, since: later, at: later)])
      refute_receive {:alert, _, _}, 1_800
    end

    test "only a collector ends a session: one it stops speaking of keeps its card", c do
      other = "0b0b0b0b-1111-4222-8333-444444444444"
      start_hub(c)
      pair(c)
      w = start_collector(c)
      busy = %{"status" => "busy"}
      agents(c, [{@claude_id, busy}, {other, busy}])
      look(w)
      wait_until(fn -> card(@claude_id) != nil and card(other) != nil end)
      drained(w)

      # The collector loses its place while one session ends, so it sends
      # no end for it. The hub does not guess.
      kill_collector(w)
      File.rm_rf!(Path.join(c.collector.collector.dir, "outbox"))
      agents(c, [{other, busy}])
      w = start_collector(c)
      look(w)
      wait_until(fn -> not card(other).stale end)
      drained(w)
      Process.sleep(500)
      assert %{status: :working, stale: false} = card(@claude_id)
      assert Enum.all?(Store.collector_events("papa", @claude_id), &(&1.kind == "status"))
    end

    test "a session that is still running keeps its card through a reconnect", c do
      start_hub(c)
      pair(c)
      w = start_collector(c)
      add(claude_path(c, @claude_id <> ".jsonl"), lines("collector/claude_session.jsonl"))
      agents(c, [{@claude_id, %{"status" => "idle"}}])
      look(w)
      wait_until(fn -> card(@claude_id) != nil end)
      drained(w)

      kill_collector(w)
      w = start_collector(c)
      wait_until(fn -> not card(@claude_id).stale end)
      # Its status has not changed, and is said again all the same.
      look(w)
      Process.sleep(900)
      assert %{status: :idle, stale: false} = card(@claude_id)
    end
  end

  test "a status said again after a connect is in the session's history once", c do
    start_hub(c)
    # The collector sees the session before it is connected, so its first
    # status is already made when the hub says where it is.
    w = start_collector(c)
    add(claude_path(c, @claude_id <> ".jsonl"), lines("collector/claude_session.jsonl"))
    agents(c, [{@claude_id, %{"status" => "busy"}}])
    look(w)

    pair(c)
    wait_until(fn -> card(@claude_id) != nil end)
    # A later second, so a status said again carries a later time.
    Process.sleep(1_100)
    look(w)
    drained(w)

    :ok = Sessions.save()
    history = Store.get_session("papa", @claude_id).events |> Enum.map(& &1.status)
    assert history == ["working"]
    # The hub still got it twice: that is how it would learn of it anew.
    statuses = Enum.filter(Store.collector_events("papa", @claude_id), &(&1.kind == "status"))
    assert length(statuses) == 2
  end

  test "a collector that is not paired sends nothing, and starts once it is", c do
    start_hub(c)
    w = start_collector(c)
    add(claude_path(c, @claude_id <> ".jsonl"), lines("collector/claude_session.jsonl"))
    agents(c, [{@claude_id, %{"status" => "busy"}}])
    look(w)
    Process.sleep(200)
    assert Store.collector_events("papa") == []
    assert Outbox.stats(w.outbox).acked == 0

    # Files that are there and are no certificate do not stop it.
    dir = c.collector.collector.dir
    for name <- ~w(cert.pem key.pem ca.pem), do: File.write!(Path.join(dir, name), "not one")
    File.write!(Path.join(dir, "hub.json"), ~s({"host":"127.0.0.1","link_port":#{c.port}}))
    Process.sleep(200)
    assert Process.alive?(w.sender)

    pair(c)
    wait_until(fn -> card(@claude_id) != nil end)
  end
end
