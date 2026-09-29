defmodule WallboardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :wallboard

  # The cookie only remembers that this browser once came with the right
  # token, so the iPad keeps working after Safari drops the ?token= part.
  @session_options [
    store: :cookie,
    key: "_wallboard",
    signing_salt: "wallboard-session",
    same_site: "Lax",
    max_age: 60 * 60 * 24 * 365
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, session: @session_options]],
    longpoll: false

  # Files asked for without a ?v= fingerprint are checked with the server on
  # every load, so an update is never hidden behind a cached copy.
  plug Plug.Static,
    at: "/",
    from: :wallboard,
    only: ~w(css js fonts images),
    cache_control_for_etags: "no-cache"

  plug Plug.Static, at: "/vendor", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/vendor",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug Plug.Head
  plug Plug.Session, @session_options
  plug WallboardWeb.Router
end
