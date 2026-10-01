SCENARIOS+=(pair-timeout)
SLOW+=(pair-timeout)
# A pairing nobody approves. It takes the ten minutes a code lasts, so it
# runs only when named or with --all.
scenario_pair_timeout() {
  home timehub 4990
  setup_by_command "$PORT" "Acme Hub"
  save_settings '{"link.enabled": "true", "link.port": "4759"}'
  sleep 4
  check "the hub answers" wait_until 60 answers "$PORT"
  HUB="http://localhost:4990"

  home timecol 4993
  drive collector-timeout
  check "the collector runs although it is not paired" item_running "$LABEL"
  check "nothing was saved as a pairing" test ! -f "$DATA/collector/link/cert.pem"
}
