import Config

# Tests never start the pollers or the web server; they exercise the parsing
# and change detection directly against saved command output.
config :wallboard, start_board: false
config :logger, level: :warning
