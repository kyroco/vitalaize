#!/bin/sh
# Unpacks a Linux download, starts the board from it and checks that the page
# answers, then stops it. CI runs this on every download it builds, so a
# download that cannot start never reaches a release.
#
#   scripts/check-release.sh vitalaize-0.3.0-linux-x86_64.tar.gz
#
# It uses a scratch home folder, so it reads and writes nothing of yours, and
# a port of its own (4799, or $PORT), so a board you already run is not the
# one that answers.
set -eu

TARBALL=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
PORT=${PORT:-4799}
WORK=$(mktemp -d)
ROOT="$WORK/vitalaize"

stop() {
  HOME="$WORK/home" "$ROOT/bin/wallboard" stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap stop EXIT

tar -xzf "$TARBALL" -C "$WORK"
[ -x "$ROOT/bin/wallboard" ] || { echo "No vitalaize/bin/wallboard in $1" >&2; exit 1; }
mkdir -p "$WORK/home"

# The example settings, as a new user starts from, on this check's own port.
# No announcing on the network: this board is gone in a few seconds.
cat > "$WORK/settings.exs" <<EOF
{settings, _} = Code.eval_file("$ROOT/settings.example.exs")
settings |> Map.put(:port, $PORT) |> put_in([:archive, :advertise], false)
EOF

HOME="$WORK/home" WALLBOARD_SETTINGS="$WORK/settings.exs" "$ROOT/bin/wallboard" daemon

# The first start compiles nothing but can take a few seconds to open the
# port. Give it 60.
i=0
until code=$(curl -s -o "$WORK/page.html" -w '%{http_code}' "http://127.0.0.1:$PORT/") &&
  [ "$code" = 200 ]; do
  i=$((i + 1))
  if [ "$i" -ge 60 ]; then
    echo "The board did not answer on port $PORT within 60 seconds (last status: ${code:-none})." >&2
    exit 1
  fi
  sleep 1
done

grep -q 'phx-' "$WORK/page.html" || { echo "Port $PORT answered, but not with the board's page." >&2; exit 1; }
echo "The board started from $(basename "$1") and answered on port $PORT."
