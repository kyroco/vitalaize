defmodule Wallboard.CollectorWatcherTest do
  use ExUnit.Case, async: true

  alias Wallboard.Collector.{Filter, Outbox, Proto, Watcher}
  alias Wallboard.Fixtures
  alias Wallboard.Settings
  alias Wallboard.Sources.Claude

  @claude_id "d299768e-2531-4395-a7ec-bf457e22c263"
  @codex_id "01a0c9db-3044-75f0-99fe-345bf658a60b"
  @codex_file "2026/09/29/rollout-2026-09-29T14-00-00-" <> @codex_id <> ".jsonl"

  # A throwaway home with a Claude folder and a Codex folder, a clock the
  # test moves, and what `claude agents` would say for each Claude folder.
  setup do
    home = Fixtures.tmp_path("collector-home")
    File.mkdir_p!(Path.join(home, ".claude/projects/-Users-r-projects-shop"))
    File.mkdir_p!(Path.join(home, ".codex/sessions/2026/09/29"))
    on_exit(fn -> File.rm_rf!(home) end)

    {:ok, world} =
      Agent.start_link(fn ->
        %{now: DateTime.utc_now() |> DateTime.truncate(:second), agents: %{}}
      end)

    settings =
      Settings.defaults()
      |> Settings.merge(%{role: "collector", collector: %{dir: Path.join(home, "state")}})
      |> Settings.normalize()

    %{home: home, world: world, settings: settings}
  end

  defp start(c, opts \\ []) do
    outbox =
      start_supervised!(
        {Outbox, [dir: Path.join(c.settings.collector.dir, "outbox"), name: nil] ++ opts},
        id: :outbox
      )

    world = c.world

    watcher =
      start_supervised!(
        {Watcher,
         name: nil,
         outbox: outbox,
         home: c.home,
         timer: Keyword.get(opts, :timer, false),
         settings: fn -> c.settings end,
         now: fn -> Agent.get(world, & &1.now) end,
         claude: fn dir -> Agent.get(world, &Map.get(&1.agents, dir, {:ok, []})) end},
        id: :watcher
      )

    %{outbox: outbox, watcher: watcher}
  end

  defp stop do
    :ok = stop_supervised(:watcher)
    :ok = stop_supervised(:outbox)
  end

  # Everything in the outbox, oldest first.
  defp sent(%{outbox: outbox}), do: outbox |> Outbox.read(0, 100_000) |> Enum.map(&elem(&1, 1))

  # What one more look adds to the outbox.
  defp look(%{outbox: outbox, watcher: watcher}) do
    before = Map.get(Outbox.stats(outbox), :seq, 0)
    :ok = Watcher.tick(watcher)
    outbox |> Outbox.read(before, 100_000) |> Enum.map(&elem(&1, 1))
  end

  defp claude_dir(c), do: Path.join(c.home, ".claude")

  defp claude_path(c, name),
    do: Path.join([claude_dir(c), "projects/-Users-r-projects-shop", name])

  defp codex_path(c), do: Path.join([c.home, ".codex/sessions", @codex_file])

  defp lines(name), do: name |> Fixtures.read!() |> String.split("\n", trim: true)
  defp text(lines), do: Enum.map_join(lines, &(&1 <> "\n"))

  defp add(path, lines) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text(lines), [:append])
  end

  # What `claude agents` reports for the session, as the board reads it.
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

  # The events the filter gives for a file read in one go.
  defp filtered(ctx, lines, c) do
    {events, _} =
      ctx
      |> Map.put(:prices, c.settings.usage.prices)
      |> Filter.new()
      |> Filter.read(text(lines))

    events
  end

  defp claude_ctx,
    do: %{tool: :claude, session_id: @claude_id, file: @claude_id <> ".jsonl", account: "main"}

  defp codex_ctx, do: %{tool: :codex, session_id: @codex_id, file: @codex_file}

  defp statuses(events) do
    for %Proto.Event{items: [%Proto.Item{body: {:status, s}}]} = e <- events,
        do: {e.session_id, s.state, s.why, s.tool}
  end

  defp ended(events) do
    for %Proto.Event{items: [%Proto.Item{body: {:ended, _}}]} = e <- events, do: e.session_id
  end

  defp from_files(events), do: Enum.filter(events, &(&1.file != ""))

  defp mark(c, body) do
    path = Path.join([c.home, ".codex/vitalaize", @codex_id <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(Map.put(body, "session_id", @codex_id)))
  end

  describe "a Claude session" do
    test "start, new lines, working to waiting to idle, and its end, in order", c do
      all = lines("collector/claude_session.jsonl")
      {first, rest} = Enum.split(all, 3)
      path = claude_path(c, @claude_id <> ".jsonl")
      w = start(c)

      assert look(w) == []

      # A new session: its first lines, then that it is working.
      add(path, first)
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      new = look(w)
      assert from_files(new) == filtered(claude_ctx(), first, c)
      assert [%Proto.Event{items: [%Proto.Item{body: {:started, started}} | _]} | _] = new
      assert started == %Proto.SessionStarted{tool: :CLAUDE, account: "main"}
      assert statuses(new) == [{@claude_id, :WORKING, :WHY_UNKNOWN, ""}]
      assert List.last(new).file == ""

      # New lines give only their own events, at their own places.
      add(path, rest)
      new = look(w)

      assert new ==
               Enum.drop(filtered(claude_ctx(), all, c), length(filtered(claude_ctx(), first, c)))

      assert List.last(new).position == File.stat!(path).size

      agents(c, [{@claude_id, %{"status" => "waiting", "waitingFor" => "permission prompt"}}])
      assert statuses(look(w)) == [{@claude_id, :WAITING, :PERMISSION, ""}]
      # Nothing changed, so nothing is said twice.
      assert look(w) == []

      agents(c, [{@claude_id, %{"status" => "idle"}}])
      assert statuses(look(w)) == [{@claude_id, :IDLE, :WHY_UNKNOWN, ""}]

      agents(c, [])
      assert ended(look(w)) == [@claude_id]
      assert look(w) == []

      # The whole outbox, in order: every position of the file going up.
      positions = w |> sent() |> from_files() |> Enum.map(& &1.position)
      assert positions == Enum.sort(positions) and positions == Enum.uniq(positions)
      assert w |> sent() |> from_files() == filtered(claude_ctx(), all, c)
    end

    test "a background session blocked with no kind given waits for another reason", c do
      w = start(c)
      agents(c, [{@claude_id, %{"kind" => "background", "state" => "blocked"}}])
      assert statuses(look(w)) == [{@claude_id, :WAITING, :OTHER, ""}]
    end

    test "when `claude agents` fails, no session is taken as ended", c do
      w = start(c)
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      assert [_] = look(w)

      Agent.update(
        c.world,
        &put_in(&1.agents[claude_dir(c)], {:error, "claude is not installed"})
      )

      assert look(w) == []
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      assert look(w) == []
    end

    test "a helper agent's file goes out under its session, marked as a helper's", c do
      main = lines("collector/claude_session.jsonl")
      helper = lines("collector/claude_subagent.jsonl")
      file = @claude_id <> "/subagents/agent-a1.jsonl"
      add(claude_path(c, @claude_id <> ".jsonl"), main)
      add(claude_path(c, file), helper)
      w = start(c)

      new = look(w)
      ctx = Map.merge(claude_ctx(), %{file: file, subagent: true})
      # The session's own file first, then its helper's.
      assert new == filtered(claude_ctx(), main, c) ++ filtered(ctx, helper, c)
      assert Enum.all?(filtered(ctx, helper, c), &(&1.subagent and &1.session_id == @claude_id))
    end

    test "every session counts, whatever its folder, and each names its GitHub repo", c do
      repo = Path.join(c.home, "code/shop")
      File.mkdir_p!(Path.join(repo, ".git"))

      File.write!(
        Path.join(repo, ".git/config"),
        ~s([remote "origin"]\n\turl = git@github.com:acme/shop.git\n)
      )

      other = Path.join(c.home, "notes")

      for {id, cwd, project} <- [{"aaaa-1", repo, "-code-shop"}, {"bbbb-2", other, "-notes"}] do
        line =
          Jason.encode!(%{
            type: "user",
            timestamp: "2026-09-29T13:00:00.000Z",
            cwd: cwd,
            sessionId: id,
            message: %{role: "user", content: "hello"}
          })

        add(Path.join([claude_dir(c), "projects", project, id <> ".jsonl"]), [line])
      end

      w = start(c)

      repos =
        for %Proto.Event{session_id: id, items: items} <- look(w),
            %Proto.Item{body: {:summary, s}} <- items,
            do: {id, s.folder, s.repo}

      assert repos == [{"aaaa-1", repo, "acme/shop"}, {"bbbb-2", other, ""}]
    end
  end

  describe "a Codex session" do
    test "start, new lines, working to waiting to idle, and its end, in order", c do
      all = lines("collector/codex_rollout.jsonl")
      # The first turn, up to the line before it finishes.
      {running, rest} = Enum.split(all, 12)
      {finish, _later} = Enum.split(rest, 1)
      w = start(c)

      add(codex_path(c), running)
      new = look(w)
      assert from_files(new) == filtered(codex_ctx(), running, c)
      assert [%Proto.Event{items: [%Proto.Item{body: {:started, started}} | _]} | _] = new
      assert started.tool == :CODEX
      assert statuses(new) == [{@codex_id, :WORKING, :WHY_UNKNOWN, ""}]

      # The collector keeps the Codex hook in place, as the board does.
      assert File.read!(Path.join(c.home, ".codex/vitalaize/hook.sh")) ==
               Wallboard.Sources.Codex.hook_script()

      # Codex asks to run something: only the kind of wait and the tool's
      # name go out, never the command.
      mark(c, %{
        "hook_event_name" => "PermissionRequest",
        "tool_name" => "shell",
        "tool_input" => %{"command" => "git push --token PLANTED_COMMAND_SECRET"}
      })

      new = look(w)
      assert statuses(new) == [{@codex_id, :WAITING, :PERMISSION, "shell"}]
      assert look(w) == []

      # Approved: the command ran.
      mark(c, %{"hook_event_name" => "PostToolUse", "tool_name" => "shell"})
      assert statuses(look(w)) == [{@codex_id, :WORKING, :WHY_UNKNOWN, ""}]

      # The turn finishes.
      add(codex_path(c), finish)
      new = look(w)

      assert from_files(new) ==
               Enum.drop(
                 filtered(codex_ctx(), running ++ finish, c),
                 length(filtered(codex_ctx(), running, c))
               )

      assert statuses(new) == [{@codex_id, :IDLE, :WHY_UNKNOWN, ""}]

      # The person quits Codex.
      mark(c, %{"hook_event_name" => "SessionEnd"})
      assert ended(look(w)) == [@codex_id]
      assert look(w) == []

      events = sent(w)
      assert from_files(events) == filtered(codex_ctx(), running ++ finish, c)
      wire = Enum.map_join(events, &Proto.Event.encode/1)
      refute wire =~ "PLANTED"
      refute wire =~ "git push"
    end

    test "one quiet for longer than it stays on the Live tab has ended", c do
      add(codex_path(c), lines("collector/codex_rollout.jsonl"))
      w = start(c)
      assert statuses(look(w)) == [{@codex_id, :IDLE, :WHY_UNKNOWN, ""}]

      minutes = c.settings.codex.idle_minutes + 1
      Agent.update(c.world, &%{&1 | now: DateTime.add(&1.now, minutes * 60)})
      assert ended(look(w)) == [@codex_id]
      assert look(w) == []
    end
  end

  describe "a chat the Codex app copied in" do
    @copy_id "01a0f8bc-44e8-7b10-80e4-85e969625028"
    @copy_file "2026/10/01/rollout-2026-10-01T14-31-23-" <> @copy_id <> ".jsonl"
    # The conversation happened two days before it was copied.
    @began DateTime.to_unix(~U[2026-09-29 12:54:31Z])

    defp copy_path(c), do: Path.join([c.home, ".codex/sessions", @copy_file])

    defp copy_in(c) do
      now = Agent.get(c.world, & &1.now)
      add(copy_path(c), Fixtures.codex_copy(@copy_id, now, [{@began, @began + 42}]))
      now
    end

    # What Codex notes about a chat it copied from a Claude session.
    defp imported(c, at) do
      source = Path.join(claude_dir(c), "projects/-Users-r-projects-shop/source.jsonl")
      File.write!(source, "")

      File.write!(
        Path.join(c.home, ".codex/external_agent_session_imports.json"),
        Jason.encode!(%{
          records: [
            %{
              source_path: source,
              imported_thread_id: @copy_id,
              imported_at: DateTime.to_unix(at)
            }
          ]
        })
      )
    end

    # Someone opens the copied chat in Codex and types, a quarter of an
    # hour on.
    defp carry_on(c) do
      Agent.update(c.world, &%{&1 | now: DateTime.add(&1.now, 900)})
      at = Agent.get(c.world, & &1.now)

      add(copy_path(c), [
        Jason.encode!(%{
          timestamp: DateTime.to_iso8601(at),
          type: "event_msg",
          payload: %{type: "task_started", started_at: DateTime.to_unix(at)}
        })
      ])

      File.touch!(copy_path(c), DateTime.to_unix(at))
    end

    test "is never sent as live work, and reaches the hub on the days it happened", c do
      copy_in(c)
      w = start(c)
      # Codex writes its list of what it copied just after the files, so a
      # copy only just written waits a few seconds for it.
      assert look(w) == []
      Agent.update(c.world, &%{&1 | now: DateTime.add(&1.now, 10)})
      new = look(w)

      assert from_files(new) != []
      assert statuses(new) == []
      assert ended(new) == []
      assert look(w) == []

      # The hub saves it from these events, with the conversation's own times.
      session =
        Enum.reduce(new, Wallboard.Link.Session.new("papa", @copy_id), fn event, s ->
          Wallboard.Link.Session.apply(s, event)
        end)

      refute Wallboard.Link.Session.live?(session)
      assert {row, []} = Wallboard.Link.Session.record(session, %{}, 0)
      assert {row.tool, row.prompts} == {"codex", 1}
      assert {row.started_at, row.ended_at} == {@began, @began + 42}
    end

    test "a copy of a Claude session this collector sends is not sent again", c do
      imported(c, copy_in(c))
      w = start(c)
      assert look(w) == []
      Agent.update(c.world, &%{&1 | now: DateTime.add(&1.now, 10)})
      assert look(w) == []

      # Carried on in Codex, it is a Codex session from then on.
      carry_on(c)
      new = look(w)
      assert [%Proto.Event{file: @copy_file} | _] = from_files(new)
      assert statuses(new) == [{@copy_id, :WORKING, :WHY_UNKNOWN, ""}]
    end

    test "a collector that had said a copy was live takes it back at its next look", c do
      copy_in(c)
      dir = Path.join(c.settings.collector.dir, "outbox")
      outbox = start_supervised!({Outbox, dir: dir, name: nil}, id: :before)

      # What a collector from before this fix saved: the file read to its
      # end, and the copy reported as an idle session.
      Outbox.append(
        outbox,
        [],
        Jason.encode!(%{
          offsets: %{copy_path(c) => File.stat!(copy_path(c)).size},
          heads: %{},
          statuses: [["codex", @copy_id, nil, "idle", "WHY_UNKNOWN", ""]]
        })
      )

      :ok = stop_supervised(:before)

      w = start(c)
      new = look(w)
      assert ended(new) == [@copy_id]
      assert statuses(new) == []
      assert look(w) == []
    end
  end

  describe "a restart" do
    test "carries on from the saved places and repeats nothing", c do
      all = lines("collector/claude_session.jsonl")
      {first, rest} = Enum.split(all, 10)
      {while_down, last} = Enum.split(rest, 5)
      path = claude_path(c, @claude_id <> ".jsonl")
      add(path, first)
      add(codex_path(c), lines("collector/codex_rollout.jsonl"))
      agents(c, [{@claude_id, %{"status" => "busy"}}])

      w = start(c)
      before = look(w)
      assert before != []
      stop()

      # Nothing changed while it was down: nothing is said again.
      w = start(c)
      assert look(w) == []
      assert sent(w) == before
      stop()

      # Lines written while it was down go out once it is back, and only
      # those, with the file's totals as if it had never stopped.
      add(path, while_down)
      w = start(c)
      look(w)
      add(path, last)
      look(w)

      events = sent(w)

      assert Enum.filter(events, &(&1.file == @claude_id <> ".jsonl")) ==
               filtered(claude_ctx(), all, c)

      assert Enum.filter(events, &(&1.file == @codex_file)) ==
               filtered(codex_ctx(), lines("collector/codex_rollout.jsonl"), c)

      assert statuses(events) == [
               {@claude_id, :WORKING, :WHY_UNKNOWN, ""},
               {@codex_id, :IDLE, :WHY_UNKNOWN, ""}
             ]

      assert ended(events) == []
    end

    test "a session that ended while the collector was down is reported as ended", c do
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      w = start(c)
      assert [_] = look(w)
      stop()

      agents(c, [])
      w = start(c)
      assert ended(look(w)) == [@claude_id]
    end
  end

  describe "going back to the hub's place" do
    test "a file the hub has less of is read again from the hub's place, in order", c do
      all = lines("collector/claude_session.jsonl")
      path = claude_path(c, @claude_id <> ".jsonl")
      add(path, all)
      w = start(c)
      whole = filtered(claude_ctx(), all, c)
      assert from_files(look(w)) == whole
      before = Outbox.stats(w.outbox).seq
      key = {@claude_id, @claude_id <> ".jsonl"}

      # The hub has all of it: nothing to do.
      hub = %{key => List.last(whole).position}
      assert Watcher.rewind(w.watcher, hub) == {:ok, [], before}
      assert look(w) == []

      # The hub has only the first five lines that told something.
      at = Enum.at(whole, 4).position
      assert {:ok, [file], ^before} = Watcher.rewind(w.watcher, %{key => at})
      assert file == @claude_id <> ".jsonl"
      # The rest is in the outbox again, after everything made before.
      again = w.outbox |> Outbox.read(before, 1_000) |> Enum.map(&elem(&1, 1))
      assert again == Enum.drop(whole, 5)
      assert look(w) == []

      # The hub knows nothing of a file that changed lately: all of it again.
      seq = Outbox.stats(w.outbox).seq
      assert {:ok, [^file], ^seq} = Watcher.rewind(w.watcher, %{})
      assert w.outbox |> Outbox.read(seq, 1_000) |> Enum.map(&elem(&1, 1)) == whole

      # It holds across a restart: the place saved is the one gone back to.
      stop()
      w = start(c)
      assert look(w) == []
    end

    test "a file the hub no longer names, and that is old, is left alone", c do
      path = claude_path(c, @claude_id <> ".jsonl")
      add(path, lines("collector/claude_session.jsonl"))
      w = start(c)
      assert look(w) != []
      days = Wallboard.Link.limits().resume_days + 1
      File.touch!(path, System.os_time(:second) - days * 86_400)
      assert look(w) == []

      seq = Outbox.stats(w.outbox).seq
      assert Watcher.rewind(w.watcher, %{}) == {:ok, [], seq}
      assert look(w) == []
    end

    test "an outbox that cannot save the new place changes nothing", c do
      path = claude_path(c, @claude_id <> ".jsonl")
      add(path, lines("collector/claude_session.jsonl"))
      w = start(c)
      sent = look(w)
      assert sent != []
      dir = Path.join(c.settings.collector.dir, "outbox")
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod(dir, 0o700) end)

      assert Watcher.rewind(w.watcher, %{}) == :retry

      File.chmod!(dir, 0o700)
      seq = Outbox.stats(w.outbox).seq
      assert {:ok, [_], ^seq} = Watcher.rewind(w.watcher, %{})
      assert w.outbox |> Outbox.read(seq, 1_000) |> Enum.map(&elem(&1, 1)) == from_files(sent)
    end
  end

  describe "what is read, and when" do
    test "an old session is left alone until it changes, then goes out whole", c do
      all = lines("collector/claude_session.jsonl")
      {first, rest} = Enum.split(all, 10)
      path = claude_path(c, @claude_id <> ".jsonl")
      add(path, first)
      days = c.settings.collector.backfill_days + 1
      File.touch!(path, System.os_time(:second) - days * 86_400)

      w = start(c)
      assert look(w) == []

      add(path, rest)
      assert look(w) == filtered(claude_ctx(), all, c)
    end

    test "a full outbox makes it wait, and nothing is lost or repeated", c do
      claude = lines("collector/claude_session.jsonl")
      codex = lines("collector/codex_rollout.jsonl")
      add(claude_path(c, @claude_id <> ".jsonl"), claude)
      add(codex_path(c), codex)
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      w = start(c, max_bytes: 100)

      # The files' events fill it; the statuses wait.
      assert look(w) == filtered(claude_ctx(), claude, c) ++ filtered(codex_ctx(), codex, c)
      assert look(w) == []

      Outbox.ack(w.outbox, Outbox.stats(w.outbox).seq)

      assert statuses(look(w)) == [
               {@claude_id, :WORKING, :WHY_UNKNOWN, ""},
               {@codex_id, :IDLE, :WHY_UNKNOWN, ""}
             ]
    end

    test "a long file goes out a couple of hundred events at a time, picking up where it stopped",
         c do
      # Every line is a new prompt, so every line gives an event.
      many =
        for n <- 1..1_000 do
          Jason.encode!(%{
            type: "user",
            timestamp: "2026-09-29T13:00:00.000Z",
            cwd: "/Users/r/projects/shop",
            sessionId: @claude_id,
            message: %{role: "user", content: "prompt number #{n}"}
          })
        end

      add(claude_path(c, @claude_id <> ".jsonl"), many)
      w = start(c, max_bytes: 100)
      want = filtered(claude_ctx(), many, c)
      assert length(want) == 1_000

      rounds =
        Enum.map(1..5, fn _ ->
          new = look(w)
          Outbox.ack(w.outbox, Outbox.stats(w.outbox).seq)
          new
        end)

      assert Enum.map(rounds, &length/1) == [200, 200, 200, 200, 200]
      assert Enum.concat(rounds) == want
      assert look(w) == []
    end

    test "a session file that got shorter is read as new", c do
      all = lines("collector/claude_session.jsonl")
      path = claude_path(c, @claude_id <> ".jsonl")
      add(path, all)
      w = start(c)
      assert look(w) == filtered(claude_ctx(), all, c)

      short = Enum.take(all, 4)
      File.write!(path, text(short))
      assert look(w) == filtered(claude_ctx(), short, c)
    end

    test "a line still being written waits for its end", c do
      [first, second | _] = lines("collector/claude_session.jsonl")
      path = claude_path(c, @claude_id <> ".jsonl")
      {head, tail} = String.split_at(second, 100)
      File.write!(path, first <> "\n" <> head)
      w = start(c)

      assert look(w) == filtered(claude_ctx(), [first], c)
      assert look(w) == []

      File.write!(path, tail <> "\n", [:append])
      assert look(w) == Enum.drop(filtered(claude_ctx(), [first, second], c), 1)
    end

    test "nothing private is on disk in the collector's folder", c do
      add(claude_path(c, @claude_id <> ".jsonl"), lines("collector/claude_session.jsonl"))
      add(codex_path(c), lines("collector/codex_rollout.jsonl"))
      w = start(c)
      assert look(w) != []

      for path <- Path.wildcard(Path.join(c.settings.collector.dir, "**")), File.regular?(path) do
        refute File.read!(path) =~ "PLANTED"
      end
    end
  end

  describe "cases the reviews found" do
    test "a restart does not end a Codex session that still waits on an approval", c do
      add(codex_path(c), Enum.take(lines("collector/codex_rollout.jsonl"), 12))
      mark(c, %{"hook_event_name" => "PermissionRequest", "tool_name" => "shell"})
      w = start(c)
      assert statuses(look(w)) == [{@codex_id, :WAITING, :PERMISSION, "shell"}]

      # Hours later it still waits; its file has been quiet all that time.
      minutes = c.settings.codex.idle_minutes + 30
      Agent.update(c.world, &%{&1 | now: DateTime.add(&1.now, minutes * 60)})
      assert look(w) == []
      stop()

      w = start(c)
      assert look(w) == []
      assert look(w) == []
    end

    test "an approval request on a Codex file already put away is still reported", c do
      add(codex_path(c), Enum.take(lines("collector/codex_rollout.jsonl"), 12))
      w = start(c)
      assert statuses(look(w)) == [{@codex_id, :WORKING, :WHY_UNKNOWN, ""}]

      minutes = c.settings.codex.idle_minutes + 1
      Agent.update(c.world, &%{&1 | now: DateTime.add(&1.now, minutes * 60)})
      assert ended(look(w)) == [@codex_id]

      mark(c, %{"hook_event_name" => "PermissionRequest", "tool_name" => "shell"})
      assert statuses(look(w)) == [{@codex_id, :WAITING, :PERMISSION, "shell"}]
      assert look(w) == []
    end

    test "a session listed twice gets one status, not two on every look", c do
      w = start(c)
      agents(c, [{@claude_id, %{"status" => "busy"}}, {@claude_id, %{"status" => "idle"}}])
      assert statuses(look(w)) == [{@claude_id, :WORKING, :WHY_UNKNOWN, ""}]
      assert look(w) == []
      assert look(w) == []
    end

    test "a session file replaced by a longer one is read as new", c do
      all = lines("collector/claude_session.jsonl")
      path = claude_path(c, @claude_id <> ".jsonl")
      add(path, all)
      w = start(c)
      assert look(w) == filtered(claude_ctx(), all, c)

      [first | rest] = all
      other = [String.replace(first, "Fix the login loop", "Fix the logout loop too") | rest]
      File.write!(path, text(other))
      assert look(w) == filtered(claude_ctx(), other, c)
      stop()

      # The same holds when the collector was down as it happened.
      File.write!(path, text(all ++ Enum.take(all, -1)))
      w = start(c)
      assert look(w) == filtered(claude_ctx(), all ++ Enum.take(all, -1), c)
    end

    @tag :capture_log
    test "an outbox that cannot be written makes it wait, then nothing is lost or repeated", c do
      all = lines("collector/claude_session.jsonl")
      w = start(c)
      assert look(w) == []
      dir = Path.join(c.settings.collector.dir, "outbox")

      File.chmod!(dir, 0o500)
      add(claude_path(c, @claude_id <> ".jsonl"), all)
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      assert look(w) == []
      assert look(w) == []
      assert Process.alive?(w.watcher) and Process.alive?(w.outbox)

      File.chmod!(dir, 0o700)
      new = look(w)
      assert from_files(new) == filtered(claude_ctx(), all, c)
      assert statuses(new) == [{@claude_id, :WORKING, :WHY_UNKNOWN, ""}]
      assert look(w) == []
    end

    @tag :capture_log
    test "an outbox that cannot be read at a start makes it wait, and nothing goes out twice",
         c do
      all = lines("collector/claude_session.jsonl")
      add(claude_path(c, @claude_id <> ".jsonl"), all)
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      w = start(c)
      before = look(w)
      assert before != []
      stop()

      dir = Path.join(c.settings.collector.dir, "outbox")
      [file] = Path.wildcard(Path.join(dir, "events-*.log"))
      File.chmod!(file, 0o000)
      w = start(c)
      assert look(w) == []
      assert look(w) == []

      File.chmod!(file, 0o600)
      assert look(w) == []
      assert sent(w) == before
    end

    test "a Codex file with a bad line costs only its own session its status", c do
      add(codex_path(c), lines("collector/codex_rollout.jsonl"))
      other = "01a0c9db-3044-75f0-99fe-000000000bad"

      bad = [
        Jason.encode!(%{
          timestamp: "2026-09-29T15:00:00.000Z",
          type: "session_meta",
          payload: %{id: other, cwd: "/tmp", originator: "Codex Desktop"}
        }),
        Jason.encode!(%{type: "session_meta", payload: %{id: %{a: "b"}, cwd: %{x: 1}}})
      ]

      name = "rollout-2026-09-29T15-00-00-" <> other <> ".jsonl"
      add(Path.join([c.home, ".codex/sessions/2026/09/29", name]), bad)
      w = start(c)

      assert {@codex_id, :IDLE, :WHY_UNKNOWN, ""} in statuses(look(w))
      assert look(w) == []
    end

    test "a tool name that is not one never reaches the collector's saved place", c do
      add(codex_path(c), Enum.take(lines("collector/codex_rollout.jsonl"), 12))

      mark(c, %{
        "hook_event_name" => "PermissionRequest",
        "tool_name" => "curl -H 'Authorization: Bearer PLANTED_TOOL_SECRET'"
      })

      w = start(c)
      assert statuses(look(w)) == [{@codex_id, :WAITING, :PERMISSION, ""}]
      assert look(w) == []
      refute File.read!(Path.join(c.settings.collector.dir, "outbox/state")) =~ "PLANTED"
    end

    test "a session listed under two folders does not end when one of them drops it", c do
      work = Path.join(c.home, ".claude-work")
      File.mkdir_p!(Path.join(work, "projects"))
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      listed = Agent.get(c.world, & &1.agents[claude_dir(c)])
      Agent.update(c.world, &put_in(&1.agents[work], listed))
      w = start(c)
      assert statuses(look(w)) == [{@claude_id, :WORKING, :WHY_UNKNOWN, ""}]

      agents(c, [])
      assert look(w) == []
      assert look(w) == []

      Agent.update(c.world, &put_in(&1.agents[work], {:ok, []}))
      assert ended(look(w)) == [@claude_id]
    end

    test "a session whose folder is no longer watched has ended", c do
      agents(c, [{@claude_id, %{"status" => "busy"}}])
      add(codex_path(c), lines("collector/codex_rollout.jsonl"))
      w = start(c)
      assert length(statuses(look(w))) == 2
      stop()

      settings =
        c.settings
        |> put_in([:collector, :claude_dirs], [])
        |> put_in([:codex, :enabled], false)

      w = start(%{c | settings: settings})
      assert ended(look(w)) == [@claude_id, @codex_id]
      assert look(w) == []
    end
  end

  describe "the folders" do
    test "the collector finds its own Claude and Codex folders and tells the hub", c do
      # A second login, a folder with nothing of Claude's in it, and a file.
      File.mkdir_p!(Path.join(c.home, ".claude-work"))
      File.write!(Path.join(c.home, ".claude-work/settings.json"), "{}")
      File.mkdir_p!(Path.join(c.home, ".claude-empty"))
      File.write!(Path.join(c.home, ".claude.json"), "{}")

      found = Watcher.folders(c.settings, c.home)

      assert found == %{
               claude: [Path.join(c.home, ".claude"), Path.join(c.home, ".claude-work")],
               codex: [Path.join(c.home, ".codex")]
             }

      w = start(c)
      hello = Watcher.hello(w.watcher)
      assert hello.folders == found.claude ++ found.codex
      assert hello.version == to_string(Application.spec(:wallboard, :vsn))
      assert hello.machine != "" and hello.os != ""
    end

    test "folders in the settings file replace the search, and Codex can be off", c do
      settings =
        c.settings
        |> put_in([:collector, :claude_dirs], ["/somewhere/claude"])
        |> put_in([:codex, :enabled], false)

      assert Watcher.folders(settings, c.home) == %{claude: ["/somewhere/claude"], codex: []}
    end

    test "a session under a second login is reported with that login's name", c do
      File.mkdir_p!(Path.join(c.home, ".claude-work/projects/-p"))
      path = Path.join([c.home, ".claude-work/projects/-p", @claude_id <> ".jsonl"])
      add(path, Enum.take(lines("collector/claude_session.jsonl"), 2))
      w = start(c)

      assert [%Proto.Event{items: [%Proto.Item{body: {:started, started}} | _]} | _] = look(w)
      assert started.account == "work"
    end
  end

  test "left alone, it looks by itself on its timer", c do
    all = lines("collector/claude_session.jsonl")
    {first, rest} = Enum.split(all, 3)
    path = claude_path(c, @claude_id <> ".jsonl")
    add(path, first)
    agents(c, [{@claude_id, %{"status" => "busy"}}])
    settings = put_in(c.settings, [:collector, :poll_seconds], 1)
    w = start(%{c | settings: settings}, timer: true)

    wait = fn wanted ->
      Enum.find_value(1..100, fn _ ->
        events = sent(w)
        if length(events) >= wanted, do: events, else: Process.sleep(50) && nil
      end)
    end

    want = length(filtered(claude_ctx(), first, c)) + 1
    assert statuses(wait.(want)) == [{@claude_id, :WORKING, :WHY_UNKNOWN, ""}]

    add(path, rest)
    events = wait.(length(filtered(claude_ctx(), all, c)) + 1)
    assert from_files(events) == filtered(claude_ctx(), all, c)
  end
end
