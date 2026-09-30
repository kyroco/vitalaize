#!/bin/sh
# Keeps the board running: it starts when you log in to this Mac and starts
# again if it ever stops.
#
#   scripts/login-item.sh on     turn it on (and start it now)
#   scripts/login-item.sh off    turn it off (and stop it now)
#
# It runs the release in _build/prod/rel/wallboard with settings.exs from
# this folder. Run it from your own Terminal: at startup the board reads the
# New Relic key through your 1Password session.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REL="$ROOT/_build/prod/rel/wallboard"
SETTINGS="$ROOT/settings.exs"
LABEL=local.wallboard
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/wallboard.log"
DOMAIN="gui/$(id -u)"

case "$1" in
  on)
    [ -x "$REL/bin/wallboard" ] || { echo "Build the release first: MIX_ENV=prod mix release"; exit 1; }
    [ -f "$SETTINGS" ] || { echo "No settings.exs in $ROOT. Copy settings.example.exs and fill it in."; exit 1; }

    # A board started by hand holds the port, so stop any board running from
    # this folder first. It is found by its process, since boards run without
    # Erlang remote connections and so cannot be asked to stop.
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    for pid in $(pgrep -f 'bin/beam' || true); do
      case "$(ps -o args= -p "$pid")" in
        "$REL"/erts-*/bin/beam*) kill "$pid" 2>/dev/null || true ;;
      esac
    done
    sleep 2

    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$REL/bin/wallboard</string>
    <string>start</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>WALLBOARD_SETTINGS</key><string>$SETTINGS</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "The board is on, and will start whenever you log in."
    echo "Its log: $LOG"
    echo "To turn it off: scripts/login-item.sh off"
    ;;

  off)
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    echo "The board is off and will not start at login."
    ;;

  *)
    echo "Usage: scripts/login-item.sh on|off"
    exit 1
    ;;
esac
