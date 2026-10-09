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

  # A device asks, the owner approves, and it collects its key.
  defp approved_key do
    ip = "192.0.2.#{System.unique_integer([:positive]) |> rem(250)}"
    {:ok, id, _} = Devices.ask(ip, "iPad")
    :ok = Devices.approve(id)
    {:approved, key} = Devices.status(id, ip)
    key
  end

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

    test "another browser at the same address gets a request and a code of its own",
         %{dir: dir} do
      start(dir)
      ipad = visit(%{})
      other = visit(%{})
      refute session(ipad)["device_ask"] == session(other)["device_ask"]
      refute code(ipad) == code(other)

      # The owner approves the iPad's code. The other browser, however
      # often it looks, collects nothing.
      [_, _] = items = Mailbox.items()
      ipad_item = Enum.find(items, fn i -> {:code, code(ipad)} in i.body end)
      :ok = Mailbox.act(ipad_item.id, "approve")

      for _ <- 1..3 do
        looked = visit(session(other))
        assert looked.status == 401
        refute session(looked)["device"]
      end

      assert visit(session(ipad)).status == 303
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
    test "has room for only so many, from one address and in all", %{dir: dir} do
      start(dir, max_pending: 3, max_per_address: 2)

      assert {:ok, a, _} = Devices.ask("192.0.2.1", "a")
      assert {:ok, b, _} = Devices.ask("192.0.2.1", "a")
      refute a == b
      assert {:error, :busy} = Devices.ask("192.0.2.1", "a")
      assert {:ok, _, _} = Devices.ask("192.0.2.2", "b")
      assert {:error, :busy} = Devices.ask("192.0.2.3", "c")

      busy = visit(%{}, ip: {192, 0, 2, 4})
      assert busy.status == 503
      assert busy.resp_body =~ "busy"
    end

    test "only so many asks a minute from one address", %{dir: dir} do
      start(dir, starts_per_minute: 1)
      assert {:ok, id, _} = Devices.ask("192.0.2.1", "a")
      :ok = Devices.refuse(id)
      assert :refused = Devices.status(id, "192.0.2.1")
      assert {:error, :busy} = Devices.ask("192.0.2.1", "a")
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

    test "asked by somebody else's name is sent to its own name, and asks nothing",
         %{dir: dir} do
      # A page some site led this Mac's own browser to.
      start(dir)
      conn = visit(%{}, ip: {127, 0, 0, 1}, host: "evil.example")
      assert conn.status == 403
      assert conn.resp_body =~ "own name"
      assert Mailbox.items() == []
    end

    test "through a proxy that says so is another device", %{dir: dir} do
      start(dir)

      conn =
        Plug.Test.conn(:get, "/")
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Map.put(:host, "localhost")
        |> Plug.Conn.put_req_header("x-forwarded-for", "100.64.0.9")
        |> Plug.Test.init_test_session(%{})
        |> Plug.Conn.fetch_query_params()
        |> Auth.call([])

      assert conn.status == 401
      assert conn.resp_body =~ "Approve this device"
      assert [_] = Mailbox.items()
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

    test "through a proxy on this Mac is never this Mac, even with approval off", %{dir: dir} do
      start(dir)

      Settings.put(%{
        approve_devices: false,
        archive: %{enabled: false},
        new_relic: %{enabled: false}
      })

      here = %{build_conn() | remote_ip: {127, 0, 0, 1}, host: "localhost"}

      # The person at this Mac.
      {:ok, _, html} = live(here, "/settings")
      assert html =~ "Settings are shown here"

      # Visitors through a proxy, by either header a proxy may add.
      for {name, value} <- [{"x-forwarded-for", "100.64.0.9"}, {"forwarded", "for=100.64.0.9"}] do
        {:ok, _, html} = here |> Plug.Conn.put_req_header(name, value) |> live("/settings")
        assert html =~ "Open this page on the machine that runs the board", name
      end
    end

    test "while approval is off, lists approved devices and says they change nothing",
         %{dir: dir} do
      start(dir)
      approved_key()

      Settings.put(%{
        approve_devices: false,
        archive: %{enabled: false},
        new_relic: %{enabled: false}
      })

      here = %{build_conn() | remote_ip: {127, 0, 0, 1}, host: "localhost"}
      {:ok, _, html} = live(here, "/settings")
      assert html =~ "Approved devices"
      assert html =~ "none of these can change anything"
      refute html =~ "Remove signs it out at once"
    end

    test "drawn before approval was turned on cannot connect live after", %{dir: dir} do
      # The page came through while the board was open to all; then the
      # board restarted asking for approval, and the page reconnects.
      start(dir)

      Settings.put(%{
        approve_devices: false,
        archive: %{enabled: false},
        new_relic: %{enabled: false}
      })

      conn = %{build_conn() | remote_ip: {192, 0, 2, 7}} |> get("/settings")
      assert conn.status == 200

      Settings.put(%{
        approve_devices: true,
        archive: %{enabled: false},
        new_relic: %{enabled: false}
      })

      assert {:error, {:redirect, %{to: "/"}}} = live(conn)
    end

    test "Remove on the Settings page signs that device out", %{dir: dir} do
      start(dir)
      keys = for _ <- 1..2, do: approved_key()
      [mine, theirs] = keys
      [%{id: their_id}, %{id: my_id}] = Devices.list()

      {:ok, view, _} = build_conn() |> init_test_session(%{"device" => mine}) |> live("/settings")
      html = view |> element(~s(button[phx-value-id="#{their_id}"])) |> render_click()

      assert html =~ "The device is removed"
      assert [%{id: ^my_id}] = Devices.list()
      refute Devices.approved?(theirs)
      assert Devices.approved?(mine)
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
      conn = %{build_conn() | remote_ip: {192, 0, 2, 7}}
      conn = conn |> init_test_session(%{"device" => "made up"}) |> get("/settings")
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

  describe "last opened" do
    test "follows the device's visits", %{dir: dir} do
      start(dir, seen_ms: 0)
      key = approved_key()
      file = Path.join(dir, "devices.json")
      [d] = Jason.decode!(File.read!(file))
      File.write!(file, Jason.encode!([%{d | "seen_at" => 0}]))
      stop_supervised!(Devices)
      start(dir, seen_ms: 0)
      assert [%{seen_at: 0}] = Devices.list()

      assert Devices.approved?(key)
      assert [%{seen_at: at}] = Devices.list()
      assert at > 0
    end
  end

  describe "two looks at the same approval at once" do
    test "both get the same key, so neither loses it", %{dir: dir} do
      start(dir)
      {:ok, id, _} = Devices.ask("192.0.2.7", "iPad")
      :ok = Devices.approve(id)
      assert {:approved, key} = Devices.status(id, "192.0.2.7")
      assert {:approved, ^key} = Devices.status(id, "192.0.2.7")
      assert [_] = Devices.list()
    end
  end

  describe "the cookie key" do
    test "is what the board signs its cookies with, never one anyone could work out", %{dir: dir} do
      settings = Settings.merge(Settings.defaults(), %{archive: %{path: Path.join(dir, "w.db")}})
      key = Settings.secret_key_base(settings)
      assert key == Devices.cookie_key!(Devices.dir(settings))

      refute key ==
               :crypto.hash(:sha512, "wallboard:wallboard-without-a-token") |> Base.encode64()
    end

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
