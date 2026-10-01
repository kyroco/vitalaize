SCENARIOS+=(over-renamed)
# The new app opened over an install from before the app was renamed: its
# data is in "Vitalize", its login item starts an app that is gone, its
# settings file loads a carried-over copy that is gone, and its setup
# record names an earlier settings file that is gone. Then the same with
# the copy still there, and a Reconfigure whose write fails.

# aged_install NAME PORT [keep-copy]: such an install, in a throwaway home.
aged_install() {
  home "$1" "$2" Vitalize
  mkdir -p "$H/projects/wallboard"
  # One thing the wizard does not ask about, to see whether it is carried over.
  echo "%{port: $PORT, brand: %{name: \"Acme\"}, github: %{repo: \"acme/rockets\", branch: \"main\"}, rotate_seconds: 45, timezone: \"America/Chicago\"}" \
    >"$H/projects/wallboard/settings.exs"
  setup_by_command "$PORT" "Acme" "importedSettings=\"$H/projects/wallboard/settings.exs\""
  save_settings '{"brand.name": "Acme Saved"}'
  sqlite3 "$DATA/wallboard.db" "create table uitest_marker(x); insert into uitest_marker values('history');"

  # Age it: the older app, and both settings files it leaned on, go away.
  stop_item "$LABEL"
  sleep 2
  PLIST="$H/Library/LaunchAgents/$LABEL.plist"
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 /Applications/Vitalize-gone.app/Contents/Resources/board/bin/wallboard" "$PLIST"
  # The older app wrote the settings file with the function's older name.
  sed -i '' 's/Wallboard.Settings.apply_overrides(/Wallboard.Settings.merge(/' "$DATA/settings.exs"
  rm -rf "$H/projects/wallboard"
  [ "${3:-}" = keep-copy ] || rm -f "$DATA/settings.imported.exs"
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null
  sleep 2
}

history_kept() { [ "$(sqlite3 "$DATA/wallboard.db" 'select x from uitest_marker')" = history ]; }
launchd_cannot_start() { launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "last exit code = 78"; }
sums() { shasum "$DATA/settings.exs" "$DATA/install.json" "$DATA/settings.json" "$H/Library/LaunchAgents/$LABEL.plist"; }

scenario_over_renamed() {
  aged_install aged 4984
  check "before the app opens, launchd cannot start the board" launchd_cannot_start
  check "before the app opens, nothing answers" no_answer "$PORT"
  drive aged-open
  check "after the app opened, the board answers" answers "$PORT"
  check "the login item runs the board from this app" item_running "$LABEL"
  check "the history is still in the database" history_kept
  check "what was saved in Settings is still in use" setting_is brand.name "Acme Saved"
  check "the settings file as it was is in the backup folder" ls "$DATA"/backups/*/settings.exs
  check "the login item as it was is in the backup folder" ls "$DATA"/backups/*/"$LABEL.plist"

  drive aged-reconfigure
  check "after Reconfigure the board answers" answers "$PORT"
  check "the history is still there after Reconfigure" history_kept
  check "Reconfigure kept the name saved in Settings" setting_is brand.name "Acme Saved"

  # A write that fails: the data folder cannot be written to.
  before=$(sums)
  chmod 555 "$DATA"
  drive aged-write-fails
  chmod 755 "$DATA"
  check "a failed write left all four files as they were" test "$before" = "$(sums)"
  check "the board still answers after the failed write" answers "$PORT"

  aged_install aged2 4985 keep-copy
  drive aged-open-copy
  check "with the copy kept, the board answers" answers "$PORT"
  check "what the earlier file held beyond the wizard is still in use" setting_is timezone "America/Chicago"
  check "and its page turning too" setting_is rotate_seconds "45"
  check "the history is still in the database" history_kept
}
