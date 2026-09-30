#!/bin/sh
# Unpacks a Linux download, starts the board from it and checks that the page
# answers, then stops it. CI runs this on every download it builds, so a
# download that cannot start never reaches a release.
#
#   scripts/check-release.sh vitalaize-0.3.0-linux-x86_64.tar.gz
#
# The board runs with a scratch home folder and database and none of your
# environment, so it reads and writes nothing of yours, and on a port of its
# own (4799, or $PORT), so a board you already run is not the one that
# answers. It runs without Erlang remote connections and is stopped by its
# process id, so it cannot reach any other board.
set -eu

PORT=${PORT:-4799}
case $PORT in '' | *[!0-9]*)
  echo "PORT must be a number." >&2
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
echo "The board started from $(basename "$1") and answered on port $PORT."
