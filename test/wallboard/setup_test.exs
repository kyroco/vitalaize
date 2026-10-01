defmodule Wallboard.SetupTest do
  # One machine's settings at a time: they are read through the environment.
  use ExUnit.Case, async: false

  alias Wallboard.{Pairing, Settings, Setup, Store}
  alias Wallboard.Link.Hub
  alias Wallboard.Pairing.Door
  alias Wallboard.Settings.Watch
  alias WallboardWeb.SettingsLive

  @moduletag :capture_log

  @env ["WALLBOARD_SETTINGS", "WALLBOARD_SAVED_SETTINGS", "WALLBOARD_ROLE", "RELEASE_ROOT"]

  setup do
    dir = Wallboard.Fixtures.tmp_path("wallboard-setup")
    File.mkdir_p!(dir)

    old_env = for name <- @env, do: {name, System.get_env(name)}
    old = :persistent_term.get({Settings, :settings}, nil)
    for name <- @env, do: System.delete_env(name)
    System.put_env("WALLBOARD_SETTINGS", Path.join(dir, "settings.exs"))

    on_exit(fn ->
      for {name, value} <- old_env do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      File.rm_rf!(dir)

      if old,
        do: :persistent_term.put({Settings, :settings}, old),
        else: :persistent_term.erase({Settings, :settings})
    end)

    %{dir: dir, saved: Path.join(dir, "settings.json")}
  end

  # A throwaway settings.exs: its database, its collector folder and its
  # Claude folder are all inside the test's own folder.
  defp settings_file(dir, more \\ "") do
    File.write!(Path.join(dir, "settings.exs"), """
    %{
      archive: %{path: #{inspect(Path.join(dir, "wallboard.db"))}, advertise: false},
      collector: %{dir: #{inspect(Path.join(dir, "collector"))}},
      claude: %{config_dirs: [#{inspect(Path.join(dir, "claude"))}]},
      github: %{repo: "acme/api"},
      #{more}
    }
    """)
  end

  # Stands in for launchctl, systemctl and systemd.sh, and keeps what was
  # run. `settings` is the file the service it plays was started with.
  defp service(state, settings \\ System.get_env("WALLBOARD_SETTINGS")) do
    me = self()

    fn program, args ->
      send(me, {:ran, Path.basename(program), args})

      case {Path.basename(program), args} do
        {"id", ["-u"]} ->
          {"501\n", 0}

        {"launchctl", ["print", "gui/501/ai.kyroco.wallboard"]} when state == :running ->
          {"""
           gui/501/ai.kyroco.wallboard = {
           \tstate = running
           \tenvironment = {
           \t\tWALLBOARD_SETTINGS => #{settings}
           \t\tRELEASE_DISTRIBUTION => none
           \t}
           }
           """, 0}

        {"launchctl", ["print", _]} ->
          {"Could not find service", 113}

        {"systemctl", ["--user", "show", _, "-p", "Environment"]} when state == :running ->
          {"Environment=WALLBOARD_SETTINGS=#{settings} RELEASE_DISTRIBUTION=none\n", 0}

        {"systemctl", ["--user", "show", _, "-p", "Environment"]} ->
          {"Environment=\n", 0}

        {"systemctl", ["--user", "is-active", _]} when state == :running ->
          {"active\n", 0}

        {"systemctl", ["--user", "is-active", _]} ->
          {"inactive\n", 3}

        {"systemctl", ["--user", "is-enabled", _]} ->
          {"", 1}

        _ ->
          {"", 0}
      end
    end
  end

  defp mac(state \\ :running), do: [os: {:unix, :darwin}, run: service(state)]
  defp linux(state), do: [os: {:unix, :linux}, run: service(state)]

  # What was asked of the service, without the questions about its state.
  defp restarts do
    for {:ran, program, args} <- flush(),
        not match?({"id", _}, {program, args}),
        not match?({"launchctl", ["print" | _]}, {program, args}),
        not match?({"systemctl", ["--user", "is-" <> _ | _]}, {program, args}),
        not match?({"systemctl", ["--user", "show" | _]}, {program, args}),
        do: {program, args}
  end

  defp flush(acc \\ []) do
    receive do
      message -> flush([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp io(lines) do
    {:ok, io} = StringIO.open(Enum.join(lines, "\n") <> "\n", capture_prompt: true)
    io
  end

  defp output(io), do: io |> StringIO.contents() |> elem(1)

  defp saved_json(path), do: path |> File.read!() |> Jason.decode!()

  describe "an existing settings.exs" do
    test "loads as it did before, with no settings.json", %{dir: dir} do
      for name <- ["one_repo.exs", "several_repos.exs", "../../../settings.example.exs"] do
        file = Path.expand(name, Path.expand("../fixtures/settings", __DIR__))

        # Only the database moves, into this test's folder: the board looks
        # there for values an older settings page saved.
        File.write!(Path.join(dir, "settings.exs"), """
        {settings, _} = Code.eval_file(#{inspect(file)})
        Wallboard.Settings.merge(settings, %{archive: %{path: #{inspect(Path.join(dir, "wallboard.db"))}}})
        """)

        {written, _} = Code.eval_file(Path.join(dir, "settings.exs"))
        expected = Settings.defaults() |> Settings.merge(written) |> Settings.normalize()

        assert Settings.load!() == expected
        assert Settings.under_saved() == expected
        refute File.exists?(Path.join(dir, "settings.json"))
      end
    end

    test "stays the base: saved values go on top, and the file is not rewritten", %{
      dir: dir,
      saved: saved
    } do
      settings_file(dir)
      before = File.read!(Path.join(dir, "settings.exs"))

      assert {:ok, _} = Setup.save(%{"brand.name" => "Studio"}, mac())
      assert File.read!(Path.join(dir, "settings.exs")) == before
      assert saved_json(saved) == %{"brand" => %{"name" => "Studio"}}
      assert Settings.load!().brand.name == "Studio"
      assert Settings.load!().github.repo == "acme/api"
    end

    test "values an older settings page saved in the database still load", %{dir: dir} do
      settings_file(dir)
      start_supervised!({Store, path: Path.join(dir, "wallboard.db")})
      Store.put_meta("settings_overrides", Jason.encode!(%{rotate_seconds: 12, token: "old"}))

      assert %{rotate_seconds: 12, token: "old"} = Settings.load!()

      # A value saved now wins over it, and the rest of it stays.
      assert {:ok, _} = Setup.save(%{"rotate_seconds" => "45"}, mac())
      assert %{rotate_seconds: 45, token: "old"} = Settings.load!()
    end

    test "a save that changes the role is held against the older page's values that role reads",
         %{dir: dir, saved: saved} do
      settings_file(dir)
      start_supervised!({Store, path: Path.join(dir, "wallboard.db")})
      Store.put_meta("settings_overrides", Jason.encode!(%{rotate_seconds: 12}))

      # A collector has no database, so the older page's 12 is out of sight.
      assert {:ok, _} = Setup.save(%{"role" => "collector"}, mac())
      assert Settings.get().rotate_seconds == 30

      # Back to a board in one save, with a value the same as the file's.
      # The board reads the database again, so the value is kept as saved:
      # dropped as "same as the file", it would lose to the older 12.
      assert {:ok, _} = Setup.save(%{"role" => "both", "rotate_seconds" => "30"}, mac())
      assert Settings.get().rotate_seconds == 30
      assert saved_json(saved) == %{"rotate_seconds" => 30}
      assert Settings.load!().rotate_seconds == 30
    end
  end

  describe "saving on a Mac that runs the board" do
    test "a hub setting and a collector setting both take effect, and only the board restarts",
         %{dir: dir, saved: saved} do
      settings_file(dir)
      folder = Path.join(dir, "claude-work")

      assert {:ok, result} =
               Setup.save(%{"link.port" => "4999", "claude.config_dirs" => folder}, mac())

      # Both are in the one saved file, and in the settings as loaded.
      assert saved_json(saved) == %{
               "link" => %{"port" => 4999},
               "claude" => %{"config_dirs" => [folder]}
             }

      assert Settings.get().link.port == 4999
      assert Settings.get().claude.config_dirs == [folder]

      # The port is the hub's and is only read at the start: the board
      # restarts for it. The folder is this Mac's collector part and is
      # read as it goes: nothing restarts for it.
      assert [%{path: [:link, :port], part: :hub}] = result.restart
      assert [%{path: [:claude, :config_dirs], part: :collector}] = result.live
      assert result.parts == [:hub]
      assert result.service == :restarted

      # One stop request to the board's login item, and nothing else.
      assert restarts() == [{"launchctl", ["kill", "SIGTERM", "gui/501/ai.kyroco.wallboard"]}]

      assert Enum.join(Setup.report(result), "\n") =~
               "Restarted the board to take up: Port they stream to"

      assert Enum.join(Setup.report(result), "\n") =~ "with no restart: Claude folders"
    end

    test "a setting that applies live restarts nothing", %{dir: dir} do
      settings_file(dir)
      folder = Path.join(dir, "claude-work")

      assert {:ok, result} =
               Setup.save(%{"claude.config_dirs" => folder, "rotate_seconds" => "10"}, mac())

      assert result.restart == [] and result.service == :untouched
      assert length(result.live) == 2
      # Not even a question to launchd.
      assert flush() == []
    end

    test "a board that is not a service is not restarted, and the person is told", %{dir: dir} do
      settings_file(dir)
      assert {:ok, result} = Setup.save(%{"port" => "4999"}, mac(:none))
      assert result.service == :by_hand
      assert restarts() == []
      assert Enum.join(Setup.report(result)) =~ "does not run as a service here"
    end

    test "a board on this machine that runs from other settings is left alone", %{dir: dir} do
      settings_file(dir)
      other = [os: {:unix, :darwin}, run: service(:running, "/Users/someone/real/settings.exs")]
      assert {:ok, result} = Setup.save(%{"port" => "4999"}, other)
      assert result.service == :by_hand
      assert restarts() == []

      other = [os: {:unix, :linux}, run: service(:running, "/home/someone/real/settings.exs")]
      assert {:ok, result} = Setup.save(%{"port" => "4998"}, other)
      assert result.service == :by_hand
      assert restarts() == []
    end

    test "a wrong value saves nothing and says which field", %{dir: dir, saved: saved} do
      settings_file(dir)

      assert {:error, %{"link.port" => message}} =
               Setup.save(%{"link.port" => "70000", "brand.name" => "Studio"}, mac())

      assert message =~ "Port they stream to: must be a port number"
      refute File.exists?(saved)
      assert flush() == []
    end

    test "a secret comes back as dots and is kept when the dots are saved", %{dir: dir} do
      settings_file(dir)
      assert {:ok, _} = Setup.save(%{"token" => "hunter2"}, mac())

      out = io([])
      assert :ok = Setup.json(["show"], mac() ++ [out: out])
      refute output(out) =~ "hunter2"

      assert {:ok, result} =
               Setup.save(%{"token" => Settings.kept(), "brand.name" => "Studio"}, mac())

      assert Settings.get().token == "hunter2"
      assert [%{path: [:brand, :name]}] = result.changed
    end

    test "the saved file can only be read by its owner", %{dir: dir, saved: saved} do
      settings_file(dir)
      assert {:ok, _} = Setup.save(%{"token" => "hunter2"}, mac())
      assert Bitwise.band(File.stat!(saved).mode, 0o777) == 0o600
    end
  end

  describe "saving on a collector" do
    test "its folders take effect with no restart; a change of role restarts it", %{dir: dir} do
      settings_file(dir, ~s(role: "collector"))
      folder = Path.join(dir, "claude-work")

      assert {:ok, result} = Setup.save(%{"collector.claude_dirs" => folder}, mac())
      assert Settings.get().collector.claude_dirs == [folder]
      assert result.restart == [] and result.service == :untouched
      assert flush() == []

      # The board's settings mean nothing here: no board runs.
      assert {:ok, result} = Setup.save(%{"port" => "4999"}, mac())
      assert result.restart == []

      assert {:ok, result} = Setup.save(%{"role" => "both"}, mac())
      assert result.parts == [:machine] and result.service == :restarted
      assert Settings.get().role == :both
    end

    test "emptying the folders goes back to finding them", %{dir: dir} do
      settings_file(dir, ~s(role: "collector"))
      assert {:ok, _} = Setup.save(%{"collector.claude_dirs" => "/tmp/a\n/tmp/b"}, mac())
      assert Settings.get().collector.claude_dirs == ["/tmp/a", "/tmp/b"]
      assert {:ok, _} = Setup.save(%{"collector.claude_dirs" => ""}, mac())
      assert Settings.get().collector.claude_dirs == nil
    end
  end

  describe "a save touches only what it was given" do
    test "a role changed to hub and back leaves this machine saving its own sessions", %{
      dir: dir,
      saved: saved
    } do
      settings_file(dir)
      assert Settings.load!().archive.collect_local

      assert {:ok, _} = Setup.save(%{"role" => "hub"}, mac())
      assert saved_json(saved) == %{"role" => "hub"}

      # Anything saved while it is a hub does not write the hub's forced
      # "off" down as the person's choice either.
      assert {:ok, _} = Setup.save(%{"brand.name" => "Hall"}, mac())
      assert saved_json(saved) == %{"role" => "hub", "brand" => %{"name" => "Hall"}}

      assert {:ok, result} = Setup.save(%{"role" => "both"}, mac())
      assert saved_json(saved) == %{"brand" => %{"name" => "Hall"}}
      assert Settings.get().role == :both
      assert Settings.get().archive.collect_local
      assert [:role] in Enum.map(result.changed, & &1.path)
    end

    test "a value in settings.exs the form would not take does not block a save", %{dir: dir} do
      settings_file(dir, """
      alerts: %{via: "sms"},
      new_relic: %{region: "US", account_id: 1_234_567},
      brand: %{name: " Acme "},
      """)

      assert {:ok, result} = Setup.save(%{"rotate_seconds" => "9"}, mac())
      assert [%{path: [:rotate_seconds]}] = result.changed
      # And none of them was rewritten.
      assert %{alerts: %{via: "sms"}, new_relic: %{region: "US", account_id: 1_234_567}} =
               Settings.get()

      assert Settings.get().brand.name == " Acme "
    end

    test "a collector told to watch no Claude folder still watches none after another save", %{
      dir: dir,
      saved: saved
    } do
      File.write!(Path.join(dir, "settings.exs"), """
      %{role: "collector", collector: %{dir: #{inspect(Path.join(dir, "collector"))}, claude_dirs: []}}
      """)

      assert {:ok, result} = Setup.save(%{"collector.codex_dirs" => "/tmp/codex"}, mac())
      assert Settings.get().collector.claude_dirs == []
      assert saved_json(saved) == %{"collector" => %{"codex_dirs" => ["/tmp/codex"]}}
      assert [%{path: [:collector, :codex_dirs]}] = result.changed
    end

    test "saving nothing changes nothing", %{dir: dir, saved: saved} do
      settings_file(dir, "new_relic: %{account_id: 1_234_567},")
      assert {:ok, result} = Setup.save(%{}, mac())
      assert result.changed == []
      assert Setup.report(result) == ["Nothing changed."]
      assert saved_json(saved) == %{}
    end

    test "a value set back to what the file says leaves the saved file", %{dir: dir, saved: saved} do
      settings_file(dir)
      assert {:ok, _} = Setup.save(%{"rotate_seconds" => "9", "brand.name" => "Hall"}, mac())
      assert {:ok, _} = Setup.save(%{"rotate_seconds" => "30"}, mac())
      assert saved_json(saved) == %{"brand" => %{"name" => "Hall"}}
    end

    test "a role that WALLBOARD_ROLE overrules is refused, not saved for later", %{
      dir: dir,
      saved: saved
    } do
      settings_file(dir)
      System.put_env("WALLBOARD_ROLE", "both")
      assert {:error, %{"role" => message}} = Setup.save(%{"role" => "collector"}, mac())
      assert message =~ "WALLBOARD_ROLE is set to both"
      refute File.exists?(saved)
      assert {:ok, _} = Setup.save(%{"role" => "both", "rotate_seconds" => "9"}, mac())
    end

    test "the app's wizard run again wins over what was saved before", %{dir: dir, saved: saved} do
      settings_file(dir)

      assert {:ok, _} =
               Setup.save(%{"role" => "hub", "port" => "5000", "alerts.via" => "SMS"}, mac())

      # Reconfigure, as macos/Wallboard/Setup.swift does it: the settings the
      # wizard asks about are forgotten, then settings.exs is written anew.
      out = io([])
      keys = Jason.encode!(%{keys: ["role", "port", "not.a.setting"]})
      assert :ok = Setup.json(["forget"], mac() ++ [io: io([keys]), out: out])
      assert "VITALAIZE_JSON" <> json = String.trim(output(out))
      assert %{"ok" => true, "path" => ^saved} = Jason.decode!(json)

      # A value the form would refuse is no obstacle: nothing is checked.
      File.write!(Path.join(dir, "settings.exs"), """
      %{
        role: "both",
        port: 4801,
        alerts: %{via: "sms"},
        archive: %{path: #{inspect(Path.join(dir, "wallboard.db"))}, advertise: false}
      }
      """)

      assert %{role: :both, port: 4801} = Settings.load!()
      # What the wizard did not name stays saved.
      assert saved_json(saved) == %{"alerts" => %{"via" => "SMS"}}
    end

    test "the wizard can replace a settings.exs that does not load, and stops no service", %{
      dir: dir,
      saved: saved
    } do
      settings_file(dir)

      assert {:ok, _} =
               Setup.save(%{"role" => "hub", "port" => "5000", "brand.name" => "Hall"}, mac())

      in_use = Settings.get()
      flush()

      # The settings file is broken now, and the wizard is run to write it anew.
      File.write!(Path.join(dir, "settings.exs"), "%{port: ")
      assert_raise TokenMissingError, fn -> Settings.load!() end

      out = io([])
      keys = Jason.encode!(%{keys: ["role", "port"]})
      assert :ok = Setup.json(["forget"], mac() ++ [io: io([keys]), out: out])
      assert "VITALAIZE_JSON" <> json = String.trim(output(out))
      assert %{"ok" => true} = Jason.decode!(json)
      assert saved_json(saved) == %{"brand" => %{"name" => "Hall"}}

      # A saved role and port were taken out, and the running service was
      # not asked to stop, nor even looked for: stopped now, it would come
      # back on the old settings file. The app starts it again itself once
      # the new file is written.
      assert flush() == []
      # Nothing was loaded again either.
      assert Settings.get() == in_use
    end

    test "taking out what was never saved writes no file", %{dir: dir, saved: saved} do
      settings_file(dir)
      assert {:ok, %{path: ^saved}} = Setup.forget(["role", "port", "not.a.setting"])
      refute File.exists?(saved)
    end

    test "turning this machine's own sessions off is kept when the saved role differs from the file's",
         %{dir: dir, saved: saved} do
      settings_file(dir, ~s(role: "hub",))
      assert {:ok, _} = Setup.save(%{"role" => "both"}, mac())
      assert Settings.get().archive.collect_local

      assert {:ok, result} = Setup.save(%{"archive.collect_local" => "false"}, mac())
      assert [%{path: [:archive, :collect_local]}] = result.changed
      refute Settings.get().archive.collect_local
      assert saved_json(saved) == %{"role" => "both", "archive" => %{"collect_local" => false}}

      # And on again leaves the saved file.
      assert {:ok, _} = Setup.save(%{"archive.collect_local" => "true"}, mac())
      assert saved_json(saved) == %{"role" => "both"}
    end

    test "something that is not a setting is refused", %{dir: dir, saved: saved} do
      settings_file(dir)

      assert {:error, %{"archive.path" => _}} =
               Setup.save(%{"archive.path" => "/tmp/x.db"}, mac())

      refute File.exists?(saved)
    end

    test "the New Relic key itself is not taken where its 1Password address goes", %{dir: dir} do
      settings_file(dir)

      assert {:error, %{"new_relic.api_key_ref" => message}} =
               Setup.save(%{"new_relic.api_key_ref" => "NRAK-ABC123"}, mac())

      assert message =~ "op://"
      assert {:ok, _} = Setup.save(%{"new_relic.api_key_ref" => "op://Private/NR/key"}, mac())
    end
  end

  describe "which service is this machine's" do
    test "a service started through a linked folder is still found and restarted", %{dir: dir} do
      settings_file(dir)
      link = dir <> "-link"
      File.ln_s!(dir, link)
      on_exit(fn -> File.rm(link) end)

      # The service was set up with the linked name; setup runs with the real one.
      linked = [os: {:unix, :linux}, run: service(:running, Path.join(link, "settings.exs"))]
      assert {:ok, result} = Setup.save(%{"port" => "4999"}, linked)
      assert result.service == :restarted
      assert restarts() == [{"systemctl", ["--user", "restart", "vitalaize.service"]}]
    end

    test "run from a release inside a checkout, it saves beside the settings.exs in use", %{
      dir: dir,
      saved: saved
    } do
      # scripts/systemd.sh in a checkout: the service names the checkout's
      # settings.exs, and the release's own folder is somewhere under it.
      settings_file(dir)
      release = Path.join(dir, "_build/prod/rel/wallboard")
      File.mkdir_p!(release)
      System.delete_env("WALLBOARD_SETTINGS")
      System.put_env("RELEASE_ROOT", release)

      File.cd!(dir, fn ->
        running = [os: {:unix, :linux}, run: service(:running, Path.join(dir, "settings.exs"))]
        assert {:ok, result} = Setup.save(%{"port" => "4999"}, running)
        assert Path.expand(result.path) |> Path.basename() == "settings.json"
        assert File.exists?(saved)
        refute File.exists?(Path.join(release, "settings.json"))
        assert result.service == :restarted
      end)
    end
  end

  describe "the app and the terminal command share one format" do
    test "each can change what the other saved", %{dir: dir, saved: saved} do
      settings_file(dir)

      # The app saves two values.
      values = %{"brand.name" => "Studio", "alerts.phone" => "+15550100"}
      out = io([])

      assert :ok =
               Setup.json(
                 ["save"],
                 mac() ++ [io: io([Jason.encode!(%{values: values})]), out: out]
               )

      assert "VITALAIZE_JSON" <> json = String.trim(output(out))
      assert %{"ok" => true, "service" => "untouched"} = Jason.decode!(json)

      # The terminal shows them and changes one: role kept, section 1
      # (Board), a new name, the rest kept, then save.
      term = io(["", "1", "Hall", "", "", "", "", "", ""])
      assert :ok = Setup.run(mac() ++ [io: term])
      assert output(term) =~ "Board name [Studio]"

      assert saved_json(saved) == %{
               "brand" => %{"name" => "Hall"},
               "alerts" => %{"phone" => "+15550100"}
             }

      # And the app sees what the terminal saved.
      out = io([])
      assert :ok = Setup.json(["show"], mac() ++ [out: out])
      "VITALAIZE_JSON" <> json = String.trim(output(out))
      shown = Jason.decode!(json)
      fields = for s <- shown["sections"], f <- s["fields"], into: %{}, do: {f["key"], f["value"]}
      assert fields["brand.name"] == "Hall"
      assert fields["alerts.phone"] == "+15550100"
      assert shown["path"] == saved
    end

    test "q leaves without saving", %{dir: dir, saved: saved} do
      settings_file(dir)
      term = io(["", "1", "Hall", "", "", "", "", "", "q"])
      assert :ok = Setup.run(mac() ++ [io: term])
      assert output(term) =~ "Nothing saved."
      refute File.exists?(saved)
    end

    test "a wrong answer is asked again", %{dir: dir} do
      settings_file(dir)
      term = io(["hubb", "hub", ""])
      assert :ok = Setup.run(mac() ++ [io: term])
      assert output(term) =~ "pick one of both, hub, collector"
      assert Settings.get().role == :hub
    end
  end

  describe "vitalaize setup on Linux, from scripted input" do
    # A throwaway hub in this test: its database, its link port, its
    # pairing door and the board's own router.
    defp start_hub(dir) do
      hub = Path.join(dir, "hub")
      start_supervised!({Store, path: Path.join(hub, "wallboard.db")})
      start_supervised!({Hub, dir: Path.join(hub, "link"), port: 0})
      start_supervised!({Door, dir: Path.join(hub, "link"), link_port: Hub.port()})

      pid =
        start_supervised!(
          {Bandit, plug: WallboardWeb.Router, ip: :loopback, port: 0, startup_log: false}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(pid)
      port
    end

    # The owner at the hub: taps Approve on the first request that shows up.
    defp approve_when_asked do
      Task.async(fn ->
        Stream.repeatedly(fn ->
          Process.sleep(20)
          Door.pending()
        end)
        |> Enum.find_value(fn
          [%{id: id, code: code}] -> Door.approve(id) && code
          _ -> nil
        end)
      end)
    end

    test "it saves a collector's settings, pairs with a throwaway hub and sets up the service",
         %{dir: dir, saved: saved} do
      port = start_hub(dir)
      folder = Path.join(dir, "claude")
      collector = Path.join(dir, "collector")
      File.mkdir_p!(collector)
      # A fresh machine, but for where it keeps its own files: the
      # collector's, and the database a board would read, go in this test's
      # folder, never the real ones under the home folder.
      File.write!(Path.join(dir, "settings.exs"), """
      %{
        archive: %{path: #{inspect(Path.join(dir, "wallboard.db"))}},
        collector: %{dir: #{inspect(collector)}}
      }
      """)

      owner = approve_when_asked()

      term =
        io([
          # What this machine does
          "collector",
          # Claude folders, Codex folders (found by itself)
          folder,
          "",
          # The hub's address
          "127.0.0.1:#{port}",
          # Set it up as a systemd user service
          "yes"
        ])

      assert :ok = Setup.run(linux(:none) ++ [io: term, poll_ms: 30, root: dir])
      text = output(term)

      # Saved, in the shared format.
      assert saved_json(saved) == %{
               "role" => "collector",
               "collector" => %{"claude_dirs" => [folder]}
             }

      assert Settings.load!().role == :collector

      # Paired: the code on the terminal is the one the owner approved.
      code = Task.await(owner, 10_000)
      assert text =~ code
      assert text =~ "Approved. This machine is connected as"

      assert {:ok, %{host: "127.0.0.1", tls: %{cert_pem: _}}} =
               Pairing.load(Path.join(collector, "link"))

      # The role changed and nothing ran as a service yet, so nothing was
      # restarted; the service was then set up with the release's own script.
      assert text =~ "does not run as a service here"
      assert [{"systemd.sh", ["on"]}] = restarts()
      assert text =~ "The collector is on, and starts whenever you log in."
    end

    test "a running collector service is the one restarted, with systemctl", %{dir: dir} do
      settings_file(dir, ~s(role: "collector"))
      term = io(["both", ""])
      assert :ok = Setup.run(linux(:running) ++ [io: term])
      assert restarts() == [{"systemctl", ["--user", "restart", "vitalaize.service"]}]
      assert output(term) =~ "Restarted the board to take up: What this machine does"
    end

    test "what pairing answers is shown as it is", %{dir: dir} do
      settings_file(dir, ~s(role: "collector"))
      pair = fn _ -> {:error, :expired} end
      term = io(["", "", "", "10.0.0.9"])
      assert :ok = Setup.run(linux(:running) ++ [io: term, pair: pair])
      assert output(term) =~ Pairing.why(:expired)
    end
  end

  describe "a running board or collector" do
    test "keeps looking when its working folder is removed under it", %{dir: dir, saved: saved} do
      settings_file(dir)
      Settings.load!()
      gone = Path.join(dir, "gone")
      File.mkdir_p!(gone)

      File.cd!(gone, fn ->
        File.rm_rf!(gone)
        assert Settings.saved_path() == saved
        watch = start_supervised!({Watch, name: :watch_gone, every_ms: 20, listener: self()})
        File.write!(saved, Jason.encode!(%{rotate_seconds: 8}))
        assert_receive {:settings, :reloaded}, 2_000
        assert Process.alive?(watch)
      end)
    end

    test "takes up a saved setting within its next look, and keeps the old on a broken file",
         %{dir: dir, saved: saved} do
      settings_file(dir)
      Settings.load!()
      start_supervised!({Watch, name: :watch_test, every_ms: 20, listener: self()})

      # Another program saves: the app, or vitalaize setup.
      File.write!(saved, Jason.encode!(%{rotate_seconds: 7}))
      assert_receive {:settings, :reloaded}, 2_000
      assert Settings.get().rotate_seconds == 7

      File.write!(saved, "{ not json")
      assert_receive {:settings, :unreadable}, 2_000
      assert Settings.get().rotate_seconds == 7
    end

    test "keeps its settings, the board password too, when the folder it was started in is removed",
         %{dir: dir} do
      # A release run by hand: nothing names the settings file and the
      # release's own folder has none, so it is the one in the folder the
      # board was started in.
      System.delete_env("WALLBOARD_SETTINGS")
      release = Path.join(dir, "release")
      started_in = Path.join(dir, "started-in")
      File.mkdir_p!(release)
      File.mkdir_p!(started_in)
      System.put_env("RELEASE_ROOT", release)

      File.write!(Path.join(started_in, "settings.exs"), """
      %{
        token: "hunter2",
        rotate_seconds: 11,
        archive: %{path: #{inspect(Path.join(dir, "wallboard.db"))}, advertise: false}
      }
      """)

      File.cd!(started_in, fn ->
        assert %{token: "hunter2", rotate_seconds: 11} = Settings.load!()
        watch = start_supervised!({Watch, name: :watch_moved, every_ms: 20, listener: self()})

        # With the folder gone there is no settings file to find, and the
        # saved settings are looked for in the release's folder. Something
        # saved there must not be loaded over nothing but the defaults.
        File.rm_rf!(started_in)
        assert Settings.saved_path() == Path.join(release, "settings.json")
        File.write!(Path.join(release, "settings.json"), Jason.encode!(%{brand: %{name: "X"}}))

        refute_receive {:settings, :reloaded}, 300
        assert_received {:settings, :moved}
        assert %{token: "hunter2", rotate_seconds: 11} = Settings.get()
        assert Process.alive?(watch)
      end)
    end

    test "keeps its password when the saved settings that hold it are removed", %{
      dir: dir,
      saved: saved
    } do
      # A password set in the app or with `vitalaize setup` is in
      # settings.json, not in the settings file.
      settings_file(dir)
      File.write!(saved, Jason.encode!(%{token: "hunter2", rotate_seconds: 9}))
      assert %{token: "hunter2", rotate_seconds: 9} = Settings.load!()
      start_supervised!({Watch, name: :watch_removed, every_ms: 20, listener: self()})

      # The saved settings go away under the running board.
      File.rm!(saved)
      assert_receive {:settings, :reloaded}, 2_000

      # What is read as it goes follows the files. The password is only
      # read at the start, so the running board keeps the one it has.
      assert %{token: "hunter2", rotate_seconds: 30} = Settings.get()
    end

    test "a setting that is only read at the start waits for the next start", %{
      dir: dir,
      saved: saved
    } do
      settings_file(dir)
      assert %{token: nil, port: 4747, role: :both} = Settings.load!()
      start_supervised!({Watch, name: :watch_start_only, every_ms: 20, listener: self()})

      # Saved from another program, on a machine with no service to restart.
      values = %{token: "hunter2", port: 4999, role: "hub", rotate_seconds: 7}
      File.write!(saved, Jason.encode!(values))
      assert_receive {:settings, :reloaded}, 2_000
      assert %{token: nil, port: 4747, role: :both, rotate_seconds: 7} = Settings.get()

      # The next start takes them up.
      assert %{token: "hunter2", port: 4999, role: :hub, rotate_seconds: 7} = Settings.load!()
    end

    test "keeps its settings while the settings file is gone, and takes up a save once it is back",
         %{dir: dir, saved: saved} do
      settings_file(dir, ~s(token: "hunter2"))
      Settings.load!()
      start_supervised!({Watch, name: :watch_gone_file, every_ms: 20, listener: self()})

      file = Path.join(dir, "settings.exs")
      File.rename!(file, file <> ".away")
      File.write!(saved, Jason.encode!(%{rotate_seconds: 8}))
      assert_receive {:settings, :moved}, 2_000
      refute_received {:settings, :reloaded}
      assert %{token: "hunter2", rotate_seconds: 30} = Settings.get()

      File.rename!(file <> ".away", file)
      assert_receive {:settings, :reloaded}, 2_000
      assert %{token: "hunter2", rotate_seconds: 8} = Settings.get()
    end
  end

  describe "the board's Settings page" do
    defp page(settings) do
      assigns = %{
        __changed__: nil,
        connected?: true,
        allowed?: true,
        notice: nil,
        linked: nil,
        linked_readable?: true,
        confirm_disconnect: nil,
        settings: settings,
        values: Settings.shown(settings),
        machines: [],
        ignored_repos: []
      }

      assigns |> SettingsLive.render() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    end

    test "shows the settings, has nothing to change them with, and says where to", %{dir: dir} do
      settings_file(dir, ~s(token: "hunter2"))
      html = page(Settings.load!())

      assert html =~ "acme/api"
      assert html =~ "Board name"
      refute html =~ "hunter2"

      for part <- [
            "<form",
            "<input",
            "<textarea",
            "<select",
            "phx-submit",
            ~s(phx-click="restart")
          ],
          do: refute(html =~ part)

      assert html =~ "open the VitalAIze app"
      assert html =~ "vitalaize setup"

      # No Connect command, key or upload address is offered any more.
      for part <- ["Connect another Mac", "/ingest", "Bearer", "Make a new key"],
          do: refute(html =~ part)

      assert html =~ "Saved sessions by Mac"
    end

    test "a save sent to it by hand changes nothing", %{dir: dir, saved: saved} do
      settings_file(dir)
      settings = Settings.load!()

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, allowed?: true, who: %{local?: true}, settings: settings}
      }

      for event <- ["save", "restart", "validate"] do
        assert {:noreply, _} =
                 SettingsLive.handle_event(event, %{"s" => %{"brand.name" => "Hacked"}}, socket)
      end

      assert Settings.load!() == settings
      refute File.exists?(saved)
    end
  end
end
