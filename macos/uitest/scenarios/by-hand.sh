SCENARIOS+=(by-hand)
# A fresh install on a Mac where a board was started by hand before: the
# wizard carries its settings over and takes its login item away, keeping
# a copy. The by-hand board itself is not started here: its label,
# local.wallboard, is the same for every home on this computer.
scenario_by_hand() {
  home byhand 4994
  # Stopping the by-hand board asks launchd by its label, which is the
  # same in every home: on a computer that really runs one, leave it be.
  if launchctl print "gui/$(id -u)/local.wallboard" >/dev/null 2>&1; then
    echo "    skipped: this computer runs a board started by hand (local.wallboard)"
    return
  fi
  mkdir -p "$H/projects/wallboard" "$H/Library/LaunchAgents"
  echo "%{port: 4747, brand: %{name: \"Acme By Hand\"}, github: %{repo: \"acme/rockets\", branch: \"main\"}, rotate_seconds: 45, timezone: \"America/Chicago\"}" \
    >"$H/projects/wallboard/settings.exs"
  cat >"$H/Library/LaunchAgents/local.wallboard.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.wallboard</string>
  <key>EnvironmentVariables</key><dict>
    <key>WALLBOARD_SETTINGS</key><string>$H/projects/wallboard/settings.exs</string>
  </dict>
</dict></plist>
EOF

  drive byhand-wizard
  check "the board answers" answers "$PORT"
  check "what the earlier file held beyond the wizard is in use" setting_is timezone "America/Chicago"
  check "and its page turning too" setting_is rotate_seconds "45"
  check "the by-hand login item is gone" test ! -f "$H/Library/LaunchAgents/local.wallboard.plist"
  check "a copy of it is in the backup folder" ls "$DATA"/backups/*/local.wallboard.plist
  check "the earlier settings file is still where it was" test -f "$H/projects/wallboard/settings.exs"
  drive hub-remove-all
}
