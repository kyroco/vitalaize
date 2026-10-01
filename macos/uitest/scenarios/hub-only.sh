SCENARIOS+=(hub-only)
# A fresh Mac set up as a hub only, then removed with its data.
scenario_hub_only() {
  home hubonly 4987
  drive hubonly-wizard
  check "the board answers" answers "$PORT"
  check "a hub-only Mac saves none of its own sessions" setting_is archive.collect_local "false"
  check "its settings file says hub" grep -q 'role: "hub"' "$DATA/settings.exs"
  drive hub-remove-all
  check "after Remove with delete the login item is gone" item_gone "$LABEL"
  check "after Remove with delete the data folder is gone" test ! -d "$DATA"
}
