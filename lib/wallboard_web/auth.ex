defmodule WallboardWeb.Auth do
  @moduledoc """
  The token is optional. With no token in settings, anyone on the network
  can open the board. With one, the first visit needs ?token=<token> in the
  address; after that the browser's cookie is enough.
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

  defp deny(conn, status, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
    |> halt()
  end
end
