import Config

config :wallboard, WallboardWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: WallboardWeb.ErrorHTML], layout: false],
  pubsub_server: Wallboard.PubSub,
  live_view: [signing_salt: "wallboard-lv"]

config :phoenix, :json_library, Jason
config :logger, :default_formatter, format: "$time [$level] $message\n"

import_config "#{config_env()}.exs"
