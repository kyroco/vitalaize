#!/bin/sh
# VitalAIze's Codex hook. VitalAIze keeps a copy at ~/.codex/vitalaize/hook.sh,
# and Codex runs it from ~/.codex/hooks.json (see the README).
#
# Codex hands a hook one JSON object on stdin. This keeps the latest one for
# each session, as <session id>.json next to this script, and the board reads
# those: an approval request, or a turn that ended on a question, shows the
# session as needing you until the next hook for it comes in.
#
# It prints nothing and always exits 0, so it can never hold Codex up.

dir=$(dirname "$0")
tmp=$(mktemp "$dir/.hook.XXXXXX") || exit 0
cat > "$tmp"

# JSON strings cannot hold a raw line break, so joining the lines is safe. The
# first session_id is the top-level one; a tool's own arguments come later.
id=$(tr -d '\n\r' < "$tmp" | grep -o '"session_id" *: *"[0-9A-Za-z-]*"' | head -n 1 |
  sed 's/.*"\([0-9A-Za-z-]*\)"$/\1/')

if [ -n "$id" ]; then
  mv -f "$tmp" "$dir/$id.json"
else
  rm -f "$tmp"
fi

exit 0
