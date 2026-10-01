SCENARIOS+=(kept-folder)
# A first setup on a Mac with nothing set up, where the person picks a
# folder that holds an older board's settings and database: a port saved
# in its settings, a name its own settings page kept in the database, and
# a setting the setup does not ask about.
scenario_kept_folder() {
  home kept 4995
  PORT2=4996
  # The older board kept its files in a folder of the person's choosing.
  DATA="$H/BoardKept"
  export VITALAIZE_DATA="$DATA"
  setup_by_command "$PORT" "Acme"
  save_settings "{\"port\": \"$PORT2\", \"rotate_seconds\": \"45\"}"
  check "the board answers on the port saved in Settings" wait_until 90 answers "$PORT2"
  sqlite3 "$DATA/wallboard.db" "create table uitest_marker(x); insert into uitest_marker values('history');"
  sqlite3 "$DATA/wallboard.db" "insert or replace into meta(key, value) values('settings_overrides', '{\"brand\":{\"name\":\"Acme Page\"}}');"
  app --uninstall >"$OUT/kept-uninstall.log" 2>&1
  check "nothing is set up any more" item_gone "$LABEL"

  # The app finds its folder by itself here, as on a real Mac: the folder
  # is the one picked in the setup.
  unset VITALAIZE_DATA
  drive kept-wizard
  export VITALAIZE_DATA="$DATA"
  check "the board answers on the port that folder had saved" answers "$PORT2"
  check "the name typed wins over the one the older page saved" setting_is brand.name "Acme Typed"
  check "a setting the setup does not ask about is still as saved" setting_is rotate_seconds "45"
  check "the history is still in the database" test "$(sqlite3 "$DATA/wallboard.db" 'select x from uitest_marker')" = history
  drive hub-remove-all
}
