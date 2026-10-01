#!/bin/sh
# Unpacks a Linux download, starts the board from it and checks that the page
# answers and that an upload from an old collector is refused, then stops
# it. Then it starts the same download as a collector and checks that it
# comes up and opens no port, and last answers `vitalaize setup` from a
# script and checks it saved, and took an old upload hook out of a made-up
# Claude folder. CI runs this on every
# download it builds, so a download that cannot start never reaches a
# release.
#
#   scripts/check-release.sh vitalaize-0.3.0-linux-x86_64.tar.gz
#
# The board runs with a scratch home folder and database and none of your
# environment, so it reads and writes nothing of yours, and on a port of its
# own (4799, or $CHECK_PORT), so a board you already run is not the one that
# answers. It runs without Erlang remote connections and is stopped by its
# process id, so it cannot reach any other board.
set -eu

PORT=${CHECK_PORT:-4799}
case $PORT in '' | *[!0-9]*)
  echo "CHECK_PORT must be a number." >&2
  exit 1
  ;;
esac

TARBALL=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
WORK=$(mktemp -d)
ROOT="$WORK/vitalaize"
BOARD=

stop() {
  if [ -n "$BOARD" ]; then
    kill "$BOARD" 2>/dev/null || true
    wait "$BOARD" 2>/dev/null || true
  fi
  rm -rf "$WORK" || true
}
trap stop EXIT
trap 'exit 130' INT TERM HUP

tar -xzf "$TARBALL" -C "$WORK"
[ -x "$ROOT/bin/wallboard" ] || {
  echo "No vitalaize/bin/wallboard in $1" >&2
  exit 1
}
mkdir -p "$WORK/home"

# Something already on the port would answer in the board's place.
if curl -s --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/"; then
  echo "Something already answers on port $PORT. Stop it, or set CHECK_PORT." >&2
  exit 1
fi

# The example settings, as a new user starts from, on this check's own port
# and database. No announcing on the network: this board is gone in seconds.
cat >"$WORK/settings.exs" <<EOF
{settings, _} = Code.eval_file("$ROOT/settings.example.exs")

settings
|> Map.put(:port, $PORT)
|> put_in([:archive, :advertise], false)
|> put_in([:archive, :path], "$WORK/wallboard.db")
EOF

env -i PATH="$PATH" HOME="$WORK/home" LANG=C.UTF-8 \
  WALLBOARD_SETTINGS="$WORK/settings.exs" RELEASE_DISTRIBUTION=none \
  "$ROOT/bin/wallboard" start >"$WORK/board.log" 2>&1 &
BOARD=$!

failed() {
  echo "$1" >&2
  echo "The board's output:" >&2
  tail -n 40 "$WORK/board.log" >&2
  exit 1
}

# Starting can take a few seconds. Give it 60, and each try 5.
i=0
until code=$(curl -s --max-time 5 -o "$WORK/page.html" -w '%{http_code}' "http://127.0.0.1:$PORT/") &&
  [ "$code" = 200 ]; do
  kill -0 "$BOARD" 2>/dev/null || failed "The board stopped before it answered."
  i=$((i + 1))
  [ "$i" -lt 60 ] || failed "The board did not answer on port $PORT within 60 tries (last status: $code)."
  sleep 1
done

grep -q 'phx-' "$WORK/page.html" || failed "Port $PORT answered, but not with the board's page."
kill -0 "$BOARD" 2>/dev/null || failed "Port $PORT answered, but the board this check started is not running."
grep -q "Running WallboardWeb.Endpoint .* at [^ ]*:$PORT " "$WORK/board.log" ||
  failed "Port $PORT answered, but the board this check started is not the one listening there."

# A download must keep Erlang remote connections off unless asked. The check
# turns them off itself, so it reads the download's own default here.
grep -q 'RELEASE_DISTRIBUTION:-none' "$ROOT"/releases/*/env.sh ||
  failed "The download's releases/*/env.sh does not turn Erlang remote connections off."
echo "The board started from $(basename "$1") and answered on port $PORT."

# A machine still on the upload hooks of 0.2.0 calls the board the old way.
# The board must refuse it in words, and keep nothing it sent.
code=$(curl -s --max-time 10 -o "$WORK/refusal.txt" -w '%{http_code}' -X POST \
  -H "Content-Type: application/gzip" \
  --data-binary "not a transcript" \
  "http://127.0.0.1:$PORT/ingest/transcript?machine=old-box&account=.claude") || code=none
