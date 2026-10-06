defmodule Wallboard.NewRelicKeyTest do
  # One machine's settings at a time: they are read through the environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wallboard.{Cmd, KeyStore, Secrets, Settings, Setup}
  alias Wallboard.KeyStore.Memory
  alias Wallboard.Settings.Watch
  alias WallboardWeb.SettingsLive

  @moduletag :capture_log

  # A made-up key. Every test that saves it looks for it everywhere it
  # must not be.
  @key "NRAK-FAKE0TEST0KEY0NOT0REAL0XYZ"
  @other "NRAK-FAKE0SECOND0KEY0NOT0REAL"

  @env [
    "WALLBOARD_SETTINGS",
    "WALLBOARD_SAVED_SETTINGS",
    "WALLBOARD_ROLE",
    "RELEASE_ROOT",
    "PATH"
  ]

  setup do
    dir = Wallboard.Fixtures.tmp_path("wallboard-nr-key")
    File.mkdir_p!(dir)

    old_env = for name <- @env, do: {name, System.get_env(name)}
    old = :persistent_term.get({Settings, :settings}, nil)
    old_status = Secrets.new_relic()
    old_level = Logger.level()
    for name <- @env -- ["PATH"], do: System.delete_env(name)
    System.put_env("WALLBOARD_SETTINGS", Path.join(dir, "settings.exs"))
    Memory.clear()
    # Every line logged is looked at, not only warnings.
    Logger.configure(level: :debug)

    on_exit(fn ->
      for {name, value} <- old_env do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      File.rm_rf!(dir)
      Memory.clear()
      Logger.configure(level: old_level)
      Application.put_env(:wallboard, :key_store, Memory)
      :persistent_term.put({Secrets, :new_relic}, old_status)

      if old,
        do: :persistent_term.put({Settings, :settings}, old),
        else: :persistent_term.erase({Settings, :settings})
    end)

    %{dir: dir, saved: Path.join(dir, "settings.json")}
  end

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

  # Stands in for launchctl: a board that runs as this Mac's login item.
  defp mac do
    run = fn program, args ->
      case {Path.basename(program), args} do
        {"id", ["-u"]} ->
          {"501\n", 0}

        {"launchctl", ["print", _]} ->
          {"gui/501/ai.kyroco.wallboard = {\n\tstate = running\n\tenvironment = {\n" <>
             "\t\tWALLBOARD_SETTINGS => #{System.get_env("WALLBOARD_SETTINGS")}\n\t}\n}\n", 0}

        _ ->
          {"", 0}
      end
    end

    [os: {:unix, :darwin}, run: run]
  end

  # Stands in for systemctl: a board that runs as a systemd user service.
  defp linux do
    run = fn program, args ->
      case {Path.basename(program), args} do
        {"systemctl", ["--user", "show", _, "-p", "Environment"]} ->
          {"Environment=WALLBOARD_SETTINGS=#{System.get_env("WALLBOARD_SETTINGS")}\n", 0}

        {"systemctl", ["--user", "is-active", _]} ->
          {"active\n", 0}

        _ ->
          {"", 0}
      end
    end

    [os: {:unix, :linux}, run: run]
  end

  defp io(lines) do
    {:ok, io} = StringIO.open(Enum.join(lines, "\n") <> "\n", capture_prompt: true)
    io
  end

  defp output(io), do: io |> StringIO.contents() |> elem(1)

  # Every file under `dir` that holds `text`.
  defp files_holding(dir, text) do
    for path <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
        File.regular?(path),
        File.read!(path) =~ text,
        do: Path.relative_to(path, dir)
  end

  defp app_show do
    out = io([])
    assert :ok = Setup.json(["show"], mac() ++ [out: out])
    "VITALAIZE_JSON" <> json = String.trim(output(out))
    {json, Jason.decode!(json)}
  end

  defp field(doc, key) do
    Enum.find_value(doc["sections"], fn s -> Enum.find(s["fields"], &(&1["key"] == key)) end)
  end

  defp app_save(values) do
    out = io([])
    result = Setup.json(["save"], mac() ++ [io: io([Jason.encode!(%{values: values})]), out: out])
    "VITALAIZE_JSON" <> json = String.trim(output(out))
    {result, json, Jason.decode!(json)}
  end

  # The key the board holds now, or why it has none.
  defp board_key do
    case Secrets.new_relic() do
      {:ok, fun} -> fun.()
      {:missing, why} -> {:missing, why}
    end
  end

  # A stand-in for 1Password's op command, first on the PATH: it prints
  # the key for the one address it knows.
  defp fake_op(dir, ref, key, wait_s \\ 0) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    op = Path.join(bin, "op")

    File.write!(op, """
    #!/bin/sh
    sleep #{wait_s}
    if [ "$1" = read ] && [ "$2" = #{inspect(ref)} ]; then echo #{inspect(key)}; exit 0; fi
    echo "no such item" >&2; exit 1
    """)

    File.chmod!(op, 0o755)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
  end

  describe "a key typed in the app on a Mac" do
    test "is kept in the keychain, in no settings file, and used by the board", c do
      settings_file(c.dir)

      log =
        capture_log(fn ->
          {:ok, json, answer} = app_save(%{"new_relic.api_key" => @key})
          send(self(), {:answer, json, answer})
          Secrets.load_new_relic(Settings.get())
        end)

      assert_received {:answer, json, answer}
      assert answer["ok"]
      # No restart: it is read again where it runs.
      assert answer["service"] == "untouched"
      assert Enum.any?(answer["lines"], &(&1 =~ "with no restart: New Relic API key"))

      # In the store, and only a note in settings.json.
      assert Memory.all() == %{"new_relic" => @key}

      assert %{
               "new_relic" => %{"api_key" => %{"kept_in" => "the test keychain", "saved_at" => _}}
             } =
               c.saved |> File.read!() |> Jason.decode!()

      assert board_key() == @key

      # Nowhere else: no file, no answer, no log line, no page.
      {shown_json, doc} = app_show()
      assert field(doc, "new_relic.api_key")["value"] == Settings.kept()
      assert field(doc, "new_relic.api_key")["type"] == "secret"
      assert field(doc, "new_relic.api_key")["restart"] == false

      html =
        %{
          __changed__: nil,
          connected?: true,
          allowed?: true,
          notice: nil,
          linked: nil,
          linked_readable?: true,
          confirm_disconnect: nil,
          settings: Settings.get(),
          values: Settings.shown(Settings.get()),
          machines: [],
          ignored_repos: []
        }
        |> SettingsLive.render()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ "New Relic API key"
      assert files_holding(c.dir, @key) == []

      for text <- [
            json,
            shown_json,
            log,
            html,
            inspect(Settings.get()),
            inspect(Secrets.new_relic())
          ],
          do: refute(text =~ @key)
    end

    test "survives a restart: a board started again reads it from the keychain", c do
      settings_file(c.dir)
      {:ok, _, %{"ok" => true}} = app_save(%{"new_relic.api_key" => @key})

      # A new start: nothing in memory but what the files and the store hold.
      :persistent_term.erase({Settings, :settings})
      :persistent_term.erase({Secrets, :new_relic})
      Secrets.load_new_relic(Settings.load!())
      assert board_key() == @key
    end

    test "dots sent back keep it, a new key replaces it, and an empty field removes it", c do
      settings_file(c.dir)
      {:ok, _, %{"ok" => true}} = app_save(%{"new_relic.api_key" => @key})
      note = Settings.get().new_relic.api_key

      # The app sends back the dots it was shown.
      {:ok, _, %{"ok" => true}} = app_save(%{"new_relic.api_key" => Settings.kept()})
      assert Memory.all() == %{"new_relic" => @key}
      assert Settings.get().new_relic.api_key == note

      {:ok, _, %{"ok" => true}} = app_save(%{"new_relic.api_key" => @other})
      assert Memory.all() == %{"new_relic" => @other}
      refute Settings.get().new_relic.api_key == note

      {:ok, _, %{"ok" => true}} = app_save(%{"new_relic.api_key" => ""})
      assert Memory.all() == %{}
      assert Settings.get().new_relic.api_key == nil
      refute File.read!(c.saved) =~ "api_key"
      assert Settings.shown(Settings.get())["new_relic.api_key"] == ""
    end

    test "is checked, and no message repeats what was typed", c do
      settings_file(c.dir)

      for {typed, words} <- [
            {"op://Private/NR/key", "Or where it is in 1Password"},
            {"NRAK has spaces", "exactly as New Relic shows it"},
            {"short", "exactly as New Relic shows it"},
            {~s(NRAK-"quoted"), "exactly as New Relic shows it"}
          ] do
        {result, json, answer} = app_save(%{"new_relic.api_key" => typed})
        assert {:error, _} = result
        assert answer["errors"]["new_relic.api_key"] =~ words
        refute json =~ typed
      end

      # The key itself where its 1Password address goes is turned away,
      # and pointed at the new field.
      {{:error, _}, json, answer} = app_save(%{"new_relic.api_key_ref" => @key})
      assert answer["errors"]["new_relic.api_key_ref"] =~ "New Relic API key"
      refute json =~ @key

      assert Memory.all() == %{}
      refute File.exists?(c.saved)
    end

    test "a keychain that will not take it saves nothing", c do
      settings_file(c.dir)
      Memory.refuse()
      {{:error, _}, json, answer} = app_save(%{"new_relic.api_key" => @key, "brand.name" => "X"})
      assert answer["errors"]["new_relic.api_key"] =~ "could not be kept in the test keychain"
      refute json =~ @key
      refute File.exists?(c.saved)
    end

    test "a keychain that will not let it go keeps it, and the note with it", c do
      settings_file(c.dir)
      {:ok, _, %{"ok" => true}} = app_save(%{"new_relic.api_key" => @key})
      before = File.read!(c.saved)
      Memory.refuse()

      {{:error, _}, json, answer} = app_save(%{"new_relic.api_key" => "", "brand.name" => "X"})

      assert answer["errors"]["new_relic.api_key"] =~
               "could not be taken out of the test keychain"

      refute json =~ @key

      # Nothing saved: the note still points at the key, which is still kept.
      assert File.read!(c.saved) == before
      assert Memory.all() == %{"new_relic" => @key}
    end
  end

  describe "a key typed in vitalaize setup on Linux" do
    test "is in a file only this user can read, and used by the board", c do
      Application.put_env(:wallboard, :key_store, Wallboard.KeyStore.File)
      settings_file(c.dir)
      shown = Settings.load!() |> Settings.shown()
      assert shown["new_relic.api_key"] == ""

      term =
        io([
          # What this machine does: keep it.
          "",
          # Section 4, New Relic: the account, the key, the 1Password
          # address and the region.
          "4",
          "",
          @key,
          "",
          "",
          # Save and finish.
          ""
        ])

      log = capture_log(fn -> assert :ok = Setup.run(linux() ++ [io: term]) end)
      text = output(term)
      assert text =~ "New Relic API key"
      assert text =~ "with no restart: New Relic API key"

      file = Path.join([c.dir, "keys", "new_relic"])
      assert File.read!(file) == @key
      assert %{mode: mode} = File.stat!(file)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(Path.dirname(file)).mode, 0o777) == 0o700

      Secrets.load_new_relic(Settings.get())
      assert board_key() == @key

      # The key file is the one place it is.
      assert files_holding(c.dir, @key) == ["keys/new_relic"]
      refute text =~ @key
      refute log =~ @key

      # Shown as set when asked again.
      again = io(["", "4", "", "", "", "", ""])
      assert :ok = Setup.run(linux() ++ [io: again])
      assert output(again) =~ "New Relic API key [set]"
      refute output(again) =~ @key
      assert File.read!(file) == @key
    end
  end

  describe "a board set up with a 1Password address" do
    test "still loads it and reads the key with op, with nothing to change", c do
      settings_file(c.dir, ~s(new_relic: %{api_key_ref: "op://Private/NR/key", account_id: 1}))
      fake_op(c.dir, "op://Private/NR/key", @other)

      settings = Settings.load!()
      assert settings.new_relic.api_key_ref == "op://Private/NR/key"
      assert settings.new_relic.api_key == nil
      assert Settings.shown(settings)["new_relic.api_key_ref"] == "op://Private/NR/key"

      log = capture_log(fn -> Secrets.load_new_relic(settings) end)
      assert board_key() == @other
      assert log =~ "from 1Password"
      refute log =~ @other
    end

    test "a slow 1Password read that ends after a key is typed does not replace it", c do
      settings_file(c.dir, ~s(new_relic: %{api_key_ref: "op://Private/NR/key"}))
      # 1Password waits for someone to approve, as it can at start-up.
      fake_op(c.dir, "op://Private/NR/key", @other, 1)
      at_start = Settings.load!()
      start_up = Task.async(fn -> Secrets.load_new_relic(at_start) end)

      # Meanwhile the key is typed, and read at once.
      Process.sleep(100)
      another_program_saves(c, %{"new_relic.api_key" => @key})
      Secrets.load_new_relic(Settings.load!())
      assert board_key() == @key

      # 1Password answers last: the typed key stays.
      Task.await(start_up, 10_000)
      assert board_key() == @key
    end

    test "a key typed later wins over the address, and removing it goes back to 1Password", c do
      settings_file(c.dir, ~s(new_relic: %{api_key_ref: "op://Private/NR/key"}))
      fake_op(c.dir, "op://Private/NR/key", @other)

      {:ok, _, %{"ok" => true}} = app_save(%{"new_relic.api_key" => @key})
      Secrets.load_new_relic(Settings.get())
      assert board_key() == @key

      {:ok, _, %{"ok" => true}} = app_save(%{"new_relic.api_key" => ""})
      Secrets.load_new_relic(Settings.get())
      assert board_key() == @other
    end

    test "with neither, the board says how to give one", c do
      settings_file(c.dir)
      Secrets.load_new_relic(Settings.load!())
      assert {:missing, why} = board_key()
      assert why =~ "Type it in the VitalAIze app's Settings or with vitalaize setup"
    end

    test "a note with no key behind it says to type it again", c do
      settings_file(c.dir)
      {:ok, _, %{"ok" => true}} = app_save(%{"new_relic.api_key" => @key})
      Memory.clear()
      capture_log(fn -> Secrets.load_new_relic(Settings.get()) end)
      assert {:missing, why} = board_key()
      assert why =~ "no longer in the test keychain"
    end
  end

  describe "a running board" do
    test "takes up a key saved in the app with no restart, and logs no key", c do
      settings_file(c.dir)
      Settings.load!()
      Secrets.load_new_relic(Settings.get())
      assert {:missing, _} = board_key()

      log =
        capture_log(fn ->
          start_supervised!({Watch, name: :watch_nr_key, every_ms: 20, listener: self()})
          another_program_saves(c, %{"new_relic.api_key" => @key})
          assert_receive {:settings, :reloaded}, 2_000
          assert wait_for(fn -> board_key() == @key end)

          # Replaced in the app: the board follows.
          another_program_saves(c, %{"new_relic.api_key" => @other})
          assert wait_for(fn -> board_key() == @other end)

          # Removed: the board has no key from then on.
          another_program_saves(c, %{"new_relic.api_key" => ""})
          assert wait_for(fn -> match?({:missing, _}, board_key()) end)
        end)

      assert log =~ "Saved settings taken up: New Relic API key"
      refute log =~ @key
      refute log =~ @other
    end

    test "a new 1Password address is read again too", c do
      settings_file(c.dir)
      fake_op(c.dir, "op://Private/NR/key", @other)
      Settings.load!()
      start_supervised!({Watch, name: :watch_nr_ref, every_ms: 20, listener: self()})

      another_program_saves(c, %{"new_relic.api_key_ref" => "op://Private/NR/key"})
      assert_receive {:settings, :reloaded}, 2_000
      assert wait_for(fn -> board_key() == @other end)
    end
  end

  # What the app or `vitalaize setup` does from a process of its own: the
  # running board's settings in memory stay as they are until it looks.
  defp another_program_saves(c, values) do
    assert {:ok, saved} = Settings.change(values)
    assert {:ok, saved} = Settings.keep_keys(saved)
    File.write!(c.saved <> ".tmp", Jason.encode!(saved))
    File.rename!(c.saved <> ".tmp", c.saved)
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  describe "the key prompt in a real terminal" do
    # `script` gives the prompt a terminal of its own, as a person's would
    # be, and records what that terminal shows. The key is typed once the
    # prompt is up, as a person would type it. The next question is asked
    # the ordinary way, and must show what is typed again and take a
    # Backspace as a correction.
    test "leaves the key off the screen, reads it whole, and leaves the next prompt as it was" do
      ebin = Application.app_dir(:wallboard, "ebin")
      elixir = System.find_executable("elixir")

      code =
        ~s[key = Wallboard.Setup.gets_hidden(:stdio, "key: "); ] <>
          ~s[IO.inspect({key, IO.gets("next: ")}, label: "read")]

      command = [elixir, "-pa", ebin, "-e", code]

      args =
        case :os.type() do
          {:unix, :darwin} -> ["-q", "/dev/null" | command]
          _ -> ["-qec", Enum.map_join(command, " ", &shell_word/1), "/dev/null"]
        end

      port =
        Port.open({:spawn_executable, System.find_executable("script")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args
        ])

      shown = until_screen(port, "key: ", "")
      Port.command(port, @key <> "\r")
      shown = until_screen(port, "next: ", shown)
      # A slip, Backspace, and the rest.
      Port.command(port, "abX\x7Fcd\r")
      shown = until_exit(port, shown)

      assert shown =~ ~s(read: {"#{@key}", "abcd\\n"})
      assert shown =~ "next: abX"
      # The only place the key is on the screen is the line the test
      # program printed itself.
      assert shown |> String.split(@key) |> length() == 2
    end
  end

  defp shell_word(word), do: "'" <> String.replace(word, "'", ~S('\'')) <> "'"

  defp until_screen(port, text, acc) do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data
        if acc =~ text, do: acc, else: until_screen(port, text, acc)
    after
      30_000 -> flunk("the prompt never showed: #{inspect(acc)}")
    end
  end

  defp until_exit(port, acc) do
    receive do
      {^port, {:data, data}} -> until_exit(port, acc <> data)
      {^port, {:exit_status, _}} -> acc
    after
      30_000 -> flunk("the prompt never ended: #{inspect(acc)}")
    end
  end

  describe "removing VitalAIze" do
    test "keeps the key, unless the settings are deleted too", c do
      settings_file(c.dir)
      {:ok, _, %{"ok" => true}} = app_save(%{"new_relic.api_key" => @key})

      # Remove: the settings stay, and so does the key they point to.
      out = io([])
      assert :ok = Setup.json(["remove"], mac() ++ [out: out])
      assert Memory.all() == %{"new_relic" => @key}

      # Remove with the database and settings deleted: the key goes too, and
      # the person is told.
      out = io([])
      assert :ok = Setup.json(["remove", "keys"], mac() ++ [out: out])
      "VITALAIZE_JSON" <> json = String.trim(output(out))
      assert %{"ok" => true, "lines" => lines} = Jason.decode!(json)
      assert "Took the New Relic API key out of the test keychain." in lines
      assert Memory.all() == %{}
      refute json =~ @key

      # With none kept, nothing is said about it.
      out = io([])
      assert :ok = Setup.json(["remove", "keys"], mac() ++ [out: out])
      refute output(out) =~ "New Relic"
    end
  end

  describe "the stores" do
    test "the file store keeps, replaces and removes a key, closed to others", c do
      opts = [dir: Path.join(c.dir, "keys")]
      assert KeyStore.File.fetch("new_relic", opts) == :none
      assert :ok = KeyStore.File.put("new_relic", @key, opts)
      assert KeyStore.File.fetch("new_relic", opts) == {:ok, @key}
      assert :ok = KeyStore.File.put("new_relic", @other, opts)
      assert KeyStore.File.fetch("new_relic", opts) == {:ok, @other}
      assert Bitwise.band(File.stat!(Path.join(c.dir, "keys/new_relic")).mode, 0o777) == 0o600
      # Nothing half written is left beside it.
      assert File.ls!(Path.join(c.dir, "keys")) == ["new_relic"]
      assert :ok = KeyStore.File.delete("new_relic", opts)
      assert :ok = KeyStore.File.delete("new_relic", opts)
      assert KeyStore.File.fetch("new_relic", opts) == :none
    end

    test "a keychain named with a quote or a backslash is refused, never swapped for the person's own" do
      # Refused before security runs, so the person's keychain is not reached.
      for path <- [~s(/tmp/a"b.keychain-db), "/tmp/a\\b.keychain-db"] do
        for result <- [
              KeyStore.Keychain.put("new_relic", @key, keychain: path),
              KeyStore.Keychain.fetch("new_relic", keychain: path),
              KeyStore.Keychain.delete("new_relic", keychain: path)
            ],
            do: assert({:error, "the keychain named in VITALAIZE_KEYCHAIN" <> _} = result)
      end
    end

    test "a name that is not a plain word is refused before any store sees it" do
      for name <- ["../x", "New", "a b", "", "x/y"],
          do: assert({:error, "not a key name"} = KeyStore.put(name, @key))
    end

    test "the keychain keeps, replaces and removes a key, in a throwaway keychain", c do
      if :os.type() != {:unix, :darwin}, do: :ok, else: keychain_round(c.dir)
    end
  end

  # A keychain file of this test's own: the person's keychains are never
  # touched.
  defp keychain_round(dir) do
    keychain = Path.join(dir, "test.keychain-db")
    {_, 0} = System.cmd("security", ["create-keychain", "-p", "", keychain])

    on_exit(fn ->
      System.cmd("security", ["delete-keychain", keychain], stderr_to_stdout: true)
    end)

    {_, 0} = System.cmd("security", ["unlock-keychain", "-p", "", keychain])
    opts = [keychain: keychain]
    store = KeyStore.Keychain

    assert store.fetch("new_relic", opts) == :none
    assert :ok = store.put("new_relic", @key, opts)
    assert store.fetch("new_relic", opts) == {:ok, @key}
    assert :ok = store.put("new_relic", @other, opts)
    assert store.fetch("new_relic", opts) == {:ok, @other}
    assert :ok = store.delete("new_relic", opts)
    assert :ok = store.delete("new_relic", opts)
    assert store.fetch("new_relic", opts) == :none

    # A keychain that cannot be written to is found out, though security
    # says it worked.
    assert {:error, "the keychain did not keep it"} =
             store.put("new_relic", @key, keychain: Path.join(dir, "missing.keychain-db"))

    # The store's own check, not only the settings': a "key" that would add
    # words to security's command, such as -A (any app may read it) or a
    # quote that ends the key early, is refused and nothing is kept.
    for bad <- ["abcdefgh -A", ~s(abcdefgh" -A "x), "abc\tdefgh", "abcdefgh\\"] do
      assert {:error, "it holds characters a key does not"} = store.put("new_relic", bad, opts)
    end

    assert store.fetch("new_relic", opts) == :none
  end

  describe "a command given a line of input" do
    test "gets it on its standard input, and only one line is taken" do
      assert {:ok, "a line\n"} = Cmd.run("cat", [], input: "a line")
      assert {:error, "cat takes one line of input"} = Cmd.run("cat", [], input: "a\nb")
      assert {:error, "false exited with 1"} = Cmd.run("false", [], input: "x")
    end

    test "the line is on no command line while the program runs" do
      # The program prints its own command line and the shell's above it.
      {:ok, out} =
        Cmd.run("sh", ["-c", ~s(cat >/dev/null; ps -o args= -p $$ -p $PPID)], input: @key)

      assert out =~ "ps -o args="
      refute out =~ @key
    end
  end
end
