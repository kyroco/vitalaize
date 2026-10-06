#!/bin/bash
# Checks what the package's postinstall does to a board that is running when
# a new VitalAIze is installed over it. Run it after any change to
# macos/installer/scripts/postinstall.
#
#   macos/installer/check-postinstall.sh BOARD
#
# BOARD is a built board, the folder `MIX_ENV=prod mix release --path BOARD`
# makes. The check puts a copy of it in a throwaway "Applications" folder as
# VitalAIze.app, starts it under a login item of its own
# (ai.kyroco.wallboard.postinstall-check) on a port of its own (4798, or
# $CHECK_PORT), puts a fresh copy in its place the way the installer does, and
# runs the postinstall on it as you, as a command-line install would (so the
# app is not opened). Then it checks:
#
#   - the running board was restarted, from the new files, and answers with
#     its style sheet;
#   - a login item that is loaded but not running stays stopped;
#   - a login item that is not loaded stays that way;
#   - a running one whose program is in another copy of the app is left alone.
#
# Your own board's login item is never named, so it is not read or restarted.
# What it cannot check is the postinstall running as root under the real
# Installer; installing a real package does that.
set -uo pipefail

[ $# -eq 1 ] && [ -x "$1/bin/wallboard" ] || {
  echo "Usage: $0 BOARD, a folder made by mix release with bin/wallboard in it." >&2
  exit 1
}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOARD="$(cd "$1" && pwd)"
PORT=${CHECK_PORT:-4798}
LABEL=ai.kyroco.wallboard.postinstall-check
DOMAIN="gui/$(id -u)"
WORK=$(mktemp -d)
APPS="$WORK/Applications"
APP="$APPS/VitalAIze.app"
PLIST="$WORK/$LABEL.plist"
FAILED=0

stop() {
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -rf "$WORK" || true
}
trap stop EXIT
trap 'exit 130' INT TERM HUP

if curl -s --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/"; then
  echo "Something already answers on port $PORT. Stop it, or set CHECK_PORT." >&2
  exit 1
fi

# The postinstall as shipped (or $POSTINSTALL, to check another copy), with
# only the login item's name changed to this check's.
sed "s/^label=ai\.kyroco\.wallboard\$/label=$LABEL/" "${POSTINSTALL:-$ROOT/macos/installer/scripts/postinstall}" >"$WORK/postinstall"
grep -q "^label=$LABEL\$" "$WORK/postinstall" || {
  echo "Could not find the line label=ai.kyroco.wallboard in the postinstall." >&2
  exit 1
}

check() {
  local what="$1"
  shift
  if "$@"; then
    echo "ok    $what"
  else
    echo "FAIL  $what"
    FAILED=1
  fi
}

# The installer's arguments: the package, the folder it installed into, the
# disk, and the startup disk.
postinstall() {
  COMMAND_LINE_INSTALL=1 /bin/sh "$WORK/postinstall" "$WORK/VitalAIze.pkg" "$APPS" / /
}

pid() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*pid = //p' | head -1; }
running() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q '^[[:space:]]*state = running$'; }
loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }
css() { [ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/css/app.css")" = 200 ]; }
answers() { curl -s --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/"; }
wait_until() {
  local seconds="$1"
  shift
  local i=0
  until "$@"; do
    i=$((i + 1))
    [ "$i" -lt "$seconds" ] || return 1
    sleep 1
  done
}

# login_item PROGRAM KEEP_RUNNING: loads the login item, the way the app
# writes it (macos/Wallboard/Setup.swift), running PROGRAM.
login_item() {
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  wait_until 10 not loaded
  python3 - "$PLIST" "$LABEL" "$1" "$2" "$WORK" <<'PY'
import os, plistlib, sys
path, label, program, keep, work = sys.argv[1:]
keep = keep == "yes"
plistlib.dump({
    "Label": label,
    "ProgramArguments": [program, "start"],
    "EnvironmentVariables": {
        "WALLBOARD_SETTINGS": work + "/settings.exs",
        "RELEASE_TMP": work + "/tmp",
        "RELEASE_DISTRIBUTION": "none",
        "PATH": os.environ["PATH"],
        "HOME": work + "/home",
    },
    "WorkingDirectory": work,
    "RunAtLoad": keep,
    "KeepAlive": keep,
    "ThrottleInterval": 30,
    "StandardOutPath": work + "/board.log",
    "StandardErrorPath": work + "/board.log",
}, open(path, "wb"))
PY
  launchctl bootstrap "$DOMAIN" "$PLIST"
}

not() { ! "$@"; }
loaded_and_stopped() { loaded && ! running; }
restarted() {
  local now
  now=$(pid)
  [ -n "$now" ] && [ "$now" != "$OLD" ]
}

# The installer puts a new copy of the app in place of the old one.
install_app() {
  rm -rf "$APP"
  mkdir -p "$APP/Contents/Resources"
  ditto "$BOARD" "$APP/Contents/Resources/board"
}

mkdir -p "$WORK/home" "$WORK/tmp"
cat >"$WORK/settings.exs" <<EOF
{settings, _} = Code.eval_file("$ROOT/settings.example.exs")

settings
|> Map.put(:port, $PORT)
|> put_in([:archive, :advertise], false)
|> put_in([:archive, :path], "$WORK/wallboard.db")
EOF

echo "==> A board running from the app when a new one is installed over it"
install_app
login_item "$APP/Contents/Resources/board/bin/wallboard" yes
check "the board starts and answers with its style sheet" wait_until 90 css
OLD=$(pid)
sleep 2
install_app
PLACED=$(date +%s)
check "installing alone does not restart it (the same process runs)" test "$(pid)" = "$OLD"
postinstall
check "the postinstall ends with a new process running the board" wait_until 60 restarted
NEW=$(pid)
# The new process's age, from ps's [[days-]hours:]minutes:seconds.
AGE=$(ps -o etime= -p "${NEW:-0}" | awk -F'[-:]' '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }')
check "the new process started after the new files were put in place" test "${AGE:-99999}" -le "$(($(date +%s) - PLACED))"
check "the board answers with its style sheet after the restart" wait_until 90 css

echo "==> A board set up but not running"
login_item "$APP/Contents/Resources/board/bin/wallboard" no
check "it is loaded and not running before the install" loaded_and_stopped
install_app
postinstall
sleep 5
check "the postinstall leaves it stopped" not running
check "nothing answers on its port" not answers

echo "==> No board set up"
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
wait_until 10 not loaded
postinstall
sleep 2
check "the postinstall sets up nothing" not loaded

echo "==> A board running from another copy of the app"
OTHER="$WORK/Elsewhere/VitalAIze.app/Contents/Resources/board/bin"
mkdir -p "$OTHER"
printf '#!/bin/sh\nexec /bin/sleep 600\n' >"$OTHER/wallboard"
chmod +x "$OTHER/wallboard"
login_item "$OTHER/wallboard" yes
check "it runs before the install" wait_until 10 running
OLD=$(pid)
install_app
postinstall
sleep 3
check "the postinstall leaves it running as it was (the same process)" test "$(pid)" = "$OLD"

echo
if [ "$FAILED" = 0 ]; then
  echo "Every check passed."
else
  echo "Some checks failed. The board's log:"
  tail -n 40 "$WORK/board.log" 2>/dev/null
  exit 1
fi
