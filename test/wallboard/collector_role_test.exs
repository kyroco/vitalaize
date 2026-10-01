defmodule Wallboard.CollectorRoleTest do
  # Not async: it sets the settings every process reads and looks at every
  # listening port in the test run.
  use ExUnit.Case, async: false

  alias Wallboard.Collector.{Outbox, Watcher}
  alias Wallboard.Fixtures
  alias Wallboard.Settings

  @key {Settings, :settings}

  setup do
    dir = Fixtures.tmp_path("collector-role")
    File.mkdir_p!(Path.join(dir, "codex/sessions"))
    saved = :persistent_term.get(@key, nil)
    endpoint = Application.get_env(:wallboard, WallboardWeb.Endpoint)

    on_exit(fn ->
      if saved, do: :persistent_term.put(@key, saved), else: :persistent_term.erase(@key)
      Application.put_env(:wallboard, WallboardWeb.Endpoint, endpoint)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # Throwaway folders only: no Claude folder, so `claude` is never run, and
  # a Codex folder of its own.
  defp settings(role, dir) do
    Settings.defaults()
    |> Settings.merge(%{
      role: role,
      port: free_port(),
      archive: %{path: Path.join(dir, "wallboard.db"), advertise: false},
      collector: %{
        dir: Path.join(dir, "collector"),
        claude_dirs: [],
        codex_dirs: [Path.join(dir, "codex")]
      }
    })
    |> Settings.normalize()
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp ids(children), do: Enum.map(children, &Supervisor.child_spec(&1, []).id)

  # Every TCP port this Erlang system listens on.
  defp listening do
    for port <- Port.list(),
        Port.info(port, :name) == {:name, ~c"tcp_inet"},
        {:ok, status} <- [:prim_inet.getstatus(port)],
        :listen in status,
        {:ok, number} <- [:inet.port(port)],
        do: number
  end

  @hub_only [
    WallboardWeb.Endpoint,
    Wallboard.Pollers,
    Wallboard.Store,
    Wallboard.Remote,
    Wallboard.Archive.StatusRecorder,
    Wallboard.Archive.Collector,
    Wallboard.Archive.GitHubCollector,
    Wallboard.Advertise,
    Phoenix.PubSub.Supervisor
  ]

  test "the collector role starts the watcher, its outbox and the sender, and nothing of the hub's",
       c do
    children = Wallboard.Application.children(settings("collector", c.dir))

    assert ids(children) == [
             Wallboard.TaskSupervisor,
             Outbox,
             Watcher,
             Wallboard.Collector.Sender
           ]

    assert ids(children) -- @hub_only == ids(children)
  end

  test "a collector listens on no port", c do
    settings = settings("collector", c.dir)
    Settings.put(settings)
    before = listening()

    # The task supervisor is already up in a test run; the rest start as
    # the release starts them.
    [_tasks | rest] = Wallboard.Application.children(settings)
    for child <- rest, do: start_supervised!(child)
    assert Watcher.tick() == :ok

    assert listening() == before
    # The check does see a port when there is one.
    {:ok, socket} = :gen_tcp.listen(0, [])
    assert listening() -- before == [elem(:inet.port(socket), 1)]
    :gen_tcp.close(socket)
    assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", settings.port, [], 1_000)
    for name <- @hub_only, do: assert(Process.whereis(name) == nil)

    # It keeps its place in its own folder, and makes no database.
    assert File.dir?(Path.join(settings.collector.dir, "outbox"))
    refute File.exists?(settings.archive.path)
  end

  test "hub and collector together runs the board as before", c do
    both = ids(Wallboard.Application.children(settings("both", c.dir)))

    for id <- [
          WallboardWeb.Endpoint,
          Wallboard.Pollers,
          Wallboard.Store,
          Wallboard.Remote,
          Wallboard.Archive.StatusRecorder,
          Wallboard.Archive.Collector,
          Wallboard.Archive.GitHubCollector
        ] do
      assert id in both
    end

    refute Outbox in both
    refute Watcher in both

    # A hub keeps only what other machines send.
    hub = ids(Wallboard.Application.children(settings("hub", c.dir)))
    assert both -- hub == [Wallboard.Archive.Collector]
  end

  describe "the role setting" do
    test "is hub, collector or both, and both when the file leaves it out" do
      assert Settings.role(Settings.defaults()) == :both

      for role <- ["hub", "collector", "both"],
          do: assert(Settings.role(%{role: role}) in [:hub, :collector, :both])

      assert Settings.role(%{role: " collector "}) == :collector
      assert Settings.normalize(Settings.defaults()).role == :both
    end

    test "anything else stops the start with a plain message" do
      assert_raise ArgumentError, ~r/role must be "hub", "collector" or "both"/, fn ->
        Settings.normalize(Settings.merge(Settings.defaults(), %{role: "colector"}))
      end
    end

    test "the WALLBOARD_ROLE environment variable wins over the file" do
      System.put_env("WALLBOARD_ROLE", "collector")
      on_exit(fn -> System.delete_env("WALLBOARD_ROLE") end)
      assert Settings.base().role == :collector
    end

    test "a setting of the wrong kind falls back instead of stopping the start" do
      settings =
        Settings.defaults()
        |> Settings.merge(%{
          archive: %{collect_local: nil},
          claude: %{poll_seconds: nil},
          codex: %{idle_minutes: 7.5},
          collector: %{poll_seconds: 2.5, backfill_days: nil, outbox_mb: 0}
        })
        |> Settings.normalize()

      refute settings.archive.collect_local
      assert settings.claude.poll_seconds == Settings.defaults().claude.poll_seconds
      assert settings.codex.idle_minutes == Settings.defaults().codex.idle_minutes
      keys = [:poll_seconds, :backfill_days, :outbox_mb]
      assert Map.take(settings.collector, keys) == Map.take(Settings.defaults().collector, keys)
    end

    test "the collector's folder sits beside the database's usual place" do
      settings = Settings.normalize(Settings.defaults())
      assert Path.basename(settings.collector.dir) == "collector"
      assert Path.dirname(settings.collector.dir) == Path.dirname(Settings.db_path(nil))
    end
  end
end
