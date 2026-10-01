defmodule Wallboard.OldCollectorTest do
  # Moving a machine off the upload hooks of VitalAIze 0.2.0: the hooks
  # come out of its Claude and Codex settings, and the hub refuses what
  # they still send. Every Claude and Codex folder here is a made-up one
  # under the temp folder (see config/test.exs for the guard).
  use ExUnit.Case, async: false

  alias Wallboard.{Mailbox, OldCollectors, Pairing, Settings, Setup, Store}
  alias Wallboard.Link.Authority
  alias Wallboard.Setup.OldHooks
  alias WallboardWeb.OldCollectorController

  @moduletag :capture_log

  @env ["WALLBOARD_SETTINGS", "WALLBOARD_SAVED_SETTINGS", "WALLBOARD_ROLE", "RELEASE_ROOT"]

  setup do
    dir = Wallboard.Fixtures.tmp_path("wallboard-old")
    home = Path.join(dir, "home")
    File.mkdir_p!(home)

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

    %{dir: dir, home: home}
  end

  # ---------------------------------------------------------------------------
  # Made-up hook files

  # Claude's settings as their owner left them: an odd layout on purpose,
  # hooks of their own, and a text that looks like JSON inside a string.
  @claude """
  {
      "model": "opus",
    "hooks": {
      "Stop": [
        {"hooks": [{"type": "command",   "command": "/usr/local/bin/my-stop.sh"}]}
      ],
      "PreToolUse": [
        { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/bin/guard.sh" } ] }
      ]
    },
    "permissions": {"allow": ["Bash(ls:*)"]},
    "note": "caf\\u00e9 \\"quoted\\" } ] wallboard-upload.sh, 1e3"
  }
  """

  defp upload_hook(folder),
    do:
      ~s({"type": "command", "command": "#{folder}/wallboard-upload.sh", "async": true, "timeout": 120})

  # The same file after 0.2.0 connected the machine: its hooks in a group
  # of their own after the owner's, before the owner's, in events of their
  # own in the middle and at the end, and one inside the owner's own group.
  defp claude_connected(folder) do
    ours = upload_hook(folder)

    @claude
    |> insert_after(
      ~s("/usr/local/bin/my-stop.sh"}]}),
      ~s(,\n      {"hooks": [#{ours}]})
    )
    |> insert_before(
      ~s("PreToolUse": [),
      ~s("Notification": [\n      {"matcher": "permission_prompt", "hooks": [#{ours}]}\n    ],\n    )
    )
    |> insert_before(
      ~s({ "matcher": "Bash"),
      ~s({"matcher": "AskUserQuestion", "hooks": [#{ours}]},\n      )
    )
    |> insert_after(~s("command": "~/bin/guard.sh" }), ~s(, #{ours}))
    |> insert_after(
      ~s("~/bin/guard.sh" }, #{ours} ] }\n    ]),
      ~s(,\n    "SessionEnd": [{"hooks": [#{ours}]}],\n    "UserPromptSubmit": [{"hooks": [#{ours}]}])
    )
  end

  # Codex's hooks.json with VitalAIze's own "Needs you" hook, which stays.
  @codex """
  {
    "hooks": {
      "Stop": [
        {
          "hooks": [
            {
              "type": "command",
              "command": "/home/r/.codex/vitalaize/codex-hook.sh"
            }
          ]
        }
      ]
    }
  }
  """

  defp codex_connected(folder) do
    ours = upload_hook(folder)

    @codex
    |> insert_after(
      "        ]\n      }",
      ~s(,\n      {\n        "hooks": [#{ours}]\n      })
    )
    |> insert_after("\n    ]", ~s(,\n    "SessionEnd": [{"hooks": [#{ours}]}]))
  end

  defp insert_after(text, anchor, more) do
    assert [_, _] = String.split(text, anchor)
    String.replace(text, anchor, anchor <> more)
  end

  defp insert_before(text, anchor, more) do
    assert [_, _] = String.split(text, anchor)
    String.replace(text, anchor, more <> anchor)
  end

  # A machine as 0.2.0 left it: a Claude folder and a Codex folder, each
  # with the upload script and its hooks, and a second Claude folder that
  # had no settings before it was connected.
  defp connected_machine(home) do
    claude = Path.join(home, ".claude")
    work = Path.join(home, ".claude-work")
    codex = Path.join(home, ".codex")
    for folder <- [claude, work, codex], do: File.mkdir_p!(folder)

    File.write!(Path.join(claude, "settings.json"), claude_connected(claude))
    File.chmod!(Path.join(claude, "settings.json"), 0o600)
    File.write!(Path.join(codex, "hooks.json"), codex_connected(codex))

    File.write!(
      Path.join(work, "settings.json"),
      ~s({\n  "hooks": {\n    "Stop": [\n      {"hooks": [#{upload_hook(work)}]}\n    ]\n  }\n}\n)
    )

    for folder <- [claude, work, codex] do
      File.write!(
        Path.join(folder, "wallboard-upload.sh"),
        "#!/bin/sh\nKEY=old-shared-key\ncurl http://hub:4747/ingest/transcript\n"
      )
    end

    %{claude: claude, work: work, codex: codex}
  end

  defp io(lines) do
    {:ok, io} = StringIO.open(Enum.join(lines, "\n") <> "\n", capture_prompt: true)
    io
  end

  defp output(io), do: io |> StringIO.contents() |> elem(1)

  defp settings_file(dir, more) do
    File.write!(Path.join(dir, "settings.exs"), """
    %{
      archive: %{path: #{inspect(Path.join(dir, "wallboard.db"))}, advertise: false},
      collector: %{dir: #{inspect(Path.join(dir, "collector"))}},
      claude: %{config_dirs: []},
      codex: %{dirs: []},
      #{more}
    }
    """)
  end

  # Plays systemd with the collector already running as a service.
  defp linux do
    settings = System.get_env("WALLBOARD_SETTINGS")
    me = self()

    run = fn program, args ->
      send(me, {:ran, Path.basename(program), args})

      case {Path.basename(program), args} do
        {"systemctl", ["--user", "show", _, "-p", "Environment"]} ->
          {"Environment=WALLBOARD_SETTINGS=#{settings} RELEASE_DISTRIBUTION=none\n", 0}

        {"systemctl", ["--user", "is-active", _]} ->
          {"active\n", 0}

        _ ->
          {"", 0}
      end
    end

    [os: {:unix, :linux}, run: run]
  end

  # ---------------------------------------------------------------------------

  describe "setting up the new collector on a machine 0.2.0 connected" do
    test "VitalAIze's hooks are gone, every other hook is as it was byte for byte, and a backup exists",
         %{dir: dir, home: home} do
      folders = connected_machine(home)
      settings_file(dir, ~s(role: "collector"))
      before = File.read!(Path.join(folders.claude, "settings.json"))
      codex_before = File.read!(Path.join(folders.codex, "hooks.json"))
      assert before =~ "wallboard-upload.sh\", \"async\""

      # Enter keeps each setting; then the hub's address.
      term = io(["", "", "", "10.0.0.9"])
      pair = fn _ -> {:ok, %{machine: "papa"}} end

      assert :ok =
               Setup.run(linux() ++ [io: term, pair: pair, home: home, env: fn _ -> nil end])

      text = output(term)

      # Claude: the file is what its owner wrote, to the byte.
      settings = Path.join(folders.claude, "settings.json")
      assert File.read!(settings) == @claude
      assert File.read!(settings <> ".before-collector") == before
      assert Bitwise.band(File.stat!(settings).mode, 0o777) == 0o600
      assert text =~ "Took 6 old VitalAIze upload hooks out of #{settings}."
      assert text =~ "the file from before is #{settings}.before-collector"

      # Codex: its "Needs you" hook stays, to the byte.
      hooks = Path.join(folders.codex, "hooks.json")
      assert File.read!(hooks) == @codex
      assert File.read!(hooks) =~ "codex-hook.sh"
      assert File.read!(hooks <> ".before-collector") == codex_before
      assert text =~ "Took 2 old VitalAIze upload hooks out of #{hooks}."

      # A file that held nothing else is left empty, not deleted.
      assert File.read!(Path.join(folders.work, "settings.json")) == "{}\n"
      assert text =~ "Took 1 old VitalAIze upload hook out of"

      # The script held the hub's old key, so it is gone everywhere.
      for folder <- Map.values(folders) do
        refute File.exists?(Path.join(folder, "wallboard-upload.sh"))
        assert text =~ "Deleted the old upload script #{folder}/wallboard-upload.sh."
      end

      # The hooks come out before the new collector pairs.
      [hooks_at, paired_at] =
        for words <- ["Took 6 old", "Approved. This machine is connected as papa."] do
          {at, _} = :binary.match(text, words)
          at
        end

      assert hooks_at < paired_at
    end

    test "running it again changes nothing and makes no second backup", %{dir: dir, home: home} do
      folders = connected_machine(home)
      settings_file(dir, ~s(role: "collector"))
      opts = [home: home, env: fn _ -> nil end]

      assert [_ | _] = Setup.retire_old_hooks(Settings.load!(), opts)
      assert Setup.retire_old_hooks(Settings.load!(), opts) == []
      refute File.exists?(Path.join(folders.claude, "settings.json.before-collector-2"))
    end

    test "an earlier backup is never written over", %{home: home} do
      folders = connected_machine(home)
      settings = Path.join(folders.claude, "settings.json")
      File.write!(settings <> ".before-collector", "an earlier copy")

      assert [%{file: ^settings, hooks: 6, backup: backup} | _] =
               OldHooks.retire(%{claude: [folders.claude], codex: []})

      assert backup == settings <> ".before-collector-2"
      assert File.read!(settings <> ".before-collector") == "an earlier copy"
    end

    test "a settings file that is a link stays a link", %{dir: dir, home: home} do
      folders = connected_machine(home)
      real = Path.join(dir, "dotfiles-settings.json")
      link = Path.join(folders.claude, "settings.json")
      File.rename!(link, real)
      File.ln_s!(real, link)

      assert [%{hooks: 6} | _] = OldHooks.retire(%{claude: [folders.claude], codex: []})
      assert {:ok, %{type: :symlink}} = File.lstat(link)
      assert File.read!(real) == @claude
    end

    test "a file it cannot read as JSON is left alone, and said so", %{home: home} do
      folders = connected_machine(home)
      settings = Path.join(folders.claude, "settings.json")
      broken = "// my notes\n" <> File.read!(settings)
      File.write!(settings, broken)

      assert [%{file: ^settings, error: :not_json} | _] =
               results = OldHooks.retire(%{claude: [folders.claude], codex: []})

      assert File.read!(settings) == broken
      refute File.exists?(settings <> ".before-collector")
      assert hd(OldHooks.report(results)) =~ "Take out the hooks that run wallboard-upload.sh"
    end

    test "only a wallboard-upload.sh hook is VitalAIze's to take" do
      assert OldHooks.ours?("/Users/r/.claude/wallboard-upload.sh")
      assert OldHooks.ours?(~s("/Users/r/My Claude/wallboard-upload.sh"))
      refute OldHooks.ours?("/Users/r/.codex/vitalaize/codex-hook.sh")
      refute OldHooks.ours?("/Users/r/.claude/wallboard-upload.sh.mine")
      refute OldHooks.ours?("wallboard-upload.sh --mine")
      refute OldHooks.ours?(nil)

      assert OldHooks.strip(@claude) == :unchanged
      assert OldHooks.strip(@codex) == :unchanged
      assert OldHooks.strip("[1, 2]") == :unchanged
      assert OldHooks.strip("{ nope") == {:error, :not_json}
    end

    test "a file written on one line, or by another tool, loses only those hooks" do
      ours = upload_hook("/h/.claude")

      one_line =
        ~s({"hooks":{"Stop":[{"hooks":[#{ours}]},{"hooks":[{"command":"a"}]},{"hooks":[#{ours}]}],"X":[]},"z":1})

      assert {:ok, text, 2} = OldHooks.strip(one_line)
      assert text == ~s({"hooks":{"Stop":[{"hooks":[{"command":"a"}]}],"X":[]},"z":1})

      # Hooks that are all VitalAIze's, with tabs and Windows line ends.
      tabs =
        "{\r\n\t\"a\": [1, {\"b\": null}],\r\n\t\"hooks\": {\"Stop\": [{\"hooks\": [#{ours}]}]}\r\n}"

      assert {:ok, text, 1} = OldHooks.strip(tabs)
      assert text == "{\r\n\t\"a\": [1, {\"b\": null}]\r\n}"
    end

    test "the folders looked in are this user's own, the settings' and the old app's",
         %{dir: dir, home: home} do
      folders = connected_machine(home)
      elsewhere = Path.join(dir, "elsewhere")
      by_app = Path.join(dir, "by-app")
      by_env = Path.join(dir, "by-env")
      for folder <- [elsewhere, by_app, by_env], do: File.mkdir_p!(folder)

      File.write!(
        Path.join(dir, "install.json"),
        Jason.encode!(%{hookedFolders: [by_app], hookedCodex: by_app})
      )

      env = fn
        "CLAUDE_CONFIG_DIR" -> by_env
        _ -> nil
      end

      settings = %{collector: %{claude_dirs: [elsewhere, Path.join(dir, "not-there")]}}
      found = OldHooks.folders(settings, home: home, env: env, data: dir)

      assert found.claude == [folders.claude, folders.work, by_env, elsewhere, by_app]
      assert found.codex == [folders.codex, by_app]
    end
  end

  describe "removing VitalAIze from a machine" do
    test "takes out the old hooks and the certificate", %{dir: dir, home: home} do
      folders = connected_machine(home)
      settings_file(dir, ~s(role: "collector"))
      link = Pairing.dir(Settings.load!())
      File.mkdir_p!(link)

      for name <- ~w(key.pem cert.pem ca.pem hub.json),
          do: File.write!(Path.join(link, name), "x")

      {:ok, out} = StringIO.open("")
      opts = [out: out, home: home, env: fn _ -> nil end]
      assert :ok = Setup.json(["remove"], opts)

      "VITALAIZE_JSON" <> json = out |> StringIO.contents() |> elem(1)
      assert %{"ok" => true, "lines" => lines} = Jason.decode!(json)
      assert Enum.any?(lines, &(&1 =~ "Took 6 old VitalAIze upload hooks"))
      assert Enum.any?(lines, &(&1 =~ "Deleted this machine's certificate"))

      refute File.exists?(link)
      assert File.read!(Path.join(folders.claude, "settings.json")) == @claude
      assert File.read!(Path.join(folders.codex, "hooks.json")) == @codex
    end

    test "vitalaize remove asks first, then stops the service too", %{dir: dir, home: home} do
      folders = connected_machine(home)
      settings_file(dir, ~s(role: "collector"))
      link = Pairing.dir(Settings.load!())
      File.mkdir_p!(link)
      File.write!(Path.join(link, "cert.pem"), "x")
      before = File.read!(Path.join(folders.claude, "settings.json"))
      opts = linux() ++ [home: home, env: fn _ -> nil end, root: dir]

      # Enter is no.
      term = io([""])
      assert :ok = Setup.remove_here([io: term] ++ opts)
      assert output(term) =~ "Nothing removed."
      assert File.read!(Path.join(folders.claude, "settings.json")) == before
      assert File.exists?(link)
      refute_received {:ran, "systemd.sh", _}

      term = io(["yes"])
      assert :ok = Setup.remove_here([io: term] ++ opts)
      text = output(term)
      assert_received {:ran, "systemd.sh", ["off"]}
      assert text =~ "Stopped VitalAIze. It no longer starts when you log in."
      assert text =~ "Took 6 old VitalAIze upload hooks"
      assert text =~ "Deleted this machine's certificate"
      assert text =~ "Your settings are still in #{dir}."
      assert File.read!(Path.join(folders.claude, "settings.json")) == @claude
      refute File.exists?(link)
    end

    test "works beside a settings file that does not load", %{dir: dir, home: home} do
      folders = connected_machine(home)
      File.write!(Path.join(dir, "settings.exs"), "%{ this is not Elixir")

      {:ok, out} = StringIO.open("")
      assert :ok = Setup.json(["retire"], out: out, home: home, env: fn _ -> nil end)
      assert File.read!(Path.join(folders.claude, "settings.json")) == @claude
    end
  end

  # ---------------------------------------------------------------------------

  describe "a machine that still sends the old way" do
    setup %{dir: dir} do
      Settings.put(%{archive: %{path: Path.join(dir, "wallboard.db"), machine: "the-hub"}})
      start_supervised!({Store, path: Path.join(dir, "wallboard.db")})
      start_supervised!(OldCollectors)

      pid =
        start_supervised!(
          {Bandit, plug: WallboardWeb.Router, ip: :loopback, port: 0, startup_log: false}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(pid)
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Mailbox.topic())
      %{port: port, link: Path.join(dir, "link")}
    end

    # What the old upload script sends: the shared key, and a body.
    defp old_call(port, path, body \\ "a transcript") do
      url = ~c"http://127.0.0.1:#{port}#{path}"
      headers = [{~c"authorization", ~c"Bearer the-old-shared-key"}]
      request = {url, headers, ~c"application/gzip", body}

      {:ok, {{_, status, _}, _, answer}} =
        :httpc.request(:post, request, [], body_format: :binary)

      {status, answer}
    end

    defp old_items, do: for(%{id: "old:" <> _} = item <- Mailbox.items(), do: item)

    test "gets the refusal, and the mailbox gets exactly one item for that machine", c do
      refusal = OldCollectorController.refusal()
      assert refusal =~ "no longer takes uploads from the old collector"
      assert refusal =~ "vitalaize setup"

      assert {410, ^refusal} =
               old_call(c.port, "/ingest/transcript?machine=build-box&account=.claude")

      assert_receive {:mailbox, :changed}

      assert [item] = old_items()
      assert item.id == "old:build-box"
      assert item.title == "A machine still uses the old collector"

      assert item.body == [
               {:strong, "build-box"},
               {:text, " still uses the old collector. Install the new one on it."}
             ]

      # Every later call is refused the same, and adds nothing: a Codex
      # upload, a "waiting" message, and the script being fetched again.
      assert {410, ^refusal} =
               old_call(c.port, "/ingest/transcript?tool=codex&machine=build-box&account=.codex")

      assert {410, ^refusal} = old_call(c.port, "/ingest/status?machine=build-box&at=1", "{}")

      assert {:ok, {{_, 410, _}, _, _}} =
               :httpc.request(
                 :get,
                 {~c"http://127.0.0.1:#{c.port}/ingest/install.sh", []},
                 [],
                 []
               )

      assert [%{id: "old:build-box"}] = old_items()
      refute_receive {:mailbox, :changed}, 100

      # Nothing it sent was kept: no session, and no inbox folder.
      assert Store.counts().total == 0
      refute File.exists?(Path.join(c.dir, "inbox"))

      # Another machine has its own item.
      assert {410, _} = old_call(c.port, "/ingest/transcript?machine=papa-mac")
      assert Enum.map(old_items(), & &1.id) == ["old:build-box", "old:papa-mac"]
    end

    test "the item goes when that machine pairs", c do
      old_call(c.port, "/ingest/transcript?machine=Build-Box")
      old_call(c.port, "/ingest/transcript?machine=papa-mac")
      assert [_, _] = old_items()

      # The owner approves the new collector: it now holds a certificate.
      Authority.ensure!(c.link)
      {:ok, _} = Authority.issue(c.link, "build-box")
      assert Enum.map(old_items(), & &1.id) == ["old:papa-mac"]

      # Its hooks may run on for a moment: that brings no item back.
      old_call(c.port, "/ingest/status?machine=Build-Box", "{}")
      assert Enum.map(old_items(), & &1.id) == ["old:papa-mac"]
    end

    test "Dismiss takes an item off for good, and the list outlives a restart", c do
      old_call(c.port, "/ingest/transcript?machine=build-box")
      old_call(c.port, "/ingest/transcript?machine=gone-box")
      assert_receive {:mailbox, :changed}
      assert_receive {:mailbox, :changed}

      assert :ok = Mailbox.act("old:gone-box", "dismiss")
      assert_receive {:mailbox, :changed}
      assert {:error, :gone} = Mailbox.act("old:gone-box", "dismiss")
      assert {:error, :gone} = Mailbox.act("old:build-box", "approve")

      old_call(c.port, "/ingest/transcript?machine=gone-box")
      assert Enum.map(old_items(), & &1.id) == ["old:build-box"]

      stop_supervised!(OldCollectors)
      start_supervised!(OldCollectors)
      old_call(c.port, "/ingest/transcript?machine=gone-box")
      assert Enum.map(old_items(), & &1.id) == ["old:build-box"]
    end

    test "a call cannot fill the mailbox or put its own words there", c do
      for name <- ["..", "a%20b", "a%2Fb", "x%0Ay", String.duplicate("n", 65), ""] do
        assert {410, _} = old_call(c.port, "/ingest/transcript?machine=#{name}")
      end

      assert {410, _} = old_call(c.port, "/ingest/transcript")
      assert old_items() == []

      for n <- 1..30, do: old_call(c.port, "/ingest/status?machine=flood-#{n}", "{}")
      assert length(old_items()) == 20
    end
  end
end
