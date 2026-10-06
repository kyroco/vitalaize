import Config

# Tests never start the pollers or the web server; they exercise the parsing
# and change detection directly against saved command output.
config :wallboard, start_board: false
config :logger, level: :warning

# Setup takes old upload hooks out of Claude's and Codex's settings files.
# In tests it may only edit files under the temp folder, so no test can
# ever change the real ~/.claude or ~/.codex of whoever runs them.
config :wallboard, old_hooks_within: System.tmp_dir!()

# Keys typed in go to a stand-in held in memory, never a real keychain
# (see Wallboard.KeyStore).
config :wallboard, key_store: Wallboard.KeyStore.Memory
