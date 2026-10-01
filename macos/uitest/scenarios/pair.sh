SCENARIOS+=(pair)
# A hub that takes collectors, and a second Mac set up as a collector that
# pairs with it by code: Approve, then Refuse, from the hub's mailbox.
scenario_pair() {
  home pairhub 4982
  setup_by_command "$PORT" "Acme Hub"
  check "the board answers" wait_until 60 answers "$PORT"
  HUB="http://localhost:4982"
  HUB_PORT=4982
  HUB_HOME="$H" HUB_DATA="$DATA" HUB_LABEL="$LABEL"

  # The board does not take collectors yet.
  home col 4983
  drive collector-closed-hub
  check "the collector runs although the board would not pair" item_running "$LABEL"

  # Now it does.
  use pairhub 4982
  save_settings '{"link.enabled": "true", "link.port": "4758"}'
  sleep 4
  check "the hub answers" wait_until 60 answers "$HUB_PORT"

  home col 4983
  drive_start collector-wizard
  check "the hub's mailbox gets the request" wait_until 120 mailbox_has_code "$HUB_PORT"
  wait_until 30 test -f "$OUT/c05-code.txt"
  CODE=$(mailbox "$HUB_PORT" list | head -1)
  check "the code in the hub's mailbox is the one the app shows" grep -q "$CODE" "$OUT/c05-code.txt"
  check "Approve in the mailbox" mailbox "$HUB_PORT" approve "$CODE"
  drive_wait
  check "the collector's login item runs" item_running "$LABEL"
  check "the collector opened no board" no_answer "$PORT"
  check "the collector says it is sending to the hub" wait_until 60 grep -q "Collector: sending to the hub" "$H/Library/Logs/VitalAIze/board.log"
  check "the collector's link to the hub is up" wait_until 60 grep -q '"state":"up"' "$DATA/collector/link/state.json"

  drive_start collector-status
  check "the hub's mailbox gets the second request" wait_until 180 test -f "$OUT/c10-pair-again.txt"
  wait_until 30 mailbox_has_code "$HUB_PORT"
  CODE=$(mailbox "$HUB_PORT" list | head -1)
  check "the second code matches too" grep -q "$CODE" "$OUT/c10-pair-code.txt"
  check "Refuse in the mailbox" mailbox "$HUB_PORT" refuse "$CODE"
  drive_wait
  check "the collector still runs after a refused pairing" item_running "$LABEL"

  # Pair again, approved: the old certificate stops working on the hub the
  # moment the new one is given, so the collector must take up the new one.
  rm -f "$OUT/c11-again-code.txt"
  drive_start collector-pair-again
  check "the hub's mailbox gets the third request" wait_until 120 test -f "$OUT/c11-again-code.txt"
  wait_until 30 mailbox_has_code "$HUB_PORT"
  CODE=$(mailbox "$HUB_PORT" list | head -1)
  check "Approve the third code in the mailbox" mailbox "$HUB_PORT" approve "$CODE"
  drive_wait
  check "the collector took up the new certificate without a restart" grep -q "Collector: paired again" "$H/Library/Logs/VitalAIze/board.log"
  check "and its link to the hub is up" wait_until 60 grep -q '"state":"up"' "$DATA/collector/link/state.json"

  drive collector-reconfigure
  check "after Reconfigure the collector still runs" item_running "$LABEL"
  check "and its link to the hub is up again" wait_until 60 grep -q '"state":"up"' "$DATA/collector/link/state.json"

  drive collector-remove
  check "after Remove the collector's login item is gone" item_gone "$LABEL"
}
