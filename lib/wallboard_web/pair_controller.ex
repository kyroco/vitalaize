defmodule WallboardWeb.PairController do
  @moduledoc """
  The pairing door: the three calls a machine without a certificate makes
  to ask for one (see `Wallboard.Pairing`). They need no password and no
  key, since the machine has neither yet; what they may do is limited by
  `Wallboard.Pairing.Door`, and nothing they send is trusted until the
  owner approves a matching code in the mailbox.

  Each call is a small JSON body. Nothing else is accepted here.
  """

  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias Wallboard.Pairing
  alias Wallboard.Pairing.Door

  def start(conn, _params) do
    with {:ok, body, conn} <- read(conn),
         {:ok, opened} <- Door.start(from(conn), body) do
      json(conn, 200, %{
        id: opened.id,
        nonce: Base.encode16(opened.nonce, case: :lower),
        ca: opened.ca_pem,
        link_port: opened.link_port,
        expires_in: opened.expires_in,
        hub: hub_name()
      })
    else
      {:error, reason, conn} -> refuse(conn, reason)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def confirm(conn, _params) do
    with {:ok, %{"id" => id, "nonce" => nonce}, conn} when is_binary(id) and is_binary(nonce) <-
           read(conn),
         {:ok, nonce} <- Base.decode16(nonce, case: :mixed),
         :ok <- Door.confirm(from(conn), id, nonce) do
      json(conn, 200, %{ok: true})
    else
      {:error, reason, conn} -> refuse(conn, reason)
      {:error, reason} -> refuse(conn, reason)
      _ -> refuse(conn, :bad_request)
    end
  end

  def wait(conn, _params) do
    with {:ok, %{"id" => id}, conn} when is_binary(id) <- read(conn),
         {:ok, state} <- Door.status(from(conn), id) do
      case state do
        :waiting -> json(conn, 200, %{state: "waiting"})
        :refused -> json(conn, 200, %{state: "refused"})
        {:approved, cert} -> json(conn, 200, %{state: "approved", cert: cert})
      end
    else
      {:error, reason, conn} -> refuse(conn, reason)
      {:error, reason} -> refuse(conn, reason)
      _ -> refuse(conn, :bad_request)
    end
  end

  # The body, whole and small, as a JSON object. Anything longer is cut off
  # unread.
  defp read(conn) do
    case read_body(conn, length: Pairing.limits().max_body_bytes, read_timeout: 5_000) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, %{} = map} -> {:ok, map, conn}
          _ -> {:error, :bad_request, conn}
        end

      {:more, _, conn} ->
        {:error, :too_large, conn}

      {:error, _} ->
        {:error, :bad_request, conn}
    end
  end

  # Who is asking: the address the connection itself comes from. A header
  # could say anything.
  defp from(conn), do: conn.remote_ip

  defp hub_name do
    {:ok, host} = :inet.gethostname()
    host |> to_string() |> String.replace_suffix(".local", "")
  end

  defp refuse(conn, reason) do
    {status, word} =
      case reason do
        :busy -> {429, "busy"}
        :gone -> {404, "gone"}
        :bad_name -> {422, "bad_name"}
        :bad_key -> {422, "bad_key"}
        :too_large -> {413, "too_large"}
        # No door on this board: the link is off.
        :unavailable -> {404, "no_door"}
        _ -> {422, "bad_request"}
      end

    json(conn, status, %{error: word})
  end

  defp json(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
    |> halt()
  end
end
