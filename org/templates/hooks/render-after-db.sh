#!/usr/bin/env bash
# PostToolUse(Bash) hook — keep the rendered Markdown tables in <activity>.md in
# sync with db/engagement.db. AGENTS.md requires `bash db/render.sh` after every
# INSERT/UPDATE; this hook runs it automatically so the index never drifts.
#
# Fires only when the command that just ran actually mutated the engagement DB
# (INSERT / UPDATE / DELETE / REPLACE against engagement.db). A SELECT, or any
# unrelated command, is a no-op.
#
# Exit 0 on success / nothing-to-do. Exit 2 (with a reason on stderr) only when
# render.sh fails, so Claude is told the rendered tables are now STALE.

INPUT="$(cat)"

command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0

# Gate: must touch engagement.db AND carry a mutating keyword. Over-matching
# (e.g. a SELECT mentioning a column called "update") only costs one extra,
# idempotent render — acceptable.
printf '%s' "$cmd" | grep -Eiq 'engagement\.db'              || exit 0
printf '%s' "$cmd" | grep -Eiq '\b(insert|update|delete|replace)\b' || exit 0

cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
root="${CLAUDE_PROJECT_DIR:-${cwd:-/workspace}}"
render="$root/db/render.sh"

[ -f "$render" ] || exit 0

if ! out="$(bash "$render" 2>&1)"; then
    {
        echo "db/render.sh failed after a DB write — the asset/credential/findings"
        echo "tables in <activity>.md are now STALE. Fix the error and re-run"
        echo "'bash db/render.sh' before relying on the rendered index:"
        echo "$out"
    } >&2
    exit 2
fi
exit 0
