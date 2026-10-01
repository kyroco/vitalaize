defmodule WallboardWeb.Auth do
  @moduledoc """
  The token is optional. With no token in settings, anyone on the network
  can open the board. With one, the first visit needs ?token=<token> in the
  address; after that the browser's cookie is enough.

  Looking at the board and deciding things on it are two different rights.
  Changing settings, or acting on a mailbox item, is for the owner: see
  `may_decide?/1`.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Wallboard.Settings.get().token do
      nil ->
        conn

      token ->
        given = conn.params["token"]

        cond do
          is_binary(given) and Plug.Crypto.secure_compare(given, token) ->
            put_session(conn, :token_hash, hash(token))

          get_session(conn, :token_hash) == hash(token) ->
            conn

          true ->
            deny(
              conn,
              401,
              "Add ?token= and the token from settings.exs to the end of the address."
            )
        end
    end
  end

  # The live connection needs the same proof as the page.
  def on_mount(:default, _params, session, socket) do
    case Wallboard.Settings.get().token do
      nil ->
        {:cont, socket}

      token ->
        if session["token_hash"] == hash(token),
          do: {:cont, socket},
          else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  def hash(token), do: :crypto.hash(:sha256, "wallboard-token:" <> token) |> Base.encode16()

  @doc """
  Who a live connection is, for `may_decide?/1`: whether it comes from this
  machine itself, and the proof of the board password its browser holds.
  Only a connected socket knows where it comes from, so call this in
  `mount` once `connected?/1` is true.
  """
  def who(socket, session) do
    local? =
      case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
        %{address: addr} -> this_machine?(addr)
        _ -> false
      end

    %{local?: local?, token_hash: session["token_hash"]}
  end

  @doc """
  True when this connection may change settings or act on a mailbox item.

  With a board password set, that is anyone whose browser has given it,
  and nobody else, checked against the password as it is now. With none,
  only someone at the hub's own machine: everyone else on the network can
  look, and could otherwise approve a machine of their own.
  """
  def may_decide?(%{local?: local?} = who) do
    case Wallboard.Settings.get().token do
      nil ->
        local? == true

      token ->
        is_binary(who[:token_hash]) and Plug.Crypto.secure_compare(who.token_hash, hash(token))
    end
  end

  def may_decide?(_), do: false

  @doc """
  True when a connection comes from this machine: from localhost, or from
  one of its own network addresses (opening the board by its network
  address, like http://192.168.1.20:4747, connects from that address).
  Another device cannot pass as one of these: it would never get the
  replies needed to finish connecting.
  """
  def this_machine?(addr), do: addr |> unmap() |> then(&(loopback?(&1) or &1 in own_addresses()))

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

  defp deny(conn, status, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
    |> halt()
  end
end
