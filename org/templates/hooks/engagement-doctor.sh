#!/usr/bin/env bash
# Stop hook — report engagement drift and hand over the review queue. Never
# blocks.
#
# This hook used to exit 2 on untriaged observations, missing HTTP-request
# evidence, and a stale session handoff, forcing a repair turn. All three
# checks were engagement-global with no notion of who did what, so with more
# than one agent session open they fired on each other's in-flight work: the
# session that happened to stop first was blocked by whatever the others were
# still holding. Concurrency is the normal case here, so the checks report and
# the operator decides.
#
# Untriaged observations are no longer reported as drift at all. An agent
# cannot truthfully declare an open-ended exploration finished, so it is never
# asked to close one: stopping with observations awaiting a decision is the
# normal end of a session, and what the hook prints is the queue the operator
# inherits, not a defect list.
#
# The gate that still blocks is `ptctl.py doctor --strict`, run deliberately at
# reporting freeze, where an open cleanup obligation or a missing reference is
# genuinely a defect rather than someone else's work in progress.

input="$(cat)"

# Claude sends stop_hook_active on a retry. Nothing here blocks, but skip the
# duplicate report.
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

output="$(python3 "$tool" doctor --quiet 2>&1)"
if [ -n "$output" ]; then
    printf '%s\n' "$output" >&2
fi

# What this session is handing to the operator. Silent when the queue is empty.
queue="$(python3 "$tool" inbox --quiet --limit 10 2>&1)"
if [ -n "$queue" ]; then
    printf '%s\n' "$queue" >&2
fi
exit 0
