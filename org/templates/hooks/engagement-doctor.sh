#!/usr/bin/env bash
# Block an agent stop when canonical finding state has drifted, a newly
# captured observation was never triaged, the compact session handoff was not
# refreshed, or the active session capture gate has no explicit outcome.
# Blockers return exit 2 so the agent gets a repair turn.

input="$(cat)"

# Claude sends stop_hook_active on a retry. Do not create an infinite stop loop.
if command -v jq >/dev/null 2>&1 &&
   [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    exit 0
fi

project_root="${CLAUDE_PROJECT_DIR:-/workspace}"
if [ ! -f "$project_root/db/ptctl.py" ]; then
    project_root="$(pwd)"
fi
tool="$project_root/db/ptctl.py"
[ -f "$tool" ] || exit 0

output="$(python3 "$tool" doctor --hook --quiet 2>&1)"
status=$?
if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    exit 2
fi

# Keep unresolved observations visible without blocking the stop.
if [ -n "$output" ]; then
    printf '%s\n' "$output" >&2
fi

handoff_output="$(python3 "$tool" session check 2>&1)"
handoff_status=$?
if [ "$handoff_status" -ne 0 ]; then
    printf '%s\n' "$handoff_output" >&2
    exit 2
fi
exit 0
