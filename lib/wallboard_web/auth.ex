defmodule WallboardWeb.Auth do
  @moduledoc """
  Who may open the board, and who may decide things on it.

  With `approve_devices` off (the default), anyone on the network can look
  at the board. With it on, a browser on another device first shows a code
  and waits until the owner approves it in the mailbox (see
  `Wallboard.Devices`); its session cookie keeps it approved from then on.
  The board's own machine never waits: a request from this machine, asked
  by one of its own names, is let in, unless a proxy on this machine says it
  passed it on (`forwarded?/1`). A proxy that says nothing cannot be told
  from the person at this machine.

  Looking at the board and deciding things on it are two different rights.
  Changing settings, or acting on a mailbox item, is for the owner: see
  `may_decide?/1`.
  """

  import Plug.Conn

  alias Wallboard.Devices

  def init(opts), do: opts

  def call(conn, _opts) do
    # The live connection sees only a proxy's X- headers, so the page tells
    # it what it saw, `Forwarded` too (see `who/2`).
    conn =
      if forwarded?(conn),
        do: put_session(conn, :proxied, true),
        else: delete_session(conn, :proxied)

    cond do
      not Wallboard.Settings.get().approve_devices -> conn
      local_conn?(conn) -> conn
      Devices.approved?(get_session(conn, :device)) -> conn
      true -> WallboardWeb.DevicePage.ask(conn)
    end
  end

  # The live connection needs the same proof as the page, and loses it the
  # moment its device is removed.
  def on_mount(:default, _params, session, socket) do
    if Phoenix.LiveView.connected?(socket) do
      # Where the connection comes from is only known while it mounts.
      local? = who(socket, session).local?
      Phoenix.PubSub.subscribe(Wallboard.PubSub, Devices.topic())

      socket =
        Phoenix.LiveView.attach_hook(socket, :devices, :handle_info, fn
          {:devices, :changed}, socket ->
            if may_open?(local?, session),
              do: {:cont, socket},
              else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}

          _, socket ->
            {:cont, socket}
        end)

      if may_open?(local?, session),
        do: {:cont, socket},
        else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    else
      # A page drawn before the live connection came through `call/2`.
      {:cont, socket}
    end
  end

  defp may_open?(local?, session) do
    local? or not Wallboard.Settings.get().approve_devices or
      Devices.approved?(session["device"])
  end

  # A plain request from this machine, by one of its own names (see `who/2`
  # for why the name matters), that no proxy passed on.
  defp local_conn?(conn), do: here?(conn.remote_ip, conn.host) and not forwarded?(conn)

  @doc """
  True when a connection from `addr`, asking for `host`, is someone at this
  machine. From one of its network addresses (http://192.168.1.20:4747
  connects from 192.168.1.20), any of its own names will do. From its
  loopback address, only `localhost`, a loopback address or its host name:
  a tunnel or forward into this machine (ssh -R, a Tailscale TCP forward)
  also connects from loopback, carrying the name its visitor used.
  """
  def here?(addr, host) do
    addr = unmap(addr)

    cond do
      loopback?(addr) -> loopback_host?(host)
      addr in own_addresses() -> own_host?(host)
      true -> false
    end
  end

  defp loopback_host?(host) when is_binary(host) do
    bare = host |> String.downcase() |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_strict_address(String.to_charlist(bare)) do
      {:ok, ip} -> loopback?(unmap(ip))
      _ -> own_host?(host)
    end
  end

  defp loopback_host?(_), do: false

  @proxy_headers ~w(forwarded x-forwarded-for x-forwarded-host x-real-ip)

  @doc """
  True when a request came through a proxy that says so (Tailscale Serve,
  cloudflared, ngrok, Caddy and the like add one of these headers). Every
  visitor through a proxy on this machine connects from this machine, so
  only these headers tell them from the person at it. A proxy that adds
  none of them cannot be told apart.
  """
  def forwarded?(%Plug.Conn{req_headers: headers}),
    do: Enum.any?(headers, fn {name, _} -> name in @proxy_headers end)

  def forwarded?(headers) when is_list(headers),
    do: Enum.any?(headers, fn {name, _} -> String.downcase(name) in @proxy_headers end)

  def forwarded?(_), do: false

  @doc """
  Who a live connection is, for `may_decide?/1`: whether it comes from this
  machine itself, and the device key its browser holds, if any. Only a
  connected socket knows where it comes from, so call this in `mount` once
  `connected?/1` is true.
  """
  def who(socket, session) do
    # A browser on this machine can be led to a page on someone else's
    # name that then points that name at this machine. That page connects
    # from here too. What gives it away is the name it asked for (see
    # `here?/2`).
    here? =
      case {Phoenix.LiveView.get_connect_info(socket, :peer_data),
            Phoenix.LiveView.get_connect_info(socket, :uri)} do
        {%{address: addr}, %URI{host: host}} -> here?(addr, host)
        _ -> false
      end

    # Through a proxy on this machine, everyone connects from here.
    proxied? =
      session["proxied"] == true or
        socket |> Phoenix.LiveView.get_connect_info(:x_headers) |> forwarded?()

    local? = here? and not proxied?

    %{local?: local?, device: session["device"]}
  end

  @doc """
  True when this connection may change settings or act on a mailbox item:
  someone at the hub's own machine, who opened the board by one of that
  machine's own names, and, when the board asks for approval, any device
  that was approved and has not been removed since. With approval off,
  everyone else on the network can look, and could otherwise approve a
  machine of their own.
  """
  def may_decide?(%{local?: true}), do: true

  def may_decide?(%{device: device}) when is_binary(device),
    do: Wallboard.Settings.get().approve_devices and Devices.approved?(device)

  def may_decide?(_), do: false

  @doc """
  True when a connection comes from this machine: from localhost, or from
  one of its own network addresses (opening the board by its network
  address, like http://192.168.1.20:4747, connects from that address).
  Another device cannot pass as one of these: it would never get the
  replies needed to finish connecting.
  """
  def this_machine?(addr), do: addr |> unmap() |> then(&(loopback?(&1) or &1 in own_addresses()))

  @doc """
  True when `host`, the name a browser asked for, is one this machine goes
  by: `localhost`, a plain network address, or its own host name (with or
  without `.local`). Any other name could belong to anyone.
  """
  def own_host?(host) when is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")
    {:ok, own} = :inet.gethostname()
    own = own |> to_string() |> String.downcase()
    bare = host |> String.trim_leading("[") |> String.trim_trailing("]")

    host in ["localhost", own, String.replace_suffix(own, ".local", ""), own <> ".local"] or
      match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(bare)))
  end

  def own_host?(_), do: false

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  # An IPv4 address seen through IPv6 (::ffff:192.168.1.20) is the IPv4 one.
  defp unmap({0, 0, 0, 0, 0, 65535, a, b}),
    do: {div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)}

  defp unmap(addr), do: addr

  defp own_addresses do
    case :inet.getifaddrs() do
      {:ok, ifs} -> for {_name, opts} <- ifs, {:addr, a} <- opts, do: a
      _ -> []
    end
  end
end
