#!/bin/bash
# Uses every screen of the Mac app the way a person does, and checks what
# happened. Run it after any change to macos/Wallboard.
#
#   macos/uitest/run.sh                 every scenario but the slow one
#   macos/uitest/run.sh --all           the slow one too (a pairing nobody
#                                       approves takes ten minutes to run out)
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

# The board's code looks for old upload hooks in the folders these name, on
# top of the throwaway home's. Unset, a run started from a shell that names
# your own Claude or Codex folder cannot reach it.
unset CLAUDE_CONFIG_DIR CODEX_HOME

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
  if [ ! -x "$BOARD/bin/wallboard" ] || [ ! -f "$WORK/board.built" ] || [ -n "${VITALAIZE_UITEST_REBUILD:-}" ] ||
    [ -n "$(find "$ROOT/lib" "$ROOT/config" "$ROOT/rel" "$ROOT/priv" "$ROOT/mix.exs" "$ROOT/mix.lock" -newer "$WORK/board.built" -type f 2>/dev/null | head -1)" ]; then
    echo "==> Building the board"
    (cd "$ROOT" && MIX_ENV=prod mix deps.get --only prod >/dev/null &&
      MIX_ENV=prod mix release --overwrite --path "$BOARD" >/dev/null) || {
      echo "The board did not build." >&2
      exit 2
    }
    # Its own mark: a scenario changes the date of the board's program.
    touch "$WORK/board.built"
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
  # A keychain of its own, empty and never locked: a key typed in the app
  # goes there, never into the keychain of whoever runs this.
  KEYCHAIN="$H/uitest.keychain-db"
  security create-keychain -p "" "$KEYCHAIN" && security unlock-keychain -p "" "$KEYCHAIN" &&
    security set-keychain-settings "$KEYCHAIN" || {
    echo "Could not make a throwaway keychain in $H." >&2
    exit 2
  }
  export CFFIXED_USER_HOME="$H" WALLBOARD_LABEL="$LABEL" VITALAIZE_DATA="$DATA" VITALAIZE_RELEASE="$BOARD"
  export VITALAIZE_KEYCHAIN="$KEYCHAIN"
  # Every throwaway Mac is this one computer, so each needs a name of its
  # own: a hub refuses a collector that carries the hub's name.
  export VITALAIZE_MACHINE="uitest-$NAME"
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
  KEYCHAIN="$H/uitest.keychain-db"
  export CFFIXED_USER_HOME="$H" WALLBOARD_LABEL="$LABEL" VITALAIZE_DATA="$DATA" VITALAIZE_RELEASE="$BOARD"
  export VITALAIZE_KEYCHAIN="$KEYCHAIN"
  export VITALAIZE_MACHINE="uitest-$NAME"
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
  drive_start "$1"
  drive_wait
}

# drive_start STEPS, then drive_wait: the same in two halves, for a
# scenario that has something to do outside the window while it is open
# (pressing Approve on the hub).
drive_start() {
  DRIVING="$1"
  local steps="$OUT/$1.steps"
  sed -e "s|{PORT}|$PORT|g" -e "s|{HOME}|$H|g" -e "s|{PORT2}|${PORT2:-}|g" -e "s|{DATA}|$DATA|g" -e "s|{HUB}|${HUB:-}|g" -e "s|{HUBPORT}|${HUB_PORT:-}|g" "$HERE/steps/$1.txt" >"$steps"
  rm -f "$OUT/results.txt"
  VITALAIZE_UITEST="$steps" VITALAIZE_UITEST_OUT="$OUT" "$APP" >"$OUT/$1.log" 2>&1 &
  DRIVER=$!
}

drive_wait() {
  set -- "$DRIVING"
  wait "$DRIVER"
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

# setup_by_command PORT NAME [key=value ...]: sets this throwaway home up
# with the app's own command line, for a scenario whose subject is what
# comes after the setup. Values are JSON, laid over what --detect finds.
setup_by_command() {
  app --detect >"$H/choices.json"
  python3 - "$H/choices.json" "$DATA" "$H" "$@" <<'PY'
import json, sys
path, data, home, port, name, *rest = sys.argv[1:]
c = json.load(open(path))
c.update(dataFolder=data, port=int(port), boardName=name, repo="acme/rockets", branch="main",
         role="hubAndCollector", claudeFolders=[home + "/.claude"], korium=False, codex=False,
         newRelic=False, phone="", devProfile="", prodProfile="",
         gateWorkflow="", devWorkflow="", prodWorkflow="", otherRepos=[])
for pair in rest:
    key, value = pair.split("=", 1)
    c[key] = json.loads(value)
json.dump(c, open(path, "w"), indent=2)
PY
  app --install "$H/choices.json" >"$OUT/$NAME-setup.log" 2>&1
}

# save_settings 'JSON': saves settings the way the app's Settings does,
# like save_settings '{"link.enabled": "true", "link.port": "4758"}'.
save_settings() {
  printf '{"values": %s}' "$1" >"$H/save.json"
  app --save "$H/save.json" >>"$OUT/$NAME-setup.log" 2>&1
}

# wait_until SECONDS COMMAND...: true once the command is, false when time is up.
wait_until() {
  local left="$1"
  shift
  while [ "$left" -gt 0 ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
    left=$((left - 1))
  done
  return 1
}

# The mailbox of the board on a port, as its owner uses it in a browser.
mailbox() { node "$HERE/mailbox.mjs" "$@"; }
mailbox_has_code() { [ -n "$(mailbox "$1" list 2>/dev/null)" ]; }

# A board with a password answers 401 until it is given.
answers() {
  case "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$1/")" in
    200 | 401) return 0 ;;
    *) return 1 ;;
  esac
}
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
# The key kept under NAME in this home's throwaway keychain.
kept_key() { security find-generic-password -s VitalAIze -a "$1" -w "$KEYCHAIN" 2>/dev/null; }
# True when TEXT is in no file of this home but its keychain, in none of the
# run's lists of what each screen showed, and in nothing the app printed.
# The script's own steps, and its line for each one, hold what it typed.
nowhere_else() {
  ! grep -rqaF --exclude='*.keychain-db' -- "$1" "$H" &&
    ! grep -rqaF --exclude='*.steps' --exclude='*results.txt' --exclude='*.log' -- "$1" "$OUT" &&
    ! cat "$OUT"/*.log 2>/dev/null | grep -aF -- "$1" | grep -qavE '^(ok|FAIL)[[:space:]]'
}

# --- scenarios ----------------------------------------------------------------

SCENARIOS=()
SLOW=()
for file in "$HERE"/scenarios/*.sh; do
  # shellcheck disable=SC1090
  . "$file"
done

# --- the run ------------------------------------------------------------------

WANTED=()
ALL=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --all) ALL=1 ;;
    --list)
      printf '%s\n' "${SCENARIOS[@]}"
      exit 0
      ;;
    *) WANTED+=("$arg") ;;
  esac
done
if [ ${#WANTED[@]} -eq 0 ]; then
  for name in "${SCENARIOS[@]}"; do
    case " ${SLOW[*]+"${SLOW[*]}"} " in
      *" $name "*) [ "$ALL" = 1 ] && WANTED+=("$name") ;;
      *) WANTED+=("$name") ;;
    esac
  done
fi

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