[ "$code" = 410 ] || failed "An old upload call was answered $code, not refused with 410."
grep -q 'no longer takes uploads' "$WORK/refusal.txt" ||
  failed "An old upload call was refused without saying why."
[ ! -e "$WORK/inbox" ] || failed "An old upload call left files in $WORK/inbox."
echo "The board refused an upload from an old collector."

# The same download as a collector: it must come up, and nothing may answer
# on the port, since a collector runs no board.
kill "$BOARD" 2>/dev/null || true
wait "$BOARD" 2>/dev/null || true
BOARD=
i=0
while curl -s --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/"; do
  i=$((i + 1))
  [ "$i" -lt 30 ] || failed "The board still answers on port $PORT after it was stopped."
  sleep 1
done

env -i PATH="$PATH" HOME="$WORK/home" LANG=C.UTF-8 \
  WALLBOARD_SETTINGS="$WORK/settings.exs" WALLBOARD_ROLE=collector RELEASE_DISTRIBUTION=none \
  "$ROOT/bin/wallboard" start >"$WORK/board.log" 2>&1 &
BOARD=$!

i=0
until grep -q 'Collector is up' "$WORK/board.log"; do
  kill -0 "$BOARD" 2>/dev/null || failed "The collector stopped before it came up."
  i=$((i + 1))
  [ "$i" -lt 60 ] || failed "The collector did not come up within 60 seconds."
  sleep 1
done

# Long enough for a web server to have started, had one been asked for.
sleep 3
kill -0 "$BOARD" 2>/dev/null || failed "The collector came up and then stopped."
if curl -s --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/"; then
  failed "A collector must open no port, but something answers on port $PORT."
fi
if grep -q 'Running WallboardWeb.Endpoint' "$WORK/board.log"; then
  failed "A collector must not start the board's web server."
fi
echo "The collector started from $(basename "$1") and opened no port."

# vitalaize setup, answered by a script: keep the role, open the first
# section (Board), give the board a new name, keep the rest, save. Its
# answer must land in settings.json beside the settings file.
kill "$BOARD" 2>/dev/null || true
wait "$BOARD" 2>/dev/null || true
BOARD=
[ -x "$ROOT/bin/vitalaize" ] || failed "No vitalaize/bin/vitalaize in $1"

# The scratch home is a machine 0.2.0 connected: its Claude settings hold a
# hook of the owner's and VitalAIze's old upload hook. Setup must take the
# upload hook out, leave the owner's, and keep a copy of the file.
CLAUDE="$WORK/home/.claude"
mkdir -p "$CLAUDE"
cat >"$CLAUDE/settings.json" <<EOF
{
  "hooks": {
    "Stop": [
      {"hooks": [{"type": "command", "command": "/usr/bin/true"}]},
      {"hooks": [{"type": "command", "command": "$CLAUDE/wallboard-upload.sh", "async": true}]}
    ]
  }
}
EOF
printf '#!/bin/sh\ncurl http://127.0.0.1:%s/ingest/transcript\n' "$PORT" >"$CLAUDE/wallboard-upload.sh"

printf '\n1\nRelease check\n\n\n\n\n\n\n' |
  env -i PATH="$PATH" HOME="$WORK/home" LANG=C.UTF-8 \
    WALLBOARD_SETTINGS="$WORK/settings.exs" \
    "$ROOT/bin/vitalaize" setup >"$WORK/board.log" 2>&1 ||
  failed "vitalaize setup stopped with an error."
grep -q '"name": "Release check"' "$WORK/settings.json" 2>/dev/null ||
  failed "vitalaize setup did not save the board's name in settings.json."
echo "vitalaize setup from $(basename "$1") saved a setting from scripted answers."

if grep -q 'wallboard-upload' "$CLAUDE/settings.json" || [ -e "$CLAUDE/wallboard-upload.sh" ]; then
  failed "vitalaize setup left the old upload hook or its script in $CLAUDE."
fi
grep -q '"command": "/usr/bin/true"' "$CLAUDE/settings.json" ||
  failed "vitalaize setup took out a hook that was not VitalAIze's."
grep -q 'wallboard-upload' "$CLAUDE/settings.json.before-collector" 2>/dev/null ||
  failed "vitalaize setup kept no copy of the Claude settings it changed."
echo "vitalaize setup took the old upload hook out and left the other hook alone."
