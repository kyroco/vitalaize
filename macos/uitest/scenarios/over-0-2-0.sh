SCENARIOS+=(over-0-2-0)
# The new app installed over 0.2.0. The app sits at the same path, so the
# login item is right, but the board that is running is still the old
# one, started before the new files were put in place; its settings file
# is in 0.2.0's form, and 0.2.0's upload hook is in Claude's settings.
scenario_over_0_2_0() {
  home v020 4986
  setup_by_command "$PORT" "Acme"
  save_settings '{"rotate_seconds": "45"}'

  # The settings file as 0.2.0 wrote it: no role, and the older header.
  cat >"$DATA/settings.exs" <<EOF
# Written by the VitalAIze app. Change the board from its settings page
# (Settings, top right of the Claude sessions panel), or run the app
# again and pick Reconfigure. Edits here are kept until the next
# Reconfigure.
%{
    port: $PORT,
    brand: %{name: "Acme"},
    claude: %{config_dirs: ["$H/.claude"]},
    github: %{repo: "acme/rockets", branch: "main", deploy_workflows: [], lanes: []},
    korium: %{enabled: false},
    codex: %{enabled: false},
    new_relic: %{enabled: false, account_id: nil, api_key_ref: nil},
    dev_power: %{aws_profile: nil},
    builds: %{prod_profile: nil},
    alerts: %{phone: nil, via: "iMessage"},
    archive: %{
      path: "$DATA/wallboard.db",
      collect_local: true
    }
  }
EOF
  # Its setup record, without what later versions added.
  python3 - "$DATA/install.json" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
for key in ("otherRepos", "importedRepos", "settingsRead"):
    record["choices"].pop(key, None)
json.dump(record, open(sys.argv[1], "w"), indent=2)
PY
  sqlite3 "$DATA/wallboard.db" "create table uitest_marker(x); insert into uitest_marker values('history');"

  # The old board, running from that file since before the upgrade.
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1
  check "the 0.2.0 settings file starts the board" wait_until 90 answers "$PORT"
  OLD_PID=$(launchctl print "gui/$(id -u)/$LABEL" | sed -n 's/^[[:space:]]*pid = //p' | head -1)
  # The upgrade: the installer puts the new files in place, which is when
  # the board's program was last changed.
  sleep 2
  touch "$BOARD/bin/wallboard"

  drive v020-open
  NEW_PID=$(launchctl print "gui/$(id -u)/$LABEL" | sed -n 's/^[[:space:]]*pid = //p' | head -1)
  check "the board was restarted (a new process runs it)" test -n "$NEW_PID" -a "$OLD_PID" != "$NEW_PID"
  check "after the restart the board answers" answers "$PORT"
  check "the history is still in the database" test "$(sqlite3 "$DATA/wallboard.db" 'select x from uitest_marker')" = history
  check "what was saved in Settings is still in use" setting_is rotate_seconds "45"
  check "the board's name from the 0.2.0 file is still in use" setting_is brand.name "Acme"

  # Its steps check that opening the app again restarts nothing.
  drive v020-again
  check "Reconfigure over the 0.2.0 files ends with the board answering" answers "$PORT"
  check "Reconfigure wrote the settings file in the new form" grep -q 'role: "both"' "$DATA/settings.exs"
  check "the 0.2.0 settings file is in the backup folder" ls "$DATA"/backups/*/settings.exs
}
