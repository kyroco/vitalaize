defmodule Wallboard.LinkTest do
  # One hub at a time: it has one name and one database.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wallboard.Collector.{Filter, Proto}
  alias Wallboard.Link
  alias Wallboard.Link.{Authority, Client, Hub}
  alias Wallboard.Store

  @moduletag :capture_log

  setup do
    dir = Wallboard.Fixtures.tmp_path("wallboard-link")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, link: Path.join(dir, "link")}
  end

  # ---------------------------------------------------------------------------
  # Helpers

  defp start_hub(dir, opts \\ []) do
    start_supervised!({Store, path: Path.join(dir, "wallboard.db")})
    start_supervised!({Hub, Keyword.merge([dir: Path.join(dir, "link"), port: 0], opts)})
    Hub.port()
  end

  defp stop_hub do
    stop_supervised!(Hub)
    stop_supervised!(Store)
  end

  # The hub and its database, gone at once: nothing gets to say goodbye.
  defp kill_hub do
    for name <- [Hub, Store] do
      pid = Process.whereis(name)
      # The hub's name belongs to its list of machines; its supervisor is
      # what holds the port too.
      pid = if name == Hub, do: pid |> Process.info(:links) |> elem(1) |> hd(), else: pid
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}, 5_000
      stop_supervised(name)
    end
  end

  # Reads the database file itself, for when the hub is down.
  defp saved_on_disk(dir, machine) do
    {:ok, conn} = Exqlite.Sqlite3.open(Path.join(dir, "wallboard.db"), mode: :readonly)

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, "SELECT position FROM collector_events WHERE machine = ?1")

    :ok = Exqlite.Sqlite3.bind(stmt, [machine])
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    Exqlite.Sqlite3.close(conn)
    rows
  end

  defp quietly(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Quick waits, so a test that loses the hub does not sit for a second.
  @fast [base_ms: 40, cap_ms: 400, back_soon_ms: 600]

  defp start_client(dir, port, tls, opts \\ []) do
    name = opts[:name] || :"client-#{System.unique_integer([:positive])}"

    hello =
      Filter.hello(%{
        machine: opts[:label] || "studio",
        os: "macOS 15.6",
        version: "0.3.0",
        folders: ["/Users/r/.claude"]
      })

    start_supervised!(
      {Client,
       name: name,
       host: "127.0.0.1",
       port: port,
       tls: tls,
       hello: hello,
       buffer: opts[:buffer] || Path.join(dir, "#{name}.buffer"),
       listener: self(),
       backoff: opts[:backoff] || @fast,
       pace: opts[:pace] || %{},
       max_bytes: opts[:max_bytes]},
      id: name
    )

    name
  end

  defp event(n, session \\ "s1") do
    %Proto.Event{
      session_id: session,
      file: session <> ".jsonl",
      position: n * 100,
      at: 1_790_000_000 + n,
      items: [%Proto.Item{body: {:counts, %Proto.Counts{prompts: n}}}]
    }
  end

  defp status(session, state, opts), do: Filter.status(%{session_id: session}, state, opts)

  defp saved(machine) do
    for row <- Store.collector_events(machine), do: Proto.Event.decode(row.event)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp wait_until(fun, left \\ 100) do
    cond do
      fun.() -> :ok
      left == 0 -> flunk("waited too long")
      true -> Process.sleep(50) && wait_until(fun, left - 1)
    end
  end

  # ---------------------------------------------------------------------------

  describe "a hub and a collector over real TLS" do
    test "events go up, answers come down, and rows are saved under the certificate's machine",
         %{dir: dir, link: link} do
      port = start_hub(dir)
      Phoenix.PubSub.subscribe(Wallboard.PubSub, "link")
      {:ok, papa} = Authority.issue(link, "papa")

      # The hello claims another name. Only the certificate counts.
      client = start_client(dir, port, papa, label: "liar")

      assert_receive {:wallboard_link, :up}, 5_000
      # Hub to collector: where to resume, which is nowhere yet.
      assert_receive {:wallboard_link, {:resume, points}}, 5_000
      assert points == %{}
      assert_receive {:link, :up, "papa"}
      assert_receive {:link, :hello, "papa", %{label: "liar", folders: ["/Users/r/.claude"]}}

      for n <- 1..3, do: :ok = Client.push(client, event(n))
      at = ~U[2026-09-30 12:00:00Z]

      :ok =
        Client.push(
          client,
          status("s1", :needs, why: :question, question: "Deploy to staging?", at: at)
        )

      # Hub to collector again: everything up to the fourth is saved.
      assert_receive {:wallboard_link, {:stored, 4}}, 5_000
      assert_receive {:link, :events, "papa", [_ | _]}

      events = saved("papa")
      assert Enum.map(events, & &1.position) == [100, 200, 300, 0]
      assert saved("liar") == [] and saved("studio") == []

      assert %Proto.Item{body: {:status, %Proto.Status{state: :WAITING, question: question}}} =
               events |> List.last() |> Map.fetch!(:items) |> hd()

      assert question == "Deploy to staging?"

      assert [%{machine: "papa", label: "liar", os: "macOS 15.6", folders: ["/Users/r/.claude"]}] =
               Store.collector_machines()

      assert %{"papa" => %{hello: %{label: "liar"}}} = Hub.connected()
      # Confirmed events leave the collector's buffer.
      assert %{phase: :live, waiting: 0} = Client.status(client)

      # The next stream of the same machine is told where the hub got to.
      stop_supervised!(client)
      flush()
      other = start_client(dir, port, papa, name: :second)
      assert_receive {:wallboard_link, {:resume, %{{"s1", "s1.jsonl"} => 300}}}, 5_000
      :ok = Client.push(other, event(4))
      assert_receive {:wallboard_link, {:stored, 1}}, 5_000
      assert length(saved("papa")) == 5
    end

    test "the port speaks TLS only, and HTTP/2 only", %{dir: dir, link: link} do
      log = capture_log(fn -> send(self(), {:port, start_hub(dir)}) end)
      assert_received {:port, port}
      # Nothing the port was started with was turned down.
      refute log =~ "unknown or invalid"

      # An approved machine that offers only HTTP/1.1 gets no connection.
      {:ok, papa} = Authority.issue(link, "papa")
      old = [alpn_advertised_protocols: ["http/1.1"], active: false]

      assert {:error, {:tls_alert, {:no_application_protocol, _}}} =
               :ssl.connect(~c"127.0.0.1", port, Authority.collector_tls(papa) ++ old, 3_000)

      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      # The opening bytes of a plain HTTP/2 connection.
      :ok = :gen_tcp.send(socket, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")

      case :gen_tcp.recv(socket, 0, 3_000) do
        {:error, :closed} -> :ok
        # A TLS alert record (type 21), never an HTTP answer.
        {:ok, <<21, _::binary>>} -> :ok
      end

      assert Hub.connected() == %{}
    end
  end

  describe "who is refused" do
    test "no certificate, another authority's certificate, and a revoked one",
         %{dir: dir, link: link} do
      port = start_hub(dir)
      {:ok, papa} = Authority.issue(link, "papa")

      # No certificate at all: the handshake ends with "certificate required".
      tls = papa |> Authority.collector_tls() |> Keyword.drop([:cert, :key])

      {:ok, socket} =
        :ssl.connect(~c"127.0.0.1", port, tls ++ [active: false, mode: :binary], 3_000)

      assert {:error, {:tls_alert, {:certificate_required, _}}} = :ssl.recv(socket, 0, 3_000)

      # A certificate another authority signed, for the same machine name.
      elsewhere = Path.join(dir, "elsewhere")
      :ok = Authority.ensure!(elsewhere)
      {:ok, forged} = Authority.issue(elsewhere, "papa")
      start_client(dir, port, %{forged | ca_pem: papa.ca_pem}, name: :forged)
      assert_receive {:wallboard_link, {:down, _}}, 5_000
      refute_received {:wallboard_link, {:resume, _}}
      stop_supervised!(:forged)

      # A revoked one.
      {:ok, mama} = Authority.issue(link, "mama")
      {:ok, [_serial]} = Hub.revoke("mama")
      start_client(dir, port, mama, name: :revoked)
      assert_receive {:wallboard_link, {:down, _}}, 5_000
      refute_received {:wallboard_link, {:resume, _}}
      stop_supervised!(:revoked)

      assert Hub.connected() == %{}
      assert saved("papa") == [] and saved("mama") == []

      # The same hub still takes a good one.
      start_client(dir, port, papa, name: :good)
      assert_receive {:wallboard_link, {:resume, _}}, 5_000
    end

    test "a collector refuses a hub whose authority it does not know", %{dir: dir, link: link} do
      port = start_hub(dir)
      {:ok, papa} = Authority.issue(link, "papa")

      elsewhere = Path.join(dir, "elsewhere")
      :ok = Authority.ensure!(elsewhere)

      # The collector's own certificate is good; the authority it trusts is
      # not this hub's.
      client = start_client(dir, port, %{papa | ca_pem: Authority.ca_pem(elsewhere)})
      :ok = Client.push(client, event(1))

      assert_receive {:wallboard_link, {:down, _}}, 5_000
      refute_received {:wallboard_link, :up}
      assert Hub.connected() == %{}
      assert saved("papa") == []
      # Nothing was sent, and nothing was thrown away.
      assert %{waiting: 1} = Client.status(client)
    end

    test "a collector refuses a machine's certificate posing as the hub's", %{link: link} do
      :ok = Authority.ensure!(link)
      {:ok, papa} = Authority.issue(link, "papa")
      {:ok, mama} = Authority.issue(link, "mama")

      # A fake hub: a TLS server that holds a real machine certificate from
      # the same authority.
      [{:Certificate, cert, _}] = :public_key.pem_decode(mama.cert_pem)
      [{:ECPrivateKey, key, _}] = :public_key.pem_decode(mama.key_pem)

      {:ok, listen} =
        :ssl.listen(0,
          cert: cert,
          key: {:ECPrivateKey, key},
          versions: [:"tlsv1.3"],
          active: false
        )

      {:ok, {_, port}} = :ssl.sockname(listen)

      spawn_link(fn ->
        {:ok, socket} = :ssl.transport_accept(listen, 5_000)
        :ssl.handshake(socket, 5_000)
      end)

      opts = Authority.collector_tls(papa) ++ [active: false]
      assert {:error, {:tls_alert, {alert, _}}} = :ssl.connect(~c"127.0.0.1", port, opts, 5_000)
      assert alert in [:handshake_failure, :bad_certificate, :unsupported_certificate]
    end

    test "a machine revoked while connected is told so and stops for good", %{
      dir: dir,
      link: link
    } do
      port = start_hub(dir)
      Phoenix.PubSub.subscribe(Wallboard.PubSub, "link")
      {:ok, papa} = Authority.issue(link, "papa")
      {:ok, mama} = Authority.issue(link, "mama")

      client = start_client(dir, port, papa)
      assert_receive {:wallboard_link, {:resume, _}}, 5_000
      start_client(dir, port, mama, name: :mama)
      assert_receive {:wallboard_link, {:resume, _}}, 5_000

      assert {:ok, [_]} = Hub.revoke("papa")
      assert_receive {:wallboard_link, :removed}, 5_000
      assert_receive {:link, :down, "papa"}, 5_000
      assert %{phase: :removed} = Client.status(client)

      # It does not try again, and the other machine is untouched.
      refute_receive {:wallboard_link, {:down, _}}, 300
      assert Map.keys(Hub.connected()) == ["mama"]
      :ok = Client.push(:mama, event(1, "m1"))
      assert_receive {:wallboard_link, {:stored, 1}}, 5_000
    end
  end

  describe "what the hub keeps" do
    test "a session's end and a status of the same second are both kept, and a repeat changes nothing",
         %{dir: dir, link: link} do
      port = start_hub(dir)
      {:ok, papa} = Authority.issue(link, "papa")
      client = start_client(dir, port, papa)
      assert_receive {:wallboard_link, {:resume, _}}, 5_000

      at = ~U[2026-09-30 12:00:00Z]
      waiting = status("s1", :needs, why: :question, at: at)
      ended = Filter.ended(%{session_id: "s1"}, at)
      idle = status("s1", :idle, at: at)
      # With no time at all, the same.
      timeless = [Filter.ended(%{session_id: "s2"}, nil), status("s2", :working, [])]

      :ok = Client.push(client, [event(1), waiting, ended, idle] ++ timeless ++ [event(2)])
      assert_receive {:wallboard_link, {:stored, 7}}, 5_000

      rows = Store.collector_events("papa")
      assert Enum.map(rows, & &1.kind) == ["file", "status", "end", "end", "status", "file"]
      # Of two statuses in one second, the later is the one kept.
      assert Proto.Event.decode(Enum.at(rows, 1).event) == idle
      assert Proto.Event.decode(Enum.at(rows, 2).event) == ended

      # The first event again, as after a cut stream: same place, same time
      # of arrival, no new row.
      :ok =
        Store.put_collector_events(
          "papa",
          [
            %{
              session_id: "s1",
              file: "s1.jsonl",
              position: 100,
              at: 1_790_000_001,
              kind: "file",
              event: Proto.Event.encode(event(1))
            }
          ],
          System.os_time(:second) + 500
        )

      assert Store.collector_events("papa") == rows
    end

    test "a certificate replaced from outside the hub closes its open stream",
         %{dir: dir, link: link} do
      port = start_hub(dir, limits: %{recheck_ms: 50})
      {:ok, papa} = Authority.issue(link, "papa")
      client = start_client(dir, port, papa, pace: %{keepalive_ms: 100})
      assert_receive {:wallboard_link, {:resume, _}}, 5_000

      # What `mix wallboard.link.issue papa --replace` does, from another
      # program: the hub's own process is told nothing.
      {:ok, _newer} = Authority.issue(link, "papa", replace: true)

      assert_receive {:wallboard_link, :removed}, 5_000
      wait_until(fn -> Hub.connected() == %{} end)
      assert %{phase: :removed} = Client.status(client)
    end

    test "a buffer that overflowed while the hub was away still delivers every line, in order",
         %{dir: dir, link: link} do
      port = free_port()
      {:ok, papa} = Authority.issue_offline(link, "papa")

      # No hub yet. The buffer holds about a third of what is pushed.
      client = start_client(dir, port, papa, max_bytes: 6_000)
      lines = Enum.map(1..300, &event/1)
      :ok = Client.push(client, lines)
      assert Client.status(client).waiting < 300

      start_hub(dir, port: port)

      # What a reader of the session file does: on every Resume, go back to
      # the hub's position and push the file's lines from there.
      reader = fn reader, resumes ->
        receive do
          {:wallboard_link, {:resume, points}} ->
            from = div(Map.get(points, {"s1", "s1.jsonl"}, 0), 100)
            :ok = Client.push(client, Enum.drop(lines, from))
            reader.(reader, resumes + 1)

          _ ->
            reader.(reader, resumes)
        after
          200 ->
            cond do
              length(saved("papa")) == 300 -> resumes
              resumes > 20 -> flunk("the hub never caught up")
              true -> reader.(reader, resumes)
            end
        end
      end

      # More than one Resume: the buffer could not carry it all at once.
      assert reader.(reader, 0) > 1
      wait_until(fn -> Client.status(client).waiting == 0 end)
      assert Enum.map(saved("papa"), & &1.position) == Enum.map(1..300, &(&1 * 100))
    end
  end

  describe "losing the hub" do
    test "a hub killed mid-stream comes back, and nothing is lost or doubled",
         %{dir: dir, link: link} do
      port = free_port()
      start_hub(dir, port: port)
      Phoenix.PubSub.subscribe(Wallboard.PubSub, "link")
      {:ok, papa} = Authority.issue(link, "papa")

      # A slow pace, so the hub dies with events still on their way.
      client = start_client(dir, port, papa, pace: %{per_tick: 2, tick_ms: 50})
      assert_receive {:wallboard_link, {:resume, %{}}}, 5_000

      :ok = Client.push(client, Enum.map(1..60, &event/1))
      assert_receive {:wallboard_link, {:stored, seq}} when seq >= 10, 5_000

      # Killed, not stopped: no goodbye, nothing flushed.
      assert Client.status(client).waiting > 0
      kill_hub()
      before = length(saved_on_disk(dir, "papa"))
      assert before >= 10 and before < 60

      assert_receive {:wallboard_link, {:down, _}}, 5_000

      # The collector keeps taking events while the hub is away.
      :ok = Client.push(client, Enum.map(61..80, &event/1))
      assert %{phase: phase, waiting: waiting} = Client.status(client)
      assert phase in [:waiting, :connecting] and waiting >= 20

      start_hub(dir, port: port)

      # It returns by itself, and the hub says where it got to.
      assert_receive {:wallboard_link, {:resume, points}}, 10_000
      assert points == %{{"s1", "s1.jsonl"} => before * 100}
      wait_until(fn -> Client.status(client).waiting == 0 end)

      # Every event is saved once, in order, none missing.
      assert Enum.map(saved("papa"), & &1.position) == Enum.map(1..80, &(&1 * 100))

      # And none crossed twice: over both lives of the hub, each position was
      # saved exactly once.
      crossed = for {:link, :events, "papa", rows} <- flush(), row <- rows, do: row.position
      assert Enum.sort(crossed) == Enum.map(1..80, &(&1 * 100))
    end

    test "retry waits grow, stay under the cap, and \"back soon\" delays the first retry",
         %{dir: dir, link: link} do
      port = free_port()
      start_hub(dir, port: port)
      {:ok, papa} = Authority.issue(link, "papa")
      backoff = [base_ms: 40, cap_ms: 500, back_soon_ms: 300]
      client = start_client(dir, port, papa, backoff: backoff)
      assert_receive {:wallboard_link, {:resume, _}}, 5_000

      # A planned restart: the hub says so first.
      assert Hub.back_soon() == 1
      assert_receive {:wallboard_link, :back_soon}, 5_000
      stop_hub()

      # The first wait is the long one: 300 ms and up, where a hub that just
      # vanished gets 20 to 40.
      assert_receive {:wallboard_link, {:down, first}}, 5_000
      assert first >= 300 and first <= 500

      # After it the waits double (each between half its ceiling and the
      # whole of it) until the cap holds them.
      for ceiling <- [80, 160, 320, 500, 500, 500] do
        assert_receive {:wallboard_link, {:down, wait}}, 5_000
        assert wait >= div(ceiling, 2) and wait <= ceiling
      end

      assert Client.status(client).phase in [:waiting, :connecting]
    end

    test "a hub that vanishes without a word gets the short first wait", %{dir: dir, link: link} do
      port = free_port()
      start_hub(dir, port: port)
      {:ok, papa} = Authority.issue(link, "papa")
      start_client(dir, port, papa, backoff: [base_ms: 40, cap_ms: 500, back_soon_ms: 300])
      assert_receive {:wallboard_link, {:resume, _}}, 5_000

      kill_hub()
      assert_receive {:wallboard_link, {:down, first}}, 5_000
      assert first >= 20 and first <= 40
    end
  end

  describe "limits" do
    test "a message over the size limit closes the stream and saves nothing",
         %{dir: dir, link: link} do
      port = start_hub(dir)
      {:ok, papa} = Authority.issue(link, "papa")

      title = String.duplicate("x", Link.limits().max_message_bytes)
      items = [%Proto.Item{body: {:summary, %Proto.Summary{title: title}}}]
      big = %Proto.Event{session_id: "s1", file: "s1.jsonl", position: 1, items: items}

      log =
        capture_log(fn ->
          {channel, stream} = raw_stream(port, papa)
          wait_until(fn -> Hub.connected() != %{} end)
          # The hub hangs up part way through, which the sender may notice.
          quietly(fn ->
            GRPC.Stub.send_request(stream, %Proto.FromCollector{seq: 1, body: {:event, big}})
          end)

          wait_until(fn -> Hub.connected() == %{} end)
          quietly(fn -> GRPC.Stub.disconnect(channel) end)
        end)

      assert log =~ "is over the limit of #{Link.limits().max_message_bytes}"
      assert saved("papa") == []
    end

    test "a collector that sends too much too fast is cut off", %{dir: dir, link: link} do
      port = start_hub(dir, limits: %{message_burst: 20, messages_per_second: 5})
      {:ok, papa} = Authority.issue(link, "papa")

      log =
        capture_log(fn ->
          {channel, stream} = raw_stream(port, papa)
          wait_until(fn -> Hub.connected() != %{} end)

          quietly(fn ->
            for n <- 1..200 do
              message = %Proto.FromCollector{seq: n, body: {:event, event(n)}}
              GRPC.Stub.send_request(stream, message)
            end
          end)

          wait_until(fn -> Hub.connected() == %{} end)
          quietly(fn -> GRPC.Stub.disconnect(channel) end)
        end)

      assert log =~ "papa sent too much too fast"
      # What arrived before the cut may be saved; the flood is not.
      assert length(saved("papa")) <= 20
      before = length(saved("papa"))

      # Connecting again buys nothing: the limit is the machine's, not the
      # stream's. A second flood right away is cut off at once.
      capture_log(fn ->
        {channel, stream} = raw_stream(port, papa)

        quietly(fn ->
          for n <- 201..400 do
            message = %Proto.FromCollector{seq: n, body: {:event, event(n)}}
            GRPC.Stub.send_request(stream, message)
          end
        end)

        wait_until(fn -> Hub.connected() == %{} end)
        quietly(fn -> GRPC.Stub.disconnect(channel) end)
      end)

      # At most what one second refills (5), never another burst of 20.
      assert length(saved("papa")) - before <= 6
    end

    test "the first message must be a hello", %{dir: dir, link: link} do
      port = start_hub(dir)
      {:ok, papa} = Authority.issue(link, "papa")

      capture_log(fn ->
        {channel, stream} = raw_stream(port, papa, hello: false)
        GRPC.Stub.send_request(stream, %Proto.FromCollector{seq: 1, body: {:event, event(1)}})
        assert {:error, %GRPC.RPCError{status: 9}} = last_reply(stream)
        quietly(fn -> GRPC.Stub.disconnect(channel) end)
      end)

      assert saved("papa") == []
    end

    test "the collector's own pace stays far under the hub's limits" do
      pace = Client.pace()
      limits = Link.limits()
      per_second = pace.per_tick * div(1000, pace.tick_ms)
      assert per_second * 2 <= limits.messages_per_second
      assert pace.bytes_per_tick * div(1000, pace.tick_ms) * 2 <= limits.bytes_per_second
      assert pace.window <= limits.message_burst
      assert pace.keepalive_ms * 3 <= limits.idle_ms
    end
  end

  test "the hub listens only when the link is turned on, on a hub with an archive" do
    on = %{archive: %{enabled: true}, link: %{enabled: true}}
    assert Link.hub?(on)
    refute Link.hub?(%{on | link: %{enabled: false}})
    refute Link.hub?(%{on | archive: %{enabled: false}})
    refute Link.hub?(Wallboard.Settings.defaults())
  end

  # ---------------------------------------------------------------------------

  # A stream opened by hand, to send what the client never would.
  defp raw_stream(port, tls, opts \\ []) do
    {:ok, channel} =
      GRPC.Stub.connect("ipv4:127.0.0.1:#{port}",
        cred: GRPC.Credential.new(ssl: Authority.collector_tls(tls)),
        adapter: GRPC.Client.Adapters.Mint
      )

    stream = Proto.Collector.Stub.stream(channel)

    if opts[:hello] != false do
      hello = Filter.hello(%{machine: "raw", os: "test", version: "0", folders: []})
      GRPC.Stub.send_request(stream, %Proto.FromCollector{body: {:hello, hello}})
    end

    {channel, stream}
  end

  defp last_reply(stream) do
    case GRPC.Stub.recv(stream) do
      {:ok, replies} -> replies |> Enum.to_list() |> List.last()
      {:error, _} = error -> error
    end
  end

  defp flush(acc \\ []) do
    receive do
      message -> flush([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
