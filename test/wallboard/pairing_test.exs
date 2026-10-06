defmodule Wallboard.PairingTest.Middle do
  @moduledoc false
  # Someone on the network between a collector and the hub: every call goes
  # through `change`, which may rewrite what is asked and what is answered.
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    step = conn.request_path |> String.split("/") |> List.last()
    asked = opts[:change].(step, :ask, Jason.decode!(body))

    {:ok, {{_, status, _}, _, reply}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{opts[:port]}/pair/#{step}", [], ~c"application/json",
         Jason.encode!(asked)},
        [timeout: 5_000],
        body_format: :binary
      )

    reply =
      case Jason.decode(reply) do
        {:ok, %{} = map} when status == 200 -> Jason.encode!(opts[:change].(step, :answer, map))
        _ -> reply
      end

    conn |> put_resp_content_type("application/json") |> send_resp(status, reply)
  end
end

defmodule Wallboard.PairingTest do
  # One hub at a time: it has one name and one database.
  use ExUnit.Case, async: false

  alias Wallboard.Collector.{Filter, Proto, Sender}
  alias Wallboard.Link.{Authority, Client, Hub, Machines}
  alias Wallboard.{Mailbox, Pairing, Settings, Store}
  alias Wallboard.Pairing.Door
  alias WallboardWeb.{Auth, BoardLive, MailboxPanel, SettingsLive}

  @moduletag :capture_log

  setup do
    dir = Wallboard.Fixtures.tmp_path("wallboard-pairing")
    File.mkdir_p!(dir)

    # The settings on this machine have nothing to do with these tests.
    old = :persistent_term.get({Settings, :settings}, nil)
    Settings.put(%{})

    on_exit(fn ->
      File.rm_rf!(dir)

      if old,
        do: :persistent_term.put({Settings, :settings}, old),
        else: :persistent_term.erase({Settings, :settings})
    end)

    %{dir: dir, link: Path.join(dir, "link")}
  end

  # ---------------------------------------------------------------------------
  # Helpers

  # A hub: its database, its link port, its pairing door, and the board's
  # own router on a port of its own. Returns that last port.
  defp start_hub(dir, limits \\ %{}) do
    start_supervised!({Store, path: Path.join(dir, "wallboard.db")})
    start_supervised!({Hub, dir: Path.join(dir, "link"), port: 0})

    start_supervised!({Door, dir: Path.join(dir, "link"), link_port: Hub.port(), limits: limits})

    web(WallboardWeb.Router)
  end

  defp web(plug) do
    pid =
      start_supervised!(
        {Bandit, plug: plug, ip: :loopback, port: 0, startup_log: false},
        id: {:web, System.unique_integer([:positive])}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    port
  end

  # A throwaway collector asks to pair. The code it shows arrives here as
  # `{:code, name, info}`; the task ends with what `Pairing.pair/1` returned.
  defp ask(port, dir, name) do
    me = self()

    Task.async(fn ->
      Pairing.pair(
        hub: "127.0.0.1:#{port}",
        dir: Path.join(dir, name),
        name: name,
        poll_ms: 30,
        on_code: &send(me, {:code, name, &1})
      )
    end)
  end

  defp pair!(port, dir, name) do
    task = ask(port, dir, name)
    assert_receive {:code, ^name, %{code: code}}, 5_000
    assert [%{id: id, code: ^code}] = Door.pending()
    :ok = Door.approve(id)
    assert {:ok, %{machine: ^name}} = Task.await(task, 5_000)
    {:ok, paired} = Pairing.load(Path.join(dir, name))
    paired
  end

  # Messages from a client arrive as `{tag, what}`, so two clients in one
  # test can be told apart.
  defp start_client(dir, paired, tag, opts \\ []) do
    me = self()

    relay =
      spawn_link(fn ->
        Stream.repeatedly(fn ->
          receive do
            {:wallboard_link, what} -> send(me, {tag, what})
          end
        end)
        |> Stream.run()
      end)

    hello =
      Filter.hello(%{
        machine: to_string(tag),
        os: "macOS 15.6",
        version: "0.3.0",
        folders: ["/Users/r/.claude"]
      })

    start_supervised!(
      {Client,
       [
         name: tag,
         host: paired.host,
         port: paired.port,
         tls: paired.tls,
         hello: hello,
         buffer: Path.join(dir, "#{tag}.buffer"),
         listener: relay,
         backoff: [base_ms: 40, cap_ms: 400, back_soon_ms: 600]
       ] ++ opts},
      id: tag
    )

    tag
  end

  defp event(n) do
    %Proto.Event{
      session_id: "s1",
      file: "s1.jsonl",
      position: n * 100,
      at: 1_790_000_000 + n,
      items: [%Proto.Item{body: {:counts, %Proto.Counts{prompts: n}}}]
    }
  end

  defp socket(assigns),
    do: %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}

  defp board_socket(who) do
    socket(%{
      who: who,
      mailbox: [],
      mailbox_note: nil,
      mailbox_open?: true,
      session_tab: :live,
      selected: nil,
      open_repo: nil,
      back_ref: nil
    })
  end

  defp html(rendered), do: rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

  defp panel(may_decide? \\ true) do
    html(
      MailboxPanel.panel(%{
        items: Mailbox.items(),
        note: nil,
        may_decide?: may_decide?,
        cannot: "Decide on the hub's own machine.",
        __changed__: nil
      })
    )
  end

  # ---------------------------------------------------------------------------

  describe "the code" do
    test "is six digits, the same for the same things, and different when anything differs" do
      args = ["key", "air", "authority", "collector number", "hub number"]
      code = apply(Pairing, :code, args)
      assert code =~ ~r/\A\d{3}-\d{3}\z/
      assert code == apply(Pairing, :code, args)

      for i <- 0..4 do
        refute code == apply(Pairing, :code, List.update_at(args, i, &(&1 <> "x")))
      end

      # Parts cannot run into each other: "ab" + "c" is not "a" + "bc".
      refute Pairing.code("ab", "c", "ca", "n", "h") == Pairing.code("a", "bc", "ca", "n", "h")
    end
  end

  describe "pairing a throwaway collector with a hub" do
    test "the same code on both sides, and Approve gives a working certificate", %{dir: dir} do
      port = start_hub(dir)
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Mailbox.topic())
      task = ask(port, dir, "air")

      assert_receive {:code, "air", %{code: code, expires_in: 600}}, 5_000
      assert_receive {:mailbox, :changed}, 5_000

      # The hub shows the machine's name and the very same code.
      assert [%{id: id, name: "air", code: ^code, replaces?: false}] = Door.pending()
      assert [%{id: "machine:" <> ^id}] = Mailbox.items()
      assert Authority.machines(Path.join(dir, "link")) == []

      assert :ok = Mailbox.act("machine:" <> id, "approve")
      out = Path.join(dir, "air")
      assert {:ok, %{machine: "air", code: ^code, dir: ^out}} = Task.await(task, 5_000)

      # What the collector saved is its own, and only its user can read it.
      assert {:ok, paired} = Pairing.load(out)
      assert paired.machine == "air" and paired.port == Hub.port()
      assert %{mode: mode} = File.stat!(out)
      assert Bitwise.band(mode, 0o777) == 0o700

      for file <- ~w(key.pem cert.pem ca.pem hub.json) do
        assert Bitwise.band(File.stat!(Path.join(out, file)).mode, 0o777) == 0o600
      end

      assert paired.tls.ca_pem == Authority.ca_pem(Path.join(dir, "link"))

      # The private key never left the collector: the hub's folder holds
      # its own two keys and no other.
      link_files = File.ls!(Path.join(dir, "link"))

      assert Enum.filter(link_files, &String.ends_with?(&1, ".key")) |> Enum.sort() ==
               ["ca.key", "hub.key"]

      # And the certificate works: the link comes up and events are saved
      # under the machine's name.
      client = start_client(dir, paired, :air)
      assert_receive {:air, :up}, 5_000
      assert_receive {:air, {:resume, _}}, 5_000
      :ok = Client.push(client, event(1))
      assert_receive {:air, {:stored, _}}, 5_000
      assert [%{position: 100}] = Store.collector_events("air")
    end

    test "Refuse gives no certificate", %{dir: dir} do
      port = start_hub(dir)
      task = ask(port, dir, "air")
      assert_receive {:code, "air", _}, 5_000
      assert [%{id: id}] = Door.pending()

      assert :ok = Mailbox.act("machine:" <> id, "refuse")
      assert {:error, :refused} = Task.await(task, 5_000)
      assert Pairing.load(Path.join(dir, "air")) == :error
      assert File.ls!(Path.join(dir, "air")) == []
      assert Authority.machines(Path.join(dir, "link")) == []
      # It cannot be approved after all.
      assert {:error, :gone} = Door.approve(id)
    end

    test "a request nobody answers runs out, and gives no certificate", %{dir: dir} do
      port = start_hub(dir)
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Mailbox.topic())
      task = ask(port, dir, "air")
      assert_receive {:code, "air", _}, 5_000
      assert_receive {:mailbox, :changed}, 5_000
      assert [%{id: id}] = Door.pending()

      # Its time runs out by moving its start back, not by waiting.
      :sys.replace_state(Door, fn s ->
        update_in(s.requests[id], &%{&1 | made: &1.made - Pairing.limits().expire_ms})
      end)

      assert {:error, :expired} = Task.await(task, 5_000)
      # The mailbox hears that the item went away without anyone asking.
      assert_receive {:mailbox, :changed}, 5_000
      assert Door.pending() == []
      assert {:error, :gone} = Door.approve(id)
      assert Pairing.load(Path.join(dir, "air")) == :error
      assert Authority.machines(Path.join(dir, "link")) == []
    end

    test "Approve at the last moment still reaches the collector", %{dir: dir} do
      port = start_hub(dir, %{expire_ms: 10_000})
      me = self()

      task =
        Task.async(fn ->
          Pairing.pair(
            hub: "127.0.0.1:#{port}",
            dir: Path.join(dir, "air"),
            name: "air",
            poll_ms: 400,
            on_code: &send(me, {:code, "air", &1})
          )
        end)

      assert_receive {:code, "air", _}, 5_000
      [%{id: id}] = Door.pending()

      # Time passes by moving the request's start back, not by sleeping,
      # so a slow machine cannot run it out early.
      older = fn ms ->
        :sys.replace_state(Door, fn s ->
          update_in(s.requests[id], &%{&1 | made: &1.made - ms})
        end)
      end

      # Approve comes with one second of the request's time left, and the
      # collector asks again after that time would have run out.
      older.(9_000)
      assert :ok = Door.approve(id)
      older.(1_500)
      assert {:ok, %{machine: "air"}} = Task.await(task, 5_000)
      assert {:ok, _} = Pairing.load(Path.join(dir, "air"))
    end

    test "a save that fails at the very end is an answer, not a crash, and leaves no key behind",
         %{dir: dir} do
      port = start_hub(dir)
      # Something sits where the key should go.
      File.mkdir_p!(Path.join([dir, "air", "key.pem"]))
      task = ask(port, dir, "air")
      assert_receive {:code, "air", _}, 5_000
      [%{id: id}] = Door.pending()
      :ok = Door.approve(id)
      assert {:error, {:folder, _}} = Task.await(task, 5_000)
      assert Path.wildcard(Path.join([dir, "air", ".*"]), match_dot: true) == []
      assert Pairing.load(Path.join(dir, "air")) == :error
    end

    test "a collector that cannot save says so before it asks the hub anything", %{dir: dir} do
      port = start_hub(dir)
      File.write!(Path.join(dir, "a-file"), "")

      assert {:error, {:folder, reason}} =
               Pairing.pair(
                 hub: "127.0.0.1:#{port}",
                 dir: Path.join(dir, "a-file/air"),
                 name: "air"
               )

      assert Pairing.why({:folder, reason}) =~ "Could not save the certificate in"
      assert Door.pending() == []
      # The door was never asked, so the address is free to try again.
      assert {:ok, _} = Door.start({127, 0, 0, 1}, elem(start_params("air"), 0))
    end

    test "approved, but the hub cannot make the certificate: the collector is told so at once",
         %{dir: dir} do
      port = start_hub(dir)
      link = Path.join(dir, "link")
      task = ask(port, dir, "air")
      assert_receive {:code, "air", _}, 5_000
      [%{id: id}] = Door.pending()

      # The hub's list of machines is broken when the machine comes for
      # its answer.
      file = Path.join(link, "machines.json")
      good = File.read!(file)
      File.write!(file, "{ not json")
      :ok = Door.approve(id)

      # Not "nobody approved", and not ten minutes of waiting.
      assert {:error, :hub_failed} = Task.await(task, 5_000)
      assert Pairing.why(:hub_failed) =~ "could not make the certificate"
      assert Pairing.load(Path.join(dir, "air")) == :error

      # The request is over: mending the list does not bring it back, and
      # no certificate was made on the quiet.
      File.write!(file, good)
      assert {:ok, :failed} = Door.status({127, 0, 0, 1}, id)
      assert {:error, :gone} = Door.approve(id)
      assert Authority.machines(link) == []

      # The machine asks again and pairs.
      assert %{machine: "air"} = pair!(port, dir, "air")
    end

    test "a machine that pairs again replaces its older certificate", %{dir: dir} do
      port = start_hub(dir)
      first = pair!(port, dir, "air")

      task = ask(port, dir, "air")
      assert_receive {:code, "air", _}, 5_000
      assert [%{id: id, replaces?: true}] = Door.pending()
      assert panel() =~ "approving this one disconnects it"
      :ok = Door.approve(id)
      assert {:ok, _} = Task.await(task, 5_000)
      {:ok, second} = Pairing.load(Path.join(dir, "air"))

      assert {:error, :revoked} =
               Authority.machine(Path.join(dir, "link"), pem_der(first.tls.cert_pem))

      assert {:ok, "air"} =
               Authority.machine(Path.join(dir, "link"), pem_der(second.tls.cert_pem))
    end
  end

  defp pem_der(pem) do
    [{:Certificate, der, _}] = :public_key.pem_decode(pem)
    der
  end

  describe "a request tampered with on the way" do
    test "a swapped key under the collector's own fingerprint never reaches the mailbox",
         %{dir: dir} do
      port = start_hub(dir)
      theirs = Authority.new_key_pair().public_pem

      middle =
        web(
          {Wallboard.PairingTest.Middle,
           port: port,
           change: fn
             "start", :ask, body -> %{body | "key" => theirs}
             _, _, body -> body
           end}
        )

      assert {:error, {:hub, _}} = Task.await(ask(middle, dir, "air"), 5_000)
      refute_received {:code, _, _}
      assert Door.pending() == []
    end

    test "a swapped key with a fingerprint of its own shows a different code on each side, and its certificate is not kept",
         %{dir: dir} do
      port = start_hub(dir)
      theirs = Authority.new_key_pair().public_pem
      {:ok, their_bytes} = Authority.public_bytes(theirs)
      their_nonce = :crypto.strong_rand_bytes(32)

      middle =
        web(
          {Wallboard.PairingTest.Middle,
           port: port,
           change: fn
             "start", :ask, body ->
               commit = Pairing.commit(their_nonce, their_bytes, body["name"])
               %{body | "key" => theirs, "commit" => Base.encode16(commit, case: :lower)}

             "confirm", :ask, body ->
               %{body | "nonce" => Base.encode16(their_nonce, case: :lower)}

             _, _, body ->
               body
           end}
        )

      task = ask(middle, dir, "air")
      assert_receive {:code, "air", %{code: shown}}, 5_000
      assert [%{id: id, name: "air", code: on_hub}] = Door.pending()
      refute shown == on_hub

      # Even an owner who approved without looking gives the collector
      # nothing it keeps: the certificate is for somebody else's key.
      :ok = Door.approve(id)

      assert {:error, {:hub, "the certificate is not for this machine's key"}} =
               Task.await(task, 5_000)

      assert Pairing.load(Path.join(dir, "air")) == :error
    end

    test "a hub number changed on the way is noticed, and no code is shown", %{dir: dir} do
      port = start_hub(dir)

      middle =
        web(
          {Wallboard.PairingTest.Middle,
           port: port,
           change: fn
             "confirm", :answer, body ->
               %{body | "nonce" => Base.encode16(:crypto.strong_rand_bytes(32))}

             _, _, body ->
               body
           end}
        )

      assert {:error, {:hub, "the hub changed its number on the way"}} =
               Task.await(ask(middle, dir, "air"), 5_000)

      refute_received {:code, _, _}
    end

    test "a swapped hub authority shows a different code on each side", %{dir: dir} do
      port = start_hub(dir)
      other = Path.join(dir, "other-link")
      :ok = Authority.ensure!(other)

      middle =
        web(
          {Wallboard.PairingTest.Middle,
           port: port,
           change: fn
             "start", :answer, body -> %{body | "ca" => Authority.ca_pem(other)}
             _, _, body -> body
           end}
        )

      _task = ask(middle, dir, "air")
      assert_receive {:code, "air", %{code: shown}}, 5_000
      assert [%{code: on_hub}] = Door.pending()
      refute shown == on_hub
    end

    test "a hub cannot hand over a certificate for another name or from another authority",
         %{link: link} do
      :ok = Authority.ensure!(link)
      pair = Authority.new_key_pair()
      {:ok, good} = Authority.sign(link, "air", pair.public_pem)
      ca = Authority.ca_pem(link)
      assert Authority.issued_for?(good.cert_pem, ca, "air", pair.public_pem)
      refute Authority.issued_for?(good.cert_pem, ca, "box", pair.public_pem)
      refute Authority.issued_for?(good.cert_pem, ca, "air", Authority.new_key_pair().public_pem)

      other = link <> "-other"
      :ok = Authority.ensure!(other)
      refute Authority.issued_for?(good.cert_pem, Authority.ca_pem(other), "air", pair.public_pem)
      refute Authority.issued_for?("junk", ca, "air", pair.public_pem)
    end
  end

  describe "a machine removed while it was away" do
    test "is told so after a few failed tries, and its client stops for good", %{dir: dir} do
      port = start_hub(dir)
      paired = pair!(port, dir, "air")
      door = %{host: "127.0.0.1", port: port}

      # Pairing kept the board's own port, where the door is.
      hub = dir |> Path.join("air/hub.json") |> File.read!() |> Jason.decode!()
      assert hub["port"] == port
      assert {:ok, :approved} = Pairing.check(door, paired.tls)

      # Removed on the hub while the machine is off: its next connect is
      # refused in the handshake, which does not say why.
      {:ok, [_]} = Authority.revoke(Path.join(dir, "link"), "air")
      assert {:ok, :removed} = Pairing.check(door, paired.tls)

      start_client(dir, paired, :air, door: door)
      assert_receive {:air, :removed}, 10_000
      # What it said before it stopped: at least three failed tries.
      assert length(said(:air)) >= 3

      # It has stopped: a try that comes due now is not made.
      send(Process.whereis(:air), :connect)
      assert %{phase: :removed} = Client.status(:air)
      assert said(:air) == []
    end

    test "a client with no door, or a door that does not answer, keeps trying", %{dir: dir} do
      port = start_hub(dir)
      paired = pair!(port, dir, "air")
      {:ok, _} = Authority.revoke(Path.join(dir, "link"), "air")

      start_client(dir, paired, :air, door: %{host: "127.0.0.1", port: closed_port()})
      start_client(dir, paired, :bee)

      for tag <- [:air, :bee], _ <- 1..7, do: assert_receive({^tag, {:down, _}}, 5_000)
      refute_received {:air, :removed}
      refute_received {:bee, :removed}
      assert %{phase: phase} = Client.status(:air)
      assert phase in [:waiting, :connecting]
    end

    test "the door answers only the machine that holds the key, on a fresh challenge",
         %{dir: dir} do
      port = start_hub(dir)
      air = pair!(port, dir, "air")
      bee = pair!(port, dir, "bee")
      from = {127, 0, 0, 1}
      {:ok, air_der} = Authority.cert_bytes(air.tls.cert_pem)

      proof = fn key, challenge ->
        Authority.prove(key, Pairing.check_text(challenge, air_der))
      end

      {:ok, challenge} = Door.challenge(from)

      assert {:ok, %{answer: "approved", signature: signature, hub_pem: hub_pem}} =
               Door.check(from, challenge, air.tls.cert_pem, proof.(air.tls.key_pem, challenge))

      {:ok, serial} = Authority.serial(air_der)
      text = Pairing.answer_text(challenge, serial, "approved")
      assert Authority.hub_signed?(air.tls.ca_pem, hub_pem, text, signature)

      # Another machine's key over this machine's certificate.
      assert {:error, :bad_request} =
               Door.check(from, challenge, air.tls.cert_pem, proof.(bee.tls.key_pem, challenge))

      # A proof of nothing, and a certificate that is not one.
      assert {:error, :bad_request} = Door.check(from, challenge, air.tls.cert_pem, "x")

      assert {:error, :bad_request} =
               Door.check(from, challenge, "junk", proof.(air.tls.key_pem, challenge))

      # The hub's own certificate, or its authority's, is not a machine's.
      assert {:error, :bad_request} =
               Door.check(from, challenge, hub_pem, proof.(air.tls.key_pem, challenge))

      assert {:error, :bad_request} =
               Door.check(from, challenge, air.tls.ca_pem, proof.(air.tls.key_pem, challenge))

      # A challenge this door did not make, and one that ran out.
      made_up = :crypto.strong_rand_bytes(56)

      assert {:error, :bad_request} =
               Door.check(from, made_up, air.tls.cert_pem, proof.(air.tls.key_pem, made_up))

      # One made just over a minute ago, sealed as this door seals them,
      # rather than waiting for a real one to run out.
      secret = :sys.get_state(Door).secret
      at = System.monotonic_time(:millisecond) - Pairing.limits().check_ms - 1
      body = :crypto.strong_rand_bytes(16) <> <<at::signed-64>>
      old = body <> :crypto.mac(:hmac, :sha256, secret, body)

      assert {:error, :bad_request} =
               Door.check(from, old, air.tls.cert_pem, proof.(air.tls.key_pem, old))

      # Over HTTP: anything but an empty body or a whole answer is refused.
      assert {:error, {:hub, _}} = post_check(port, %{challenge: "zz", cert: "x", proof: "y"})
      assert {:error, {:hub, _}} = post_check(port, %{challenge: 1})
    end

    test "a removed the hub did not sign is not believed", %{dir: dir} do
      port = start_hub(dir)
      air = pair!(port, dir, "air")
      bee = pair!(port, dir, "bee")
      {:ok, air_der} = Authority.cert_bytes(air.tls.cert_pem)
      {:ok, serial} = Authority.serial(air_der)
      {:ok, seen} = Agent.start_link(fn -> nil end)

      # The answer changed on the way, under the hub's own signature.
      changed =
        web(
          {Wallboard.PairingTest.Middle,
           port: port,
           change: fn
             "check", :answer, %{"answer" => _} = body -> %{body | "answer" => "removed"}
             _, _, body -> body
           end}
        )

      assert {:error, {:hub, _}} = Pairing.check(%{host: "127.0.0.1", port: changed}, air.tls)

      # A whole answer signed by another machine of the same hub.
      forged =
        web(
          {Wallboard.PairingTest.Middle,
           port: port,
           change: fn
             "check", :answer, %{"challenge" => hex} = body ->
               Agent.update(seen, fn _ -> Base.decode16!(hex, case: :mixed) end)
               body

             "check", :answer, %{"answer" => _} = body ->
               challenge = Agent.get(seen, & &1)
               text = Pairing.answer_text(challenge, serial, "removed")
               signature = Authority.prove(bee.tls.key_pem, text)

               %{
                 body
                 | "answer" => "removed",
                   "signature" => Base.encode16(signature),
                   "hub" => bee.tls.cert_pem
               }

             _, _, body ->
               body
           end}
        )

      assert {:error, {:hub, _}} = Pairing.check(%{host: "127.0.0.1", port: forged}, air.tls)
      assert {:ok, :approved} = Pairing.check(%{host: "127.0.0.1", port: port}, air.tls)
    end

    test "a machine the hub still takes keeps trying, however often the door is asked",
         %{dir: dir} do
      port = start_hub(dir)
      paired = pair!(port, dir, "air")
      asked = fn -> :sys.get_state(Door).window.calls[{127, 0, 0, 1}] || 0 end
      before = asked.()

      # The link's port answers nothing, the board's does: every try
      # fails, and every third the door says "approved".
      start_client(dir, %{paired | port: closed_port()}, :air,
        door: %{host: "127.0.0.1", port: port}
      )

      for _ <- 1..9, do: assert_receive({:air, {:down, _}}, 5_000)
      wait_until(fn -> :sys.get_state(:air).asking == nil end)

      # Two asks of two calls each, at the third and sixth tries.
      assert asked.() - before >= 4
      refute :removed in said(:air)
      assert %{phase: phase} = Client.status(:air)
      assert phase in [:waiting, :connecting]
    end

    test "a machine whose first ask found no door asks again, and learns it was removed",
         %{dir: dir} do
      paired = pair!(start_hub(dir), dir, "air")
      board = closed_port()
      {:ok, _} = Authority.revoke(Path.join(dir, "link"), "air")

      start_client(dir, paired, :air, door: %{host: "127.0.0.1", port: board})

      # Its first ask, at the third try, finds nothing at the board's port.
      wait_until(fn ->
        s = :sys.get_state(:air)
        s.failed > 3 and s.asking == nil
      end)

      refute :removed in said(:air)

      # The board comes back where the machine looks for it.
      start_supervised!(
        {Bandit, plug: WallboardWeb.Router, ip: :loopback, port: board, startup_log: false},
        id: :board
      )

      assert_receive {:air, :removed}, 10_000
    end

    test "a list of machines that cannot be read is busy, never removed", %{dir: dir} do
      port = start_hub(dir)
      paired = pair!(port, dir, "air")
      list = Path.join([dir, "link", "machines.json"])
      good = File.read!(list)
      File.write!(list, "half a file")
      door = %{host: "127.0.0.1", port: port}

      assert {:error, :busy} = Pairing.check(door, paired.tls)

      File.write!(list, good)
      assert {:ok, :approved} = Pairing.check(door, paired.tls)
    end

    test "a collector paired before the board's port was saved asks on the usual one",
         %{dir: dir} do
      port = start_hub(dir)
      pair!(port, dir, "air")
      folder = Path.join(dir, "air")
      assert {:ok, %{door: %{host: "127.0.0.1", port: ^port}}} = Sender.paired(folder)

      hub = folder |> Path.join("hub.json") |> File.read!() |> Jason.decode!()
      File.write!(Path.join(folder, "hub.json"), Jason.encode!(Map.delete(hub, "port")))
      assert {:ok, %{door: %{host: "127.0.0.1", port: 4747}}} = Sender.paired(folder)
    end
  end

  # A port nothing listens on.
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp wait_until(check, tries \\ 200) do
    cond do
      check.() ->
        :ok

      tries == 0 ->
        flunk("waited too long")

      true ->
        # A pause between looks at a condition, not a wait for a timer.
        Process.sleep(25)
        wait_until(check, tries - 1)
    end
  end

  # Every message from a client that waits here now, in order.
  defp said(tag) do
    receive do
      {^tag, what} -> [what | said(tag)]
    after
      0 -> []
    end
  end

  defp post_check(port, body) do
    {:ok, {{_, status, _}, _, text}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{port}/pair/check", [], ~c"application/json", Jason.encode!(body)},
        [timeout: 5_000],
        body_format: :binary
      )

    if status == 200, do: {:ok, Jason.decode!(text)}, else: {:error, {:hub, status}}
  end

  describe "the door" do
    setup %{dir: dir} do
      %{port: start_hub(dir)}
    end

    defp start_params(name) do
      pair = Authority.new_key_pair()
      {:ok, bytes} = Authority.public_bytes(pair.public_pem)
      nonce = :crypto.strong_rand_bytes(32)

      {%{
         "name" => name,
         "key" => pair.public_pem,
         "commit" => Base.encode16(Pairing.commit(nonce, bytes, name))
       }, nonce}
    end

    defp open(from, name) do
      {params, nonce} = start_params(name)

      with {:ok, %{id: id}} <- Door.start(from, params),
           {:ok, _} <- Door.confirm(from, id, nonce),
           do: {:ok, id}
    end

    test "the mailbox cannot be flooded: five requests, one per address and per name" do
      for n <- 1..5, do: assert({:ok, _} = open({10, 0, 0, n}, "machine-#{n}"))
      assert length(Door.pending()) == 5

      # A sixth is turned away, whoever asks.
      assert {:error, :busy} = open({10, 0, 0, 6}, "machine-6")
      assert length(Door.pending()) == 5

      # Refusing one frees its place.
      [%{id: id} | _] = Door.pending()
      :ok = Door.refuse(id)
      assert {:ok, _} = open({10, 0, 0, 6}, "machine-6")
      # One address holds one request, and so does one name.
      assert {:error, :busy} = open({10, 0, 0, 6}, "machine-7")
      %{id: id} = Enum.find(Door.pending(), &(&1.name != "machine-6"))
      :ok = Door.refuse(id)
      assert {:error, :busy} = open({10, 0, 0, 7}, "machine-6")
      assert length(Door.pending()) == 4
    end

    test "requests started together and shown together still fill only five places" do
      started =
        for n <- 1..10 do
          {params, nonce} = start_params("machine-#{n}")
          {:ok, %{id: id}} = Door.start({10, 0, 0, n}, params)
          {n, id, nonce}
        end

      answers = for {n, id, nonce} <- started, do: Door.confirm({10, 0, 0, n}, id, nonce)
      assert Enum.count(answers, &match?({:ok, _}, &1)) == 5
      assert Enum.count(answers, &(&1 == {:error, :busy})) == 5
      assert length(Door.pending()) == 5
      assert length(Mailbox.items()) == 5
    end

    test "a name is held only by a request the owner can see" do
      # Someone starts a request under a machine's name and never shows
      # its number. The real machine is not kept out by it.
      {params, _} = start_params("air")
      assert {:ok, %{id: squat}} = Door.start({10, 0, 0, 66}, params)
      assert {:ok, id} = open({10, 0, 0, 1}, "air")
      assert [%{id: ^id, name: "air"}] = Door.pending()

      # Shown later, the first one is too late: the name has its request.
      assert {:error, _} = Door.confirm({10, 0, 0, 66}, squat, :crypto.strong_rand_bytes(32))
      {params, nonce} = start_params("box")
      {:ok, %{id: first}} = Door.start({10, 0, 0, 2}, params)
      {:ok, _} = open({10, 0, 0, 3}, "Box")
      assert {:error, :busy} = Door.confirm({10, 0, 0, 2}, first, nonce)
      assert Door.pending() |> Enum.map(& &1.name) |> Enum.sort() == ["Box", "air"]
    end

    test "nothing may pair under the hub's own name", %{dir: dir} do
      stop_supervised!(Door)

      start_supervised!(
        {Door, dir: Path.join(dir, "link"), link_port: Hub.port(), hub_name: "Papa"}
      )

      for name <- ["Papa", "papa"] do
        {params, _} = start_params(name)
        assert {:error, :name_taken} = Door.start({10, 0, 0, 1}, params)
      end

      # Said as what it is, not as a name with the wrong letters in it.
      assert Pairing.why(:name_taken) =~ "same name as this machine"

      assert {:ok, _} = open({10, 0, 0, 1}, "Papa-2")
    end

    test "one address may start six requests a minute" do
      from = {10, 0, 0, 9}

      for n <- 1..6 do
        {params, _} = start_params("m-#{n}")
        assert {:ok, %{id: id}} = Door.start(from, params)
        # A wrong number forgets the request, which frees the address.
        assert {:error, :bad_request} = Door.confirm(from, id, :crypto.strong_rand_bytes(32))
      end

      {params, _} = start_params("m-7")
      assert {:error, :busy} = Door.start(from, params)
      assert Door.pending() == []
    end

    test "a request is shown only once its number is shown, by the address that asked, and a wrong one ends it" do
      {params, nonce} = start_params("air")
      {:ok, %{id: id}} = Door.start({10, 0, 0, 1}, params)
      assert Door.pending() == []
      assert {:error, :gone} = Door.status({10, 0, 0, 1}, id)

      assert {:error, :bad_request} = Door.confirm({10, 0, 0, 2}, id, nonce)
      assert Door.pending() == []
      assert {:ok, _} = Door.confirm({10, 0, 0, 1}, id, nonce)
      assert [%{name: "air"}] = Door.pending()
      # A second number is not a second try.
      assert {:error, :bad_request} = Door.confirm({10, 0, 0, 1}, id, nonce)
      assert {:ok, :waiting} = Door.status({10, 0, 0, 1}, id)
    end

    test "nobody learns a request's code before the owner sees it" do
      # Someone in the middle who knows the code on the real collector
      # would like to try keys against the hub and drop each request whose
      # code does not match, unseen. The hub's answer to a start gives them
      # nothing to work a code out from: only a fingerprint of its number.
      {params, nonce} = start_params("air")
      {:ok, bytes} = Authority.public_bytes(params["key"])
      {:ok, opened} = Door.start({10, 0, 0, 1}, params)
      refute Map.has_key?(opened, :nonce)
      assert byte_size(opened.commit) == 32
      assert Door.pending() == []

      # The number comes with the confirm, and by then the request is in
      # the mailbox under the machine's name, where it stays.
      assert {:ok, hub_nonce} = Door.confirm({10, 0, 0, 1}, opened.id, nonce)
      assert Pairing.hub_commit(hub_nonce) == opened.commit
      {:ok, ca} = Authority.cert_bytes(opened.ca_pem)
      assert [%{name: "air", code: code}] = Door.pending()
      assert code == Pairing.code(bytes, "air", ca, nonce, hub_nonce)

      # A second try under that name has to wait for the first to go.
      assert {:error, :busy} = open({10, 0, 0, 2}, "air")
      assert [%{code: ^code}] = Door.pending()
    end

    test "a machine that gave up before Approve keeps the certificate it holds", %{dir: dir} do
      stop_supervised!(Door)
      link = Path.join(dir, "link")
      start_supervised!({Door, dir: link, link_port: Hub.port(), limits: %{gone_ms: 400}})

      # The machine holds a certificate already, asks for another, and is
      # stopped. The owner approves a moment later.
      {:ok, _} = Authority.issue(link, "air")
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Mailbox.topic())
      {:ok, id} = open({10, 0, 0, 1}, "air")
      assert [%{id: ^id, replaces?: true}] = Door.pending()
      assert :ok = Door.approve(id)
      assert Door.pending() == []

      # Approve made nothing and revoked nothing: nobody came for it.
      assert [%{revoked_at: nil}] = Authority.machines(link)

      # Somebody else who knows the request's id cannot fetch it either,
      # nor set the signing off.
      assert {:ok, :waiting} = Door.status({10, 0, 0, 99}, id)
      assert [%{revoked_at: nil}] = Authority.machines(link)

      # The machine that asked, had it stayed, gets its certificate, and
      # only then does the older one stop working.
      assert {:ok, {:approved, cert}} = Door.status({10, 0, 0, 1}, id)
      assert {:ok, {:approved, ^cert}} = Door.status({10, 0, 0, 99}, id)

      assert [true, false] =
               link
               |> Authority.machines()
               |> Enum.map(&(&1.revoked_at == nil))
               |> Enum.sort(:desc)
    end

    test "a request whose machine stopped asking leaves the mailbox by itself" do
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Mailbox.topic())
      {:ok, id} = open({10, 0, 0, 1}, "air")
      assert_receive {:mailbox, :changed}, 1_000
      gone = Pairing.limits().gone_ms

      # Time passes by moving the request's last ask back, not by
      # sleeping, so a slow machine cannot run a request out early.
      older = fn ms ->
        :sys.replace_state(Door, fn s ->
          update_in(s.requests[id], &%{&1 | asked: &1.asked - ms})
        end)
      end

      # While its machine asks, it stays. Someone else asking does not
      # keep it there.
      older.(div(gone * 2, 3))
      assert {:ok, :waiting} = Door.status({10, 0, 0, 1}, id)
      older.(div(gone * 2, 3))
      assert [%{id: ^id}] = Door.pending()
      assert {:ok, :waiting} = Door.status({10, 0, 0, 99}, id)
      older.(div(gone * 2, 3))
      assert Door.pending() == []
      assert {:error, :gone} = Door.status({10, 0, 0, 1}, id)
      assert {:error, :gone} = Door.approve(id)
      # Its place is free again.
      assert {:ok, _} = open({10, 0, 0, 1}, "air")
    end

    test "bad names, bad keys and anything else are refused" do
      {params, _} = start_params("air")
      from = {10, 0, 0, 1}
      assert {:error, :bad_name} = Door.start(from, %{params | "name" => "air/../x"})
      assert {:error, :bad_name} = Door.start(from, %{params | "name" => Authority.hub_name()})
      assert {:error, :bad_key} = Door.start(from, %{params | "key" => "not a key"})
      assert {:error, :bad_request} = Door.start(from, %{params | "commit" => "abc"})
      assert {:error, :bad_request} = Door.start(from, Map.delete(params, "key"))
      assert {:error, :bad_request} = Door.start(from, %{"session" => "data"})
      assert Door.pending() == []
    end

    test "over HTTP it takes small JSON and nothing else", %{port: port} do
      post = fn step, body ->
        {:ok, {{_, status, _}, _, reply}} =
          :httpc.request(
            :post,
            {~c"http://127.0.0.1:#{port}/pair/#{step}", [], ~c"application/json", body},
            [timeout: 5_000],
            body_format: :binary
          )

        {status, reply}
      end

      assert {422, _} = post.("start", "not json")
      assert {422, _} = post.("start", "[1,2]")
      assert {413, _} = post.("start", Jason.encode!(%{name: String.duplicate("a", 5_000)}))
      assert {422, _} = post.("confirm", Jason.encode!(%{id: "x", nonce: "zz"}))
      assert {404, reply} = post.("wait", Jason.encode!(%{id: "no-such-request"}))
      assert Jason.decode!(reply) == %{"error" => "gone"}
      assert Door.pending() == []
    end

    test "a request that never shows its number is dropped, and frees its address" do
      {params, nonce} = start_params("air")
      {:ok, %{id: id}} = Door.start({10, 0, 0, 1}, params)

      # Its time to show the number runs out by moving its start back.
      :sys.replace_state(Door, fn s ->
        update_in(s.requests[id], &%{&1 | made: &1.made - Pairing.limits().confirm_ms})
      end)

      assert {:error, :gone} = Door.confirm({10, 0, 0, 1}, id, nonce)
      assert {:ok, _} = open({10, 0, 0, 1}, "air")
    end
  end

  test "a board with the link off has no door, and the collector is told so", %{dir: dir} do
    port = web(WallboardWeb.Router)
    assert Mailbox.items() == []
    assert {:error, _} = Mailbox.act("machine:x", "approve")
    assert {:error, :not_a_hub} = Task.await(ask(port, dir, "air"), 5_000)
    assert Pairing.why(:not_a_hub) =~ "turn on Take collectors"
  end

  describe "the mailbox" do
    test "counts and lists the request, and the item goes away after Approve or Refuse",
         %{dir: dir} do
      port = start_hub(dir)
      assert Mailbox.items() == []
      assert panel() =~ "Nothing to decide."

      task = ask(port, dir, "air")
      assert_receive {:code, "air", %{code: code}}, 5_000

      assert [%{id: id, title: "A new machine wants to connect", actions: actions}] =
               Mailbox.items()

      assert actions == [{"approve", "Approve"}, {"refuse", "Refuse"}]

      page = panel()
      assert page =~ "1 thing to decide"
      assert page =~ "A new machine wants to connect"
      assert page =~ "air shows the code"
      assert page =~ ~s(<span class="mailbox-code">#{code}</span>)
      assert page =~ "Approve only if that matches what the machine shows."
      assert page =~ ~r/class="mailbox-act primary"[^>]*phx-value-action="approve"/s
      assert page =~ ~r/phx-value-action="refuse"/
      refute page =~ "disabled"

      # Someone who may only look sees the same list with the buttons off.
      looking = panel(false)
      assert looking =~ "disabled"
      assert looking =~ "Decide on the hub&#39;s own machine."

      assert :ok = Mailbox.act(id, "approve")
      assert Mailbox.items() == []
      assert {:error, :gone} = Mailbox.act(id, "approve")
      assert {:ok, _} = Task.await(task, 5_000)

      task = ask(port, dir, "box")
      assert_receive {:code, "box", _}, 5_000
      assert [%{id: id}] = Mailbox.items()
      assert :ok = Mailbox.act(id, "refuse")
      assert Mailbox.items() == []
      assert {:error, :refused} = Task.await(task, 5_000)
    end

    test "with a board password set, approving from a device that has not entered it is refused",
         %{dir: dir} do
      port = start_hub(dir)
      Settings.put(%{token: "open sesame"})
      task = ask(port, dir, "air")
      assert_receive {:code, "air", _}, 5_000
      assert [%{id: id}] = Mailbox.items()

      # The page itself is closed to a device without the password...
      conn = Plug.Test.conn(:get, "/") |> Plug.Test.init_test_session(%{})
      conn = %{conn | params: %{}}
      assert %{status: 401, halted: true} = Auth.call(conn, [])
      assert {:halt, _} = Auth.on_mount(:default, %{}, %{}, socket(%{}))

      # ...and so is the button, for a connection that got in some other
      # way: one with no proof, one with an older password's proof, and one
      # that is merely on the hub's own machine.
      for who <- [
            %{local?: false, token_hash: nil},
            %{local?: false, token_hash: Auth.hash("an older password")},
            %{local?: true, token_hash: nil}
          ] do
        refute Auth.may_decide?(who)

        assert {:noreply, after_tap} =
                 BoardLive.handle_event(
                   "mailbox_act",
                   %{"id" => id, "action" => "approve"},
                   board_socket(who)
                 )

        assert after_tap.assigns.mailbox_note == "Open the board with its password to decide."
        assert [%{id: ^id}] = Mailbox.items()
        assert Authority.machines(Path.join(dir, "link")) == []
      end

      # The device that entered it approves.
      who = %{local?: false, token_hash: Auth.hash("open sesame")}
      assert Auth.may_decide?(who)

      assert {:noreply, after_tap} =
               BoardLive.handle_event(
                 "mailbox_act",
                 %{"id" => id, "action" => "approve"},
                 board_socket(who)
               )

      assert after_tap.assigns.mailbox_note == nil
      assert after_tap.assigns.mailbox == []
      assert {:ok, _} = Task.await(task, 5_000)
    end

    test "the hub's own machine means a connection from it, asked for by one of its own names" do
      {:ok, own} = :inet.gethostname()
      own = to_string(own)

      for host <- ["localhost", "LOCALHOST", "127.0.0.1", "192.168.1.20", "[::1]", own] do
        assert Auth.own_host?(host), host
      end

      assert Auth.own_host?(String.replace_suffix(own, ".local", "") <> ".local")

      # A page on somebody else's name, pointed at this machine, connects
      # from this machine too. Its name gives it away.
      for host <- ["evil.example", "127.0.0.1.evil.example", "localhost.evil.example", "", nil] do
        refute Auth.own_host?(host), inspect(host)
      end
    end

    test "with no board password, only the hub's own machine may decide", %{dir: dir} do
      port = start_hub(dir)
      task = ask(port, dir, "air")
      assert_receive {:code, "air", _}, 5_000
      assert [%{id: id}] = Mailbox.items()

      refute Auth.may_decide?(%{local?: false, token_hash: nil})
      refute Auth.may_decide?(%{})

      assert {:noreply, after_tap} =
               BoardLive.handle_event(
                 "mailbox_act",
                 %{"id" => id, "action" => "approve"},
                 board_socket(%{local?: false, token_hash: nil})
               )

      assert after_tap.assigns.mailbox_note =~ "hub's own machine"
      assert [%{id: ^id}] = Mailbox.items()

      assert {:noreply, _} =
               BoardLive.handle_event(
                 "mailbox_act",
                 %{"id" => id, "action" => "approve"},
                 board_socket(%{local?: true, token_hash: nil})
               )

      assert {:ok, _} = Task.await(task, 5_000)
    end
  end

  describe "connected machines" do
    test "Disconnect closes that machine's stream and refuses its next connect; others are untouched",
         %{dir: dir} do
      port = start_hub(dir)
      air = pair!(port, dir, "air")
      box = pair!(port, dir, "box")
      start_client(dir, air, :air)
      box_client = start_client(dir, box, :box)
      for tag <- [:air, :box], do: assert_receive({^tag, {:resume, _}}, 5_000)
      :ok = Client.push(box_client, event(1))
      assert_receive {:box, {:stored, _}}, 5_000

      settings =
        Settings.defaults()
        |> put_in([:archive, :path], Path.join(dir, "wallboard.db"))
        |> put_in([:link, :enabled], true)

      # The list: this hub first, then each machine with what its hello said.
      assert [hub, %{name: "air"} = a, %{name: "box"} = b] = Machines.list(settings, 3)
      assert hub.hub? and hub.sessions == 3 and hub.os == Machines.os_name()

      assert {a.hub?, a.connected?, a.os, a.folders} ==
               {false, true, "macOS 15.6", ["/Users/r/.claude"]}

      assert {b.connected?, b.sessions} == {true, 1}

      page = socket(%{allowed?: true, who: %{local?: true}, settings: settings, notice: nil})
      page = %{page | assigns: Map.put(page.assigns, :confirm_disconnect, nil)}

      # The first tap only asks.
      assert {:noreply, page} =
               SettingsLive.handle_event("disconnect", %{"machine" => "air"}, page)

      assert page.assigns.confirm_disconnect == "air"
      assert Map.keys(Hub.connected()) |> Enum.sort() == ["air", "box"]

      # The second revokes: the machine is told, and its stream is closed.
      assert {:noreply, page} =
               SettingsLive.handle_event("disconnect", %{"machine" => "air"}, page)

      assert page.assigns.notice =~ "air is disconnected"
      assert Enum.map(page.assigns.linked, & &1.name) == [hub.name, "box"]
      assert_receive {:air, :removed}, 5_000
      wait_until(fn -> Map.keys(Hub.connected()) == ["box"] end)

      # Its next connect is refused, with the same certificate.
      start_client(dir, air, :air_again)
      # (A client can count a TLS 1.3 connection as open before it hears
      # the hub turned its certificate down, so what tells is that the hub
      # never answers it and never lists it.)
      assert_receive {:air_again, {:down, _}}, 5_000
      refute_received {:air_again, {:resume, _}}
      assert Map.keys(Hub.connected()) == ["box"]

      # The other machine never noticed.
      refute_received {:box, :removed}
      refute_received {:box, {:down, _}}
      :ok = Client.push(box_client, event(2))
      assert_receive {:box, {:stored, _}}, 5_000
      assert length(Store.collector_events("box")) == 2
    end

    test "a list of machines that cannot be read is not taken for an empty one", %{dir: dir} do
      port = start_hub(dir)
      pair!(port, dir, "air")

      settings =
        Settings.defaults()
        |> put_in([:archive, :path], Path.join(dir, "wallboard.db"))
        |> put_in([:link, :enabled], true)

      assert Machines.readable?(settings)
      assert [_hub, %{name: "air"}] = Machines.list(settings)

      file = Path.join([dir, "link", "machines.json"])
      good = File.read!(file)
      File.write!(file, "{ not json")
      refute Machines.readable?(settings)
      assert [%{hub?: true}] = Machines.list(settings)

      page = socket(%{allowed?: true, who: %{local?: true}, settings: settings, notice: nil})
      page = %{page | assigns: Map.put(page.assigns, :confirm_disconnect, "air")}

      assert {:noreply, page} =
               SettingsLive.handle_event("disconnect", %{"machine" => "air"}, page)

      assert page.assigns.notice =~ "could not be disconnected"
      refute page.assigns.linked_readable?

      File.write!(file, good)
      assert Authority.working?(Path.join(dir, "link"), "air")
    end

    test "Disconnect is refused once the board password no longer matches", %{dir: dir} do
      port = start_hub(dir)
      pair!(port, dir, "air")
      Settings.put(%{token: "new password"})

      page =
        socket(%{
          allowed?: true,
          who: %{local?: true, token_hash: Auth.hash("old password")},
          settings: Settings.defaults(),
          notice: nil,
          confirm_disconnect: "air"
        })

      assert {:noreply, page} =
               SettingsLive.handle_event("disconnect", %{"machine" => "air"}, page)

      assert page.assigns.notice =~ "Open this page again"
      assert Authority.working?(Path.join(dir, "link"), "air")

      # The same goes for everything else the page can do.
      assert {:noreply, page} = SettingsLive.handle_event("new_key", %{}, page)
      assert page.assigns.notice =~ "Open this page again"
      assert {:noreply, _} = SettingsLive.handle_event("save", %{"s" => %{}}, page)
      assert Settings.get().token == "new password"
    end
  end

  describe "finding the hub" do
    test "reads what dns-sd prints" do
      browse = """
      Browsing for _wallboard._tcp.local
      DATE: ---Wed 30 Sep 2026---
      22:41:07.123  ...STARTING...
      Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
      22:41:07.124  Add        3  11 local.               _wallboard._tcp.     Wallboard on studio
      22:41:07.124  Add        2  12 local.               _wallboard._tcp.     Wallboard on studio
      22:41:09.001  Rmv        0  11 local.               _wallboard._tcp.     Wallboard on old
      """

      assert Pairing.browsed(browse) == ["Wallboard on studio"]

      lookup = """
      Lookup Wallboard on studio._wallboard._tcp.local
      22:41:08.010  Wallboard\\032on\\032studio._wallboard._tcp.local. can be reached at studio.local.:4747 (interface 11)
       path=/
      """

      assert Pairing.resolved(lookup, "Wallboard on studio") ==
               [%{name: "Wallboard on studio", host: "studio.local", port: 4747}]
    end

    test "reads what avahi-browse prints" do
      out = """
      +;eth0;IPv4;Wallboard\\032on\\032box;_wallboard._tcp;local
      =;eth0;IPv6;Wallboard\\032on\\032box;_wallboard._tcp;local;box.local;fe80::1;4747;"path=/"
      =;eth0;IPv4;Wallboard\\032on\\032box;_wallboard._tcp;local;box.local;192.168.1.30;4747;"path=/"
      """

      found = Pairing.avahi(out)

      assert Pairing.one_per_host(found) ==
               [%{name: "Wallboard on box", host: "192.168.1.30", port: 4747}]

      # A hub with two network cards is one hub; two hosts under one name
      # are two, so the person is asked which.
      second_card = %{name: "Wallboard on box", host: "10.0.0.30", port: 4747, as: "box.local"}
      other_host = %{name: "Wallboard on box", host: "10.0.0.66", port: 4747, as: "evil.local"}
      assert length(Pairing.one_per_host(found ++ [second_card])) == 1
      assert length(Pairing.one_per_host(found ++ [other_host])) == 2

      # A name is printed in a terminal: nothing but plain text gets there.
      assert [%{name: "Wallboard[2J"}] =
               Pairing.avahi(
                 ~s(=;eth0;IPv4;Wallboard\\027[2J;_wallboard._tcp;local;b.local;10.0.0.1;4747;"")
               )
    end

    test "this machine's own name is one a certificate can carry" do
      assert Authority.machine_name?(Pairing.machine_name())
    end
  end
end
