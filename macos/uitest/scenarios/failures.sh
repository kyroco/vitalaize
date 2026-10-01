SCENARIOS+=(failures)
# What a person sees when things go wrong: the board's port is taken, and
# a board that cannot start after its login item is mended. (A write that
# fails is in over-renamed; a refused or unanswered pairing is in pair.)
scenario_failures() {
  home fail 4988
  PORT2=4989

  # Another program holds the port the wizard is given.
  nc -lk 127.0.0.1 "$PORT" >/dev/null 2>&1 &
  BUSY=$!
  sleep 1
  drive fail-port
  kill "$BUSY" 2>/dev/null
  wait "$BUSY" 2>/dev/null
  check "the stopped setup wrote no settings file for the taken port" test "$(grep -c "port: $PORT," "$DATA/settings.exs" 2>/dev/null)" != 1
  check "with another port the board answers" answers "$PORT2"

  # The login item names an app that is gone, and the settings file is
  # not one the board can read.
  stop_item "$LABEL"
  sleep 2
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 /Applications/Gone.app/Contents/Resources/board/bin/wallboard" "$H/Library/LaunchAgents/$LABEL.plist"
  cp "$DATA/settings.exs" "$H/settings-before.exs"
  echo "this is not a settings file (" >"$DATA/settings.exs"
  drive fail-mend
  check "after Reconfigure the board answers again" answers "$PORT2"
  check "the settings file that could not be read is in the backup folder" grep -rq "this is not a settings file" "$DATA/backups"
}
