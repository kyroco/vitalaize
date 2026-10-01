SCENARIOS+=(fresh-hub)
# A fresh Mac set up as hub and collector, then everything a person can do
# with it afterwards: the first screen, Settings, Reconfigure and Remove.
scenario_fresh_hub() {
  home hub 4981
  PORT2=4991
  mkdir -p "$H/OtherClaude" "$H/BoardFiles" "$H/.aws"
  printf '[profile acme-dev-read]\nregion = us-east-1\n[profile acme-prod-read]\nregion = us-east-1\n' >"$H/.aws/config"

  drive hub-wizard
  check "after the wizard the board answers on its port" answers "$PORT"
  check "after the wizard the login item runs" item_running "$LABEL"
  check "the wizard's board name is in use" setting_is brand.name "Acme"
  check "the wizard's repositories are in use" setting_is github.repos "kyroco/vitalaize
acme/rockets"
  check "a workflow left at None is none, not a made-up name" setting_is github.dev_deploy ""

  drive hub-status
  check "a new port saved in Settings is where the board answers" answers "$PORT2"
  check "the old port no longer answers" no_answer "$PORT"
  check "the name saved in Settings is in use" setting_is brand.name "Acme Two"

  drive hub-reconfigure
  check "after Reconfigure the board answers" answers "$PORT2"
  check "the name typed in Reconfigure is in use" setting_is brand.name "Acme Three"
  check "a setting the wizard does not ask about is still as saved" setting_is rotate_seconds "45"
  check "Reconfigure's Send as is in use" setting_is alerts.via "iMessage"
  python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["choices"], open(sys.argv[2], "w"))' "$DATA/install.json" "$H/again.json"

  drive hub-remove
  check "after Remove the login item is gone" item_gone "$LABEL"
  check "after Remove nothing answers on the port" no_answer "$PORT2"
  check "Remove kept the database" test -f "$DATA/wallboard.db"
  check "Remove kept the settings" test -f "$DATA/settings.exs"
  check "Remove took the setup record away" test ! -f "$DATA/install.json"
  check "Remove kept a copy of the setup record" ls "$DATA"/backups/*/install.json
  check "Remove kept a copy of the login item" ls "$DATA"/backups/*/"$LABEL.plist"

  app --install "$H/again.json" >"$OUT/install-again.log" 2>&1
  check "set up again from the command line" answers "$PORT2"
  drive hub-remove-all
  check "after Remove with delete the login item is gone" item_gone "$LABEL"
  check "after Remove with delete the data folder is gone" test ! -d "$DATA"
}
