#!/bin/sh
# Keeps the board running on Linux: it starts when you log in and starts
# again if it ever stops. It sets up a systemd user service.
#
#   ./systemd.sh on     turn it on (and start it now)
#   ./systemd.sh off    turn it off (and stop it now)
#
# It works from the downloaded release (this script sits beside bin/) and
# from a source checkout (scripts/systemd.sh, after MIX_ENV=prod mix
# release). Either way it uses settings.exs from that folder.
#
# With role: "collector" in settings.exs the same service runs the
# collector: no board and no port, only the watcher for this machine's
# Claude and Codex sessions.
#
# To keep the board running after you log out, also run once:
#   loginctl enable-linger "$USER"
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
if [ -x "$HERE/bin/wallboard" ]; then
  REL="$HERE"
  ROOT="$HERE"
else
  ROOT=$(cd "$HERE/.." && pwd)
  REL="$ROOT/_build/prod/rel/wallboard"
fi
# The board's process shows its folder with symlinks resolved, so resolve
# them here too, or a board in a linked folder is never found to stop.
[ -d "$REL" ] && REL=$(cd "$REL" && pwd -P)
SETTINGS="$ROOT/settings.exs"
NAME=vitalaize
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="$UNIT_DIR/$NAME.service"

case "$1" in
  on)
    [ -x "$REL/bin/wallboard" ] || { echo "Build the release first: MIX_ENV=prod mix release"; exit 1; }
    [ -f "$SETTINGS" ] || { echo "No settings.exs in $ROOT. Copy settings.example.exs and fill it in."; exit 1; }
    command -v systemctl >/dev/null 2>&1 || { echo "This needs systemd (systemctl)."; exit 1; }

    # A board started by hand holds the port, so stop any board running from
    # this folder first. It is found by its process, since boards run without
    # Erlang remote connections and so cannot be asked to stop.
    for pid in $(pgrep -f 'bin/beam' || true); do
      case "$(ps -o args= -p "$pid")" in
        "$REL"/erts-*/bin/beam*) kill "$pid" 2>/dev/null || true ;;
      esac
    done
    sleep 2

    mkdir -p "$UNIT_DIR"
    cat > "$UNIT" <<EOF
[Unit]
Description=VitalAIze
After=network-online.target

[Service]
ExecStart=$REL/bin/wallboard start
WorkingDirectory=$ROOT
Environment=WALLBOARD_SETTINGS=$SETTINGS
Environment=RELEASE_DISTRIBUTION=none
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    # Restart rather than start: the loop above may have stopped this service's
    # own board, which systemd does not bring back after a clean stop.
    systemctl --user enable "$NAME.service"
    systemctl --user restart "$NAME.service"
    echo "VitalAIze is on, and will start whenever you log in."
    echo "Its log: journalctl --user -u $NAME -f"
    ;;
  off)
    systemctl --user disable --now "$NAME.service" >/dev/null 2>&1 || true
    rm -f "$UNIT"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    echo "VitalAIze is off and will not start at login."
    ;;
  *)
    echo "Usage: $0 on|off"
    exit 1
    ;;
esac
