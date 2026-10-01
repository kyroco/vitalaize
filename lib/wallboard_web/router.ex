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
    # Before Auth, so its "wrong token" page gets these headers too.
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
    plug WallboardWeb.Auth
    plug :protect_from_forgery
    plug :put_root_layout, html: {WallboardWeb.Layouts, :root}
  end

  # Other Macs sending Claude sessions. No cookies or forms here: each
  # request carries the ingest key itself.
  scope "/ingest", WallboardWeb do
    post "/transcript", IngestController, :transcript
    post "/status", IngestController, :status
    get "/install.sh", IngestController, :install
    get "/upload.sh", IngestController, :upload
    get "/codex-upload.sh", IngestController, :codex_upload
  end

  # A machine with no certificate yet asks for one here (see
  # Wallboard.Pairing). No cookies, no password: it has neither, and the
  # door's own limits and the owner's Approve are what guard it.
  scope "/pair", WallboardWeb do
    post "/start", PairController, :start
    post "/confirm", PairController, :confirm
    post "/wait", PairController, :wait
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
