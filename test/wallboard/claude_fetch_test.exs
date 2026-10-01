defmodule Wallboard.ClaudeFetchTest do
  # A stand-in claude on the PATH prints the agents.json of the config
  # folder it is asked about. One at a time: the PATH is this whole test
  # run's.
  use ExUnit.Case, async: false

  alias Wallboard.Collector.{Outbox, Proto, Watcher}
  alias Wallboard.{Fixtures, Settings}
  alias Wallboard.Sources.Claude

  @stopped "5c1d0a77-3b1e-4a52-9d0c-6e2f8a4b7c11"
  @busy "9e84b3f2-6a0d-4c7e-8f15-2d3b9a7c4e60"
  @idle "c70f2a19-8d44-4b3a-a6e2-51f0c9d7b382"
  @terminal "1b6e9d04-f2a7-4e58-b3c1-7a0d5e8f2c93"

  # A throwaway home whose Claude folder lists a job that ended or was
  # stopped (state "working", no pid, no status) beside three
  # sessions that are running.
  setup do
    home = Fixtures.tmp_path("claude-fetch-home")
    bin = Path.join(home, "bin")
    dir = Path.join(home, ".claude")
    File.mkdir_p!(bin)
    # A collector takes a folder with projects in it as a Claude folder.
    File.mkdir_p!(Path.join(dir, "projects"))

    File.write!(Path.join(bin, "claude"), """
    #!/bin/sh
    cat "$CLAUDE_CONFIG_DIR/agents.json"
    """)

    File.chmod!(Path.join(bin, "claude"), 0o755)
    File.write!(Path.join(dir, "agents.json"), Fixtures.read!("claude/agents_stopped_job.json"))

    old = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> old)

    on_exit(fn ->
      System.put_env("PATH", old)
      File.rm_rf!(home)
    end)

    %{home: home, dir: dir}
  end

  test "only a row that nothing says is running is left out" do
    {:ok, agents} = Claude.parse_agents(Fixtures.read!("claude/agents_stopped_job.json"))
    stopped = Enum.find(agents, &(&1.session_id == @stopped))

    assert %{state: "working", status: nil, pid: nil} = stopped
    assert Enum.map(Claude.live(agents), & &1.session_id) == [@busy, @idle, @terminal]

    # A session that needs you, or still has a status, stays even with no pid.
    assert Claude.live([%{stopped | state: "blocked"}]) != []
    assert Claude.live([%{stopped | status: "waiting"}]) != []
    assert Claude.live([%{stopped | status: "busy"}]) != []
    assert Claude.live([%{stopped | state: "done"}]) == []
  end

  test "on the board's own machine a stopped job gives no card and is not counted", c do
    settings = Settings.merge(Settings.defaults(), %{claude: %{config_dirs: [c.dir]}})

    assert {:ok, %{sessions: sessions, problems: []}, tracking} =
             Claude.poll(settings, nil, nil, ~U[2026-10-01 16:03:00Z])

    refute Enum.any?(sessions, &(&1.session_id == @stopped))
    refute Enum.any?(Map.keys(tracking), &(&1 =~ @stopped))

    # The running sessions' cards are as they were.
    cards = for s <- sessions, into: %{}, do: {s.session_id, {s.name, s.kind, s.status}}

    assert cards == %{
             @busy => {"shop-2061", "background", :working},
             @idle => {"planner", "background", :idle},
             @terminal => {"fixing-prod", "interactive", :working}
           }

    assert Enum.count(sessions, &(&1.status == :working)) == 2
  end

  test "a collector says nothing of a stopped job, and the running ones as before", c do
    settings =
      Settings.defaults()
      |> Settings.merge(%{role: "collector", collector: %{dir: Path.join(c.home, "state")}})
      |> Settings.normalize()

    outbox =
      start_supervised!(
        {Outbox, [dir: Path.join(settings.collector.dir, "outbox"), name: nil]},
        id: :outbox
      )

    # No `claude:` here, so the collector asks the stand-in claude itself.
    watcher =
      start_supervised!(
        {Watcher,
         name: nil, outbox: outbox, home: c.home, timer: false, settings: fn -> settings end},
        id: :watcher
      )

    # The first look only finds its place in the files.
    :ok = Watcher.tick(watcher)
    :ok = Watcher.tick(watcher)

    said =
      for {_seq, %Proto.Event{items: [%Proto.Item{body: {:status, s}}]} = e} <-
            Outbox.read(outbox, 0, 100_000),
          do: {e.session_id, s.state}

    assert Enum.sort(said) ==
             Enum.sort([{@busy, :WORKING}, {@idle, :IDLE}, {@terminal, :WORKING}])
  end
end
