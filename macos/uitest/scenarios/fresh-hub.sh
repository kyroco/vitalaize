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
  check "the New Relic key typed in the wizard is in the keychain" test "$(kept_key new_relic)" = NRAK-UITEST0WIZARD0KEY00000001
  check "the board read it from there" wait_until 30 grep -q "New Relic key loaded into memory from the keychain" "$H/Library/Logs/VitalAIze/board.log"
  check "and it is in no file, list or log of the run" nowhere_else NRAK-UITEST0WIZARD0KEY00000001

  drive hub-status
  check "a new port saved in Settings is where the board answers" answers "$PORT2"
  check "the old port no longer answers" no_answer "$PORT"
  check "the name saved in Settings is in use" setting_is brand.name "Acme Two"

  drive hub-reconfigure
  check "after Reconfigure the board answers" answers "$PORT2"
  check "the name typed in Reconfigure is in use" setting_is brand.name "Acme Three"
  check "a setting the wizard does not ask about is still as saved" setting_is rotate_seconds "45"
  check "Reconfigure's Send as is in use" setting_is alerts.via "iMessage"
  check "Reconfigure with the key field left empty keeps the key" test "$(kept_key new_relic)" = NRAK-UITEST0WIZARD0KEY00000001

  drive hub-settings-all
  check "the time zone saved in Settings is in use" setting_is timezone "America/Chicago"
  check "the ntfy server too" setting_is alerts.ntfy_server "http://localhost:9"
  check "the region too" setting_is new_relic.region "eu"
  check "the New Relic key typed in Settings is in the keychain" test "$(kept_key new_relic)" = NRAK-UITEST0SETTINGS0KEY000001
  check "and shows as set, not as itself" setting_is new_relic.api_key "••••••••"
  check "and is in no file, picture or list of the run" nowhere_else NRAK-UITEST0SETTINGS0KEY000001
  check "its 1Password address is saved beside it" setting_is new_relic.api_key_ref "op://Private/Acme/key"
  check "the hub takes collectors" setting_is link.enabled "true"
  check "on the port typed" setting_is link.port "4761"
  check "the repositories too" setting_is github.repos "acme/rockets"
  check "the main branch too" setting_is github.branch "trunk"
  check "the board still answers" answers "$PORT2"
  check "and asks for its password" test "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$PORT2/")" = 401
  check "and opens with it" test "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$PORT2/?token=acme-secret")" = 200
  check "the saved settings as they were are in the backup folder" ls "$DATA"/backups/*/settings.json

  sqlite3 "$DATA/wallboard.db" "create table uitest_marker(x); insert into uitest_marker values('history');"
  drive hub-remove
  check "after Remove the login item is gone" item_gone "$LABEL"
  check "after Remove nothing answers on the port" no_answer "$PORT2"
  check "Remove kept the database" test -f "$DATA/wallboard.db"
  check "Remove kept the settings" test -f "$DATA/settings.exs"
  check "Remove took the setup record away" test ! -f "$DATA/install.json"
  check "Remove kept a copy of the setup record" ls "$DATA"/backups/*/install.json
  check "Remove kept a copy of the login item" ls "$DATA"/backups/*/"$LABEL.plist"
  check "Remove kept the New Relic key, as its screen said" test "$(kept_key new_relic)" = NRAK-UITEST0SETTINGS0KEY000001

  drive hub-again
  check "set up again, the board answers" answers "$PORT2"
  check "the name typed in the new setup is in use" setting_is brand.name "Acme Again"
  check "a setting saved before Remove is still in use" setting_is timezone "America/Chicago"
  check "the New Relic key saved before Remove is still kept" test "$(kept_key new_relic)" = NRAK-UITEST0SETTINGS0KEY000001
  check "one the setup asks about and was left alone, too" setting_is github.branch "trunk"
  check "the history from before Remove is still in the database" test "$(sqlite3 "$DATA/wallboard.db" 'select x from uitest_marker')" = history
  drive hub-remove-all
  check "after Remove with delete the login item is gone" item_gone "$LABEL"
  check "after Remove with delete the data folder is gone" test ! -d "$DATA"
  check "and the New Relic key is out of the keychain" test -z "$(kept_key new_relic)"
}
