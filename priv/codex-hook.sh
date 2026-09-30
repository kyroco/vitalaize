#!/bin/sh
# VitalAIze's Codex hook. VitalAIze keeps a copy at ~/.codex/vitalaize/hook.sh,
# and Codex runs it from ~/.codex/hooks.json (see the README).
#
# Codex hands a hook one JSON object on stdin. This keeps the latest one for
# each session, as <session id>.json next to this script, and for each helper
# agent working in it (whose calls carry agent_id) as
# <session id>.<agent id>.json, so a helper never replaces the session's own.
# The board reads those: an approval request, or a turn that ended on a
# question, shows the session as needing you until the next hook call.
#
# It prints nothing and always exits 0, so it can never hold Codex up.

dir=$(dirname "$0")
tmp=$(mktemp "$dir/.hook.XXXXXX") || exit 0
cat > "$tmp"

# The first value of a key, limited to letters, digits, - and _. JSON strings
# cannot hold a raw line break, so joining the lines is safe. Codex writes
# its own fields before a tool's arguments, so the first one found is its.
first() {
  tr -d '\n\r' < "$tmp" | grep -o "\"$1\" *: *\"[0-9A-Za-z_-]*\"" | head -n 1 |
    sed 's/.*"\([0-9A-Za-z_-]*\)"$/\1/'
}

id=$(first session_id)
agent=$(first agent_id)

if [ -n "$id" ] && [ -n "$agent" ]; then
  mv -f "$tmp" "$dir/$id.$agent.json"
elif [ -n "$id" ]; then
  mv -f "$tmp" "$dir/$id.json"
else
  rm -f "$tmp"
fi

exit 0
