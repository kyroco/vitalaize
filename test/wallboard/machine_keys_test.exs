defmodule Wallboard.MachineKeysTest do
  use ExUnit.Case, async: false

  alias Wallboard.Archive.{Ingest, MachineKeys}
  alias Wallboard.{Fixtures, Settings, Store, TestHub}
  alias WallboardWeb.SettingsLive

  @sid "9f8651f6-634b-47b7-a4db-b27994e624eb"

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "wallboard-keys-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A hub with its archive on, in a throwaway folder.
  defp hub(dir) do
    old = Settings.get()
    on_exit(fn -> :persistent_term.put({Wallboard.Settings, :settings}, old) end)
    start_supervised!({Store, path: ":memory:"})
    Settings.put(%{archive: %{enabled: true, path: Path.join(dir, "wallboard.db")}})
    TestHub.serve()
  end

  # A .tar.gz that unpacks to about `mb` megabytes of zeros, made small: one
  # megabyte compressed with a full flush comes out the same every time,
  # so it can be repeated. The end of the stream is left off, as unpacking
  # never gets that far.
  defp bomb(mb) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :best_compression, :deflated, 31, 8, :default)
    zeros = :binary.copy(<<0>>, 1_000_000)
    first = IO.iodata_to_binary(:zlib.deflate(z, zeros, :full))
    again = IO.iodata_to_binary(:zlib.deflate(z, zeros, :full))
    :zlib.close(z)
    first <> :binary.copy(again, mb - 1)
  end

  describe "the size limit" do
    test "an upload that would unpack past the limit is refused as it passes it" do
      # About 20 GB unpacked, from about 20 MB: unpacking it all would take
      # more memory than the machine running this test has.
      big = bomb(20_000)
      assert byte_size(big) < 25_000_000
      assert MachineKeys.window() == 300

      {micros, result} = :timer.tc(fn -> Ingest.unpack(big) end)
      assert result == {:error, :too_big}
      # It stopped at the limit, 512 MB in, not 20 GB.
      assert Ingest.max_unpacked() == 512_000_000
      assert micros < 30_000_000
    end

    test "an archive within the limit unpacks, and a cut-short one is refused" do
      files = [{~c"#{@sid}.jsonl", "{}\n"}]
      path = Path.join(tmp_dir(), "up.tgz")
      :ok = :erl_tar.create(String.to_charlist(path), files, [:compressed])
      tgz = File.read!(path)

      assert {:ok, [{name, "{}\n"}]} = Ingest.unpack(tgz)
      assert name == "#{@sid}.jsonl"

      assert Ingest.unpack(binary_part(tgz, 0, div(byte_size(tgz), 2))) ==
               {:error, "not a .tar.gz"}

      assert Ingest.unpack("not gzip at all") == {:error, "not a .tar.gz"}
    end

    test "the hub answers an upload past the limit with 413 and saves nothing" do
      dir = tmp_dir()
      url = hub(dir)
      Application.put_env(:wallboard, :max_unpacked, 5_000_000)
      on_exit(fn -> Application.delete_env(:wallboard, :max_unpacked) end)
      {id, key} = Fixtures.connect_machine(Path.join(dir, "laptop"), "laptop")

      assert Fixtures.signed_post(url, "/ingest/transcript?machine=laptop", bomb(50), id, key) ==
               {"413", "the upload unpacks to more than the hub takes"}

      refute File.exists?(Path.join([dir, "inbox", "laptop"]))
    end
  end

  describe "connecting a machine" do
    setup do
      dir = tmp_dir()
      url = hub(dir)
      claude = Path.join(dir, ".claude")
      codex = Path.join(dir, ".codex")
      File.mkdir_p!(codex)
      install = Path.join(dir, "install.sh")
      File.write!(install, Ingest.install_script(url))
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)
      %{dir: dir, url: url, claude: claude, codex: codex, install: install, bin: bin}
    end

    # Runs a script with throwaway home, Claude and Codex folders, never the
    # real ones, and a PATH of the system's own tools after dir/bin.
    defp sh(ctx, args, env, input \\ nil) do
      args = if input, do: ["-c", ~s(sh "$0" < "$1"), hd(args), input], else: args

      System.cmd("sh", args,
        env:
          [
            {"HOME", ctx.dir},
            {"TMPDIR", ctx.dir},
            {"CLAUDE_CONFIG_DIR", ctx.claude},
            {"CODEX_HOME", ctx.codex},
            {"PATH", Enum.join([ctx.bin, "/usr/bin", "/bin", "/usr/sbin", "/sbin"], ":")}
          ] ++ env,
        stderr_to_stdout: true
      )
    end

    defp connect(ctx, key \\ nil),
      do: sh(ctx, [ctx.install], [{"WALLBOARD_KEY", key || MachineKeys.connect_key()}])

    # A Claude session ending, as its Stop hook tells the upload script.
    defp stop_hook(ctx) do
      project = Path.join([ctx.claude, "projects", "app"])
      File.mkdir_p!(project)
      transcript = Path.join(project, "#{@sid}.jsonl")

      File.write!(
        transcript,
        Jason.encode!(%{
          type: "user",
          sessionId: @sid,
          timestamp: "2026-09-30T13:00:00Z",
          message: %{role: "user", content: "hello"}
        }) <> "\n"
      )

      input = Path.join(ctx.dir, "stop.json")

      File.write!(
        input,
        Jason.encode!(%{
          session_id: @sid,
          transcript_path: transcript,
          hook_event_name: "SessionEnd"
        })
      )

      sh(ctx, [Path.join(ctx.claude, "wallboard-upload.sh")], [], input)
    end

    defp saved_machines,
      do: Store.query("SELECT machine FROM sessions", []) |> Enum.map(& &1.machine)

    test "gives the machine a key of its own that never crosses the network, and it sends", ctx do
      assert {out, 0} = connect(ctx)
      assert [_, machine] = Regex.run(~r/Connected as (\S+)\./, out)
      assert [%{machine: ^machine, key_id: id, last_used_at: nil}] = MachineKeys.list()

      # The same key beside each upload script, readable only by this user,
      # and neither key written into a script.
      for folder <- [ctx.claude, ctx.codex] do
        file = Path.join(folder, "wallboard-key")

        assert File.read!(file) ==
                 "#{id}\n#{machine}\n#{MachineKeys.derive(MachineKeys.connect_key(), id)}\n"

        assert File.stat!(file).access == :read_write
        assert Bitwise.band(File.stat!(file).mode, 0o077) == 0
        script = File.read!(Path.join(folder, "wallboard-upload.sh"))
        refute script =~ MachineKeys.connect_key()
        refute script =~ MachineKeys.derive(MachineKeys.connect_key(), id)
      end

      assert {"", 0} = stop_hook(ctx)
      assert saved_machines() == [machine]
      assert [%{last_used_at: used}] = MachineKeys.list()
      assert is_integer(used)
    end

    test "connecting again replaces the machine's key rather than adding one", ctx do
      assert {_, 0} = connect(ctx)
      assert [%{key_id: first}] = MachineKeys.list()
      assert {_, 0} = connect(ctx)
      assert [%{key_id: second}] = MachineKeys.list()
      assert first != second
    end

    test "a wrong connect key changes nothing on the machine", ctx do
      assert {out, 1} = connect(ctx, "not-the-key")
      assert out =~ "did not connect this machine (401): wrong signature"
      assert MachineKeys.list() == []
      refute File.exists?(Path.join(ctx.claude, "wallboard-key"))
      refute File.exists?(Path.join(ctx.claude, "settings.json"))
    end

    test "the connect command needs the key it is given", ctx do
      assert {out, 1} = sh(ctx, [ctx.install], [])
      assert out =~ "Copy the whole connect command"
    end

    test "with no Digest::SHA for perl, openssl signs instead", ctx do
      # A perl that fails, as one without Digest::SHA would.
      File.write!(Path.join(ctx.bin, "perl"), "#!/bin/sh\nexit 2\n")
      File.chmod!(Path.join(ctx.bin, "perl"), 0o755)

      assert {out, 0} = connect(ctx)
      assert out =~ "Connected as"
      assert {"", 0} = stop_hook(ctx)
      assert length(saved_machines()) == 1
    end

    test "the connect key cannot send sessions, and a machine key cannot connect", ctx do
      {id, key} = Fixtures.connect_machine(Path.join(ctx.dir, "laptop"), "laptop")

      assert {"401", "sign with the connect key"} =
               Fixtures.signed_post(
                 ctx.url,
                 "/ingest/connect?machine=x&key=#{String.duplicate("c", 32)}",
                 "",
                 id,
                 key
               )

      assert {"401", "sign with this machine's key"} =
               Fixtures.signed_post(
                 ctx.url,
                 "/ingest/transcript?machine=laptop",
                 "",
                 "connect",
                 MachineKeys.connect_key()
               )
    end
  end

  describe "the settings page" do
    defp page do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          allowed?: true,
          connected?: true,
          errors: %{},
          notice: nil,
          restart?: false,
          show_key?: false,
          confirm_new_key?: false,
          confirm_disconnect: nil,
          flash: %{}
        }
      }

      # What mounting does for a live connection from this Mac.
      SettingsLive.load(socket)
    end

    defp html(socket),
      do:
        socket.assigns
        |> SettingsLive.render()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

    test "disconnecting one machine leaves the others connected" do
      dir = tmp_dir()
      hub(dir)
      {laptop, _} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")
      {desk, _} = Fixtures.connect_machine(Path.join(dir, "b"), "desk")

      socket = page()
      assert html(socket) =~ "laptop"
      assert html(socket) =~ "desk"

      # The first tap only asks to be sure.
      {:noreply, socket} = SettingsLive.handle_event("disconnect", %{"key" => laptop}, socket)
      assert length(MachineKeys.list()) == 2
      assert html(socket) =~ "Tap again to disconnect"

      {:noreply, socket} = SettingsLive.handle_event("disconnect", %{"key" => laptop}, socket)
      assert [%{key_id: ^desk, machine: "desk"}] = MachineKeys.list()
      assert socket.assigns.notice =~ "laptop is disconnected"
    end

    test "the connect command passes the key to the script, and machines on the old key are listed" do
      dir = tmp_dir()
      hub(dir)
      MachineKeys.note_old_try("old-mac")
      page = html(page())

      assert page =~ "Machines to connect again"
      assert page =~ "old-mac"

      assert SettingsLive.install_command("http://hub:4747", "k") ==
               ~s(curl -fsS http://hub:4747/ingest/install.sh | WALLBOARD_KEY="k" sh)
    end
  end
end
