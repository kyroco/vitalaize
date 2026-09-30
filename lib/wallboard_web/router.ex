defmodule WallboardWeb.Router do
  use WallboardWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_query_params
    plug WallboardWeb.Auth
    plug :protect_from_forgery
    plug :put_root_layout, html: {WallboardWeb.Layouts, :root}
    plug :put_secure_browser_headers
  end

  # Other machines connecting and sending sessions. No cookies or forms
  # here: each request is signed (see Wallboard.Archive.MachineKeys).
  scope "/ingest", WallboardWeb do
    post "/connect", IngestController, :connect
    post "/transcript", IngestController, :transcript
    post "/status", IngestController, :status
    get "/install.sh", IngestController, :install
    get "/upload.sh", IngestController, :upload
    get "/codex-upload.sh", IngestController, :codex_upload
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
