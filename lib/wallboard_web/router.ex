defmodule WallboardWeb.Router do
  use WallboardWeb, :router

  # Phoenix's default policy (framing and <base> limited to this board) plus
  # no plugins and no forms sent elsewhere. Scripts, styles, fonts and images
  # stay open: the page has inline theme styles and a script, and the font
  # stylesheet and logo can come from any address in settings.
  @csp "frame-ancestors 'self'; object-src 'none'; base-uri 'self'; form-action 'self'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_query_params
    # Before Auth, so its "approve this device" page gets these headers too.
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
    plug WallboardWeb.Auth
    plug :protect_from_forgery
    plug :put_root_layout, html: {WallboardWeb.Layouts, :root}
  end

  # Where the upload hooks of VitalAIze 0.2.0 sent sessions. Nothing is
  # taken here any more: every call is refused, and nothing is kept of it.
  # Kept in 0.4.0 too; #136 takes it out.
  scope "/ingest", WallboardWeb do
    match :*, "/*rest", OldCollectorController, :refuse
  end

  # A machine with no certificate yet asks for one here (see
  # Wallboard.Pairing). No cookies, no approval: it has neither, and the
  # door's own limits and the owner's Approve are what guard it. A paired
  # machine whose link keeps failing asks /check whether it was removed.
  scope "/pair", WallboardWeb do
    post "/start", PairController, :start
    post "/confirm", PairController, :confirm
    post "/wait", PairController, :wait
    post "/check", PairController, :check
  end

  scope "/", WallboardWeb do
    pipe_through :browser

    get "/brand/logo", AssetController, :logo
    get "/theme/fonts/:file", AssetController, :font

    live_session :board, on_mount: WallboardWeb.Auth do
      live "/", BoardLive
      live "/settings", SettingsLive
    end
  end
end
