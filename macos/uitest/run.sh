#!/bin/bash
# Uses every screen of the Mac app the way a person does, and checks what
# happened. Run it after any change to macos/Wallboard.
#
#   macos/uitest/run.sh                 every scenario
#   macos/uitest/run.sh fresh-hub pair  only these
#   macos/uitest/run.sh --list          name the scenarios
#   macos/uitest/run.sh --keep ...      leave the throwaway boards running after
#
# It builds the board and a test copy of the app (the app's own sources plus
# macos/uitest/Driver.swift), opens the real window, and clicks through the
# step files in macos/uitest/steps. Each scenario gets a throwaway home
# folder, its own login item name and its own port, so nothing of yours is
# read or changed: not your settings, your login item, your board or your
# Claude folders. The test window does show on your screen while it runs;
# it takes no keyboard focus.
#
# What comes out, under macos/build/uitest/out/SCENARIO: one picture a
# screen (NAME.png), the controls on it (NAME.txt), and results.txt with a
# line a step. The script ends with every failed line, and exits 1 on any.
#
# Needs: Xcode's command line tools, Elixir and Erlang, node (to press
# Approve in the hub's mailbox), sqlite3. Apple silicon only, as the app is.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/macos/uitest"
WORK="${VITALAIZE_UITEST_WORK:-$ROOT/macos/build/uitest}"
BOARD="$WORK/board"
APP="$WORK/VitalAIze-uitest"
LABEL_BASE="ai.kyroco.wallboard.uitest"
KEEP=0
FAILS="$WORK/failed.txt"

# Optional: a file that puts a pinned Elixir and Erlang on PATH (see build.sh).
if [ -n "${VITALAIZE_TOOLCHAIN:-}" ] && [ -f "$VITALAIZE_TOOLCHAIN" ]; then
  # shellcheck disable=SC1090
  . "$VITALAIZE_TOOLCHAIN"
fi

# --- building ---------------------------------------------------------------

