defmodule Wallboard.DevicesTest do
  # One devices door at a time: it has one name.
  use ExUnit.Case, async: false

  alias Wallboard.{Devices, Mailbox, Settings}
  alias WallboardWeb.Auth

  @moduletag :capture_log

  @ipad "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"

  setup do
    dir = Wallboard.Fixtures.tmp_path("wallboard-devices")
    File.mkdir_p!(dir)

    old = :persistent_term.get({Settings, :settings}, nil)
    Settings.put(%{approve_devices: true})

    on_exit(fn ->
      File.rm_rf!(dir)

      if old,
        do: :persistent_term.put({Settings, :settings}, old),
        else: :persistent_term.erase({Settings, :settings})
    end)

    %{dir: dir}
  end

  defp start(dir, limits \\ []), do: start_supervised!({Devices, dir: dir, limits: limits})

  # A request from another device on the network, carrying the session
  # its browser kept from the last answer.
  defp visit(session, opts \\ []) do
    path = Keyword.get(opts, :path, "/")
    ip = Keyword.get(opts, :ip, {192, 0, 2, 7})
    host = Keyword.get(opts, :host, "papa.local.example")

    Plug.Test.conn(:get, path)
    |> Map.put(:remote_ip, ip)
    |> Map.put(:host, host)
    |> Plug.Conn.put_req_header("user-agent", @ipad)
    |> Plug.Test.init_test_session(session)
    |> Plug.Conn.fetch_query_params()
    |> Auth.call([])
  end

  defp session(conn), do: Plug.Conn.get_session(conn)

  defp code(conn) do
    [_, code] = Regex.run(~r/class="code">(\d{3}-\d{3})</, conn.resp_body)
    code
  end

  describe "a device the board does not know" do
    test "sees a code that the mailbox shows too, and nothing of the board", %{dir: dir} do
      start(dir)
      conn = visit(%{})

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "Approve this device"
      assert conn.resp_body =~ ~s(http-equiv="refresh")
      code = code(conn)

      assert [%{id: "device:" <> _, title: title, body: body}] = Mailbox.items()
      assert title == "A device wants to open the board"
      assert {:code, code} in body
      assert Enum.any?(body, &match?({:text, "iPad, Safari at 192.0.2.7" <> _}, &1))

      # Looking again shows the same code, and asks nothing new.
      again = visit(session(conn))
      assert code(again) == code
      assert length(Mailbox.items()) == 1
    end

    test "opens the board once approved, and stays in", %{dir: dir} do
      start(dir)
      conn = visit(%{})
      [%{id: id}] = Mailbox.items()
      assert :ok = Mailbox.act(id, "approve")
      assert Mailbox.items() == []

      opened = visit(session(conn))
      assert opened.status == 303
      assert Plug.Conn.get_resp_header(opened, "location") == ["/"]
      key = session(opened)["device"]
      assert is_binary(key)

      # From then on the board itself answers: the plug lets it through.
      through = visit(session(opened))
      refute through.halted
      assert Devices.approved?(key)

      # The key is never kept as itself.
      refute File.read!(Path.join(dir, "devices.json")) =~ key
      assert Bitwise.band(File.stat!(Path.join(dir, "devices.json")).mode, 0o777) == 0o600
    end

    test "survives a restart once approved, and is signed out at once when removed", %{dir: dir} do
      pid = start(dir)
      conn = visit(%{})
      [%{id: id}] = Mailbox.items()
      :ok = Mailbox.act(id, "approve")
      opened = visit(session(conn))

      # A restart forgets the waiting, never the approved.
      stop_supervised!(Devices)
      refute Process.alive?(pid)
      start(dir)
      refute visit(session(opened)).halted

      Phoenix.PubSub.subscribe(Wallboard.PubSub, Devices.topic())
      assert [%{id: device, name: "iPad, Safari", address: "192.0.2.7"}] = Devices.list()
      assert :ok = Devices.remove(device)
      assert_receive {:devices, :changed}

      back = visit(session(opened))
      assert back.status == 401
      assert back.resp_body =~ "Approve this device"
      refute Auth.may_decide?(%{local?: false, device: session(opened)["device"]})
    end

    test "that was refused is told so, and can ask again", %{dir: dir} do
      start(dir)
      conn = visit(%{})
      [%{id: id}] = Mailbox.items()
      assert :ok = Mailbox.act(id, "refuse")

      refused = visit(session(conn))
      assert refused.status == 403
      assert refused.resp_body =~ "was refused"
      refute refused.resp_body =~ "http-equiv"

      # It does not fill the mailbox again by itself.
      still = visit(session(refused))
      assert still.status == 403
      assert Mailbox.items() == []

      asked = visit(session(still), path: "/?ask=again")
      assert asked.status == 401
      assert [_] = Mailbox.items()
    end

    test "cannot collect an approval from another address", %{dir: dir} do
      start(dir)
      conn = visit(%{})
      [%{id: id}] = Mailbox.items()
      :ok = Mailbox.act(id, "approve")

      # Someone who copied the cookie, elsewhere on the network.
      other = visit(session(conn), ip: {192, 0, 2, 99})
      assert other.status == 401
      refute session(other)["device"]
      assert Devices.list() == []
    end
  end

  describe "the door" do
    test "has room for only so many, and only so many asks a minute from one address",
         %{dir: dir} do
      start(dir, max_pending: 2, starts_per_minute: 1)

      assert {:ok, _, _} = Devices.ask("192.0.2.1", "a")
      # The same address gets its own request back, not a new one.
      assert {:ok, _, _} = Devices.ask("192.0.2.1", "a")
      assert {:ok, _, _} = Devices.ask("192.0.2.2", "b")
      assert {:error, :busy} = Devices.ask("192.0.2.3", "c")

      busy = visit(%{}, ip: {192, 0, 2, 4})
      assert busy.status == 503
      assert busy.resp_body =~ "busy"
    end

    test "lets a request go once its browser stops looking", %{dir: dir} do
      start(dir, gone_ms: 0)
      assert {:ok, id, _} = Devices.ask("192.0.2.1", "a")
      assert Devices.pending() == []
      assert Devices.status(id, "192.0.2.1") == :gone
    end

    test "codes are six digits in two groups" do
      for _ <- 1..50, do: assert(Devices.code() =~ ~r/^\d{3}-\d{3}$/)
    end

    test "names a browser plainly, whatever it says" do
      assert Devices.device_name(@ipad) == "iPad, Safari"

      assert Devices.device_name(
               "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/129.0 Safari/537.36"
             ) == "Mac, Chrome"

      assert Devices.device_name("curl/8.7.1") == "A device"
      assert Devices.device_name(nil) == "A device"
    end

    test "starts with nobody approved when its file cannot be read", %{dir: dir} do
      File.write!(Path.join(dir, "devices.json"), "{ not json")
      start(dir)
      assert Devices.list() == []
      assert visit(%{}).status == 401
    end
  end

  describe "the board's own machine" do
    test "never needs a code, by any of its own names", %{dir: dir} do
      start(dir)

      for host <- ["localhost", "127.0.0.1"] do
        refute visit(%{}, ip: {127, 0, 0, 1}, host: host).halted, host
      end

      assert Mailbox.items() == []
      assert Auth.may_decide?(%{local?: true, device: nil})
    end

    test "asked by somebody else's name is another device", %{dir: dir} do
      start(dir)
      assert visit(%{}, ip: {127, 0, 0, 1}, host: "evil.example").status == 401
    end
  end

  describe "an open page" do
    import Phoenix.ConnTest, only: [build_conn: 0, init_test_session: 2, get: 2]
    import Phoenix.LiveViewTest

    @endpoint WallboardWeb.Endpoint

    setup do
      endpoint = Application.get_env(:wallboard, @endpoint, [])

      Application.put_env(
        :wallboard,
        @endpoint,
        Keyword.merge(endpoint, secret_key_base: String.duplicate("k", 64), server: false)
      )

      start_supervised!(@endpoint)
      on_exit(fn -> Application.put_env(:wallboard, @endpoint, endpoint) end)

      Settings.put(%{
        approve_devices: true,
        archive: %{enabled: false},
        new_relic: %{enabled: false}
      })
    end

    test "on a device that is removed goes back to the code at once", %{dir: dir} do
      start(dir)
      {:ok, id, _} = Devices.ask("127.0.0.1", "iPad")
      :ok = Devices.approve(id)
      {:approved, key} = Devices.status(id, "127.0.0.1")

      # Asked as www.example.com, so not this machine's own name.
      conn = build_conn() |> init_test_session(%{"device" => key})
      {:ok, view, html} = live(conn, "/settings")
      assert html =~ "Approved devices"
      assert render(view) =~ "iPad"

      [%{id: device}] = Devices.list()
      assert :ok = Devices.remove(device)
      assert_redirect(view, "/")
    end

    test "with a key nobody approved does not open", %{dir: dir} do
      start(dir)
      conn = build_conn() |> init_test_session(%{"device" => "made up"})
      conn = get(conn, "/settings")
      assert conn.status == 401
      assert conn.resp_body =~ "Approve this device"
    end
  end

  describe "with approval off" do
    test "anyone on the network can look, and only this machine decides", %{dir: dir} do
      start(dir)
      Settings.put(%{approve_devices: false})
      refute visit(%{}).halted
      assert Mailbox.items() == []
      refute Auth.may_decide?(%{local?: false, device: nil})
    end
  end

  describe "the cookie key" do
    test "is made once at random, kept for this user only, and the same after", %{dir: dir} do
      key = Devices.cookie_key!(dir)
      assert byte_size(key) >= 64
      assert Devices.cookie_key!(dir) == key
      assert Bitwise.band(File.stat!(Path.join(dir, "cookie_key")).mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700

      other = Path.join(dir, "other")
      refute Devices.cookie_key!(other) == key
    end
  end

  describe "an old board password" do
    test "turns approval on, until a save turns it off" do
      Settings.put(%{token: "hunter2"})
      settings = Settings.get()
      assert settings.approve_devices == true
      refute Map.has_key?(settings, :token)

      Settings.put(%{token: "  "})
      assert Settings.get().approve_devices == false

      Settings.put(%{token: "hunter2", approve_devices: false})
      assert Settings.get().approve_devices == false
    end
  end
end
