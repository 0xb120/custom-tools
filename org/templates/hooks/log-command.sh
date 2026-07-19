#!/usr/bin/env bash
# PreToolUse(Bash) hook — append every shell command Claude runs to an
# engagement-level audit log, for traceability of the offensive activity.
#
# CONTRACT: this hook must NEVER block a command. It always exits 0, even on
# error — a logging failure must not stop the engagement.
#
# Record format (grep records by the '## ' header):
#   ## <UTC timestamp>  cwd=<dir>
#   <command, verbatim, possibly multi-line>
#
# Log path: <engagement-root>/logs/commands.log. The log is git-ignored
# (commands routinely embed secrets: `sshpass -p ...`, `curl -H "Authorization:
# ..."`, spray passwords, …) — never commit it.

INPUT="$(cat)"

# No jq → cannot parse the hook payload. Skip silently (only 'none' docs-only
# engagements lack jq, and those run no commands worth logging).
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
[ -z "$cmd" ] && exit 0

cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
root="${CLAUDE_PROJECT_DIR:-${cwd:-/workspace}}"
ts="$(date -u +%FT%TZ)"

log_dir="$root/logs"
mkdir -p "$log_dir" 2>/dev/null || exit 0
{
    printf '## %s  cwd=%s\n' "$ts" "${cwd:-?}"
    printf '%s\n\n' "$cmd"
} >> "$log_dir/commands.log" 2>/dev/null

exit 0