build() {
  mkdir -p "$WORK"
  if [ ! -x "$BOARD/bin/wallboard" ] || [ -n "${VITALAIZE_UITEST_REBUILD:-}" ] ||
    [ -n "$(find "$ROOT/lib" "$ROOT/config" "$ROOT/rel" "$ROOT/priv" "$ROOT/mix.exs" "$ROOT/mix.lock" -newer "$BOARD/bin/wallboard" -type f 2>/dev/null | head -1)" ]; then
    echo "==> Building the board"
    (cd "$ROOT" && MIX_ENV=prod mix deps.get --only prod >/dev/null &&
      MIX_ENV=prod mix release --overwrite --path "$BOARD" >/dev/null) || {
      echo "The board did not build." >&2
      exit 2
    }
  fi
  echo "==> Building the test copy of the app"
  xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 -O -D UITEST \
    "$ROOT"/macos/Wallboard/*.swift "$HERE/Driver.swift" -o "$APP" || {
    echo "The app did not build." >&2
    exit 2
  }
}

# --- one throwaway Mac ------------------------------------------------------

# home NAME PORT [DATA FOLDER NAME]: a fresh home folder, and the
# environment that points the app at it.
home() {
  NAME="$1"
  PORT="$2"
  H="$WORK/homes/$NAME"
  LABEL="$LABEL_BASE.$NAME"
  DATA="$H/Library/Application Support/${3:-VitalAIze}"
  OUT="$WORK/out/${SCENARIO}"
  stop_item "$LABEL"
  [ -d "$H" ] && chflags -R nouchg "$H" 2>/dev/null
  rm -rf "$H"
  mkdir -p "$H/.claude/projects" "$OUT"
  export CFFIXED_USER_HOME="$H" WALLBOARD_LABEL="$LABEL" VITALAIZE_DATA="$DATA" VITALAIZE_RELEASE="$BOARD"
  LABELS+=("$LABEL")
  if curl -s --max-time 2 -o /dev/null "http://localhost:$PORT/"; then
    echo "Something already answers on port $PORT. Stop it first." >&2
    exit 2
  fi
}

# use NAME PORT [DATA FOLDER NAME]: go back to a home made earlier.
use() {
  NAME="$1"
  PORT="$2"
  H="$WORK/homes/$NAME"
  LABEL="$LABEL_BASE.$NAME"
  DATA="$H/Library/Application Support/${3:-VitalAIze}"
  export CFFIXED_USER_HOME="$H" WALLBOARD_LABEL="$LABEL" VITALAIZE_DATA="$DATA" VITALAIZE_RELEASE="$BOARD"
}

stop_item() { launchctl bootout "gui/$(id -u)/$1" 2>/dev/null; return 0; }

LABELS=()
cleanup() {
  [ "$KEEP" = 1 ] && return
  for label in "${LABELS[@]+"${LABELS[@]}"}"; do stop_item "$label"; done
}
trap cleanup EXIT

# The app's own command line, in the current throwaway home.
app() { "$APP" "$@"; }

# drive STEPS: opens the window and clicks through steps/STEPS.txt. Words
# in braces in a step file are filled in here.
drive() {
  local steps="$OUT/$1.steps"
  sed -e "s|{PORT}|$PORT|g" -e "s|{HOME}|$H|g" -e "s|{DATA}|$DATA|g" -e "s|{HUB}|${HUB:-}|g" "$HERE/steps/$1.txt" >"$steps"
  VITALAIZE_UITEST="$steps" VITALAIZE_UITEST_OUT="$OUT" "$APP" >"$OUT/$1.log" 2>&1
  local status=$?
  if [ -f "$OUT/results.txt" ]; then
    mv "$OUT/results.txt" "$OUT/$1.results.txt"
    grep -q "^FAIL" "$OUT/$1.results.txt" && sed -n "s|^FAIL|$SCENARIO/$1|p" "$OUT/$1.results.txt" >>"$FAILS"
    echo "    $1: $(grep -c "^ok" "$OUT/$1.results.txt") steps passed, $(grep -c "^FAIL" "$OUT/$1.results.txt") failed"
  else
    echo "$SCENARIO/$1	the app ended (status $status) before the steps were done; see $OUT/$1.log" >>"$FAILS"
    echo "    $1: the app ended before the steps were done"
  fi
}

# check "what it shows" COMMAND...: a check outside the window.
check() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok  	$what" >>"$OUT/checks.txt"
  else
    echo "FAIL	$what" >>"$OUT/checks.txt"
    echo "$SCENARIO	check: $what" >>"$FAILS"
    echo "    FAILED check: $what"
  fi
}

answers() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$1/")" = 200 ]; }
no_answer() { ! answers "$1"; }
item_running() { launchctl print "gui/$(id -u)/$1" 2>/dev/null | grep -q "state = running"; }
item_gone() { ! launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1; }
# setting KEY: the value the board uses now, as the app's Settings shows it.
setting() {
  app --settings | python3 -c '
import json, sys
doc = json.load(sys.stdin)
for section in doc["sections"]:
    for field in section["fields"]:
        if field["key"] == sys.argv[1]:
            print(field["value"])' "$1"
}
setting_is() { [ "$(setting "$1")" = "$2" ]; }

# --- scenarios ----------------------------------------------------------------

SCENARIOS=()
for file in "$HERE"/scenarios/*.sh; do
  # shellcheck disable=SC1090
  . "$file"
done

# --- the run ------------------------------------------------------------------

WANTED=()
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --list)
      printf '%s\n' "${SCENARIOS[@]}"
      exit 0
      ;;
    *) WANTED+=("$arg") ;;
  esac
done
[ ${#WANTED[@]} -eq 0 ] && WANTED=("${SCENARIOS[@]}")

build
mkdir -p "$WORK/out"
: >"$FAILS"
for SCENARIO in "${WANTED[@]}"; do
  if ! declare -F "scenario_${SCENARIO//-/_}" >/dev/null; then
    echo "No scenario named $SCENARIO. Try --list." >&2
    exit 2
  fi
  echo "==> $SCENARIO"
  rm -rf "$WORK/out/$SCENARIO"
  "scenario_${SCENARIO//-/_}"
  cleanup
  LABELS=()
done

echo
if [ -s "$FAILS" ]; then
  echo "FAILED:"
  cat "$FAILS"
  exit 1
fi
echo "Every step passed. Pictures and lists are in $WORK/out."
