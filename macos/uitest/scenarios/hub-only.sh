SCENARIOS+=(hub-only)
# A fresh Mac set up as a hub only, then removed with its data while the
# board's own code cannot be run.
scenario_hub_only() {
  home hubonly 4987
  drive hubonly-wizard
  check "the board answers" answers "$PORT"
  check "a hub-only Mac saves none of its own sessions" setting_is archive.collect_local "false"
  check "its settings file says hub" grep -q 'role: "hub"' "$DATA/settings.exs"
  # The board's own code fails when Remove asks it what it took out (and
  # only then: the first screen needs it), so the app alone has to say
  # what may be left.
  mv "$BOARD/bin/wallboard" "$BOARD/bin/wallboard.real"
  printf '#!/bin/sh\ncase "$VITALAIZE_ARGS" in "--json remove"*) exit 1 ;; esac\nexec "$0.real" "$@"\n' >"$BOARD/bin/wallboard"
  chmod +x "$BOARD/bin/wallboard"
  drive hub-remove-all
  mv -f "$BOARD/bin/wallboard.real" "$BOARD/bin/wallboard"
  check "after Remove with delete the login item is gone" item_gone "$LABEL"
  check "after Remove with delete the data folder is gone" test ! -d "$DATA"
  check "with the board's code out of reach, Remove says so" grep -q "Could not take out this Mac's certificate or look for old upload hooks" "$OUT/15-removed-all.txt"
  check "and that a New Relic key may still be in the keychain" grep -q "A New Relic API key kept in the keychain may still be there" "$OUT/15-removed-all.txt"
}
