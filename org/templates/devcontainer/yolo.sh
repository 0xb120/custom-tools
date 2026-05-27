#!/bin/bash
# YOLO launcher: build/start the engagement devcontainer, then drop into an
# interactive Claude Code session with permission prompts disabled
# (--dangerously-skip-permissions).
#
# Why this is acceptable here: Claude runs as the non-root `pentester` user
# INSIDE a disposable container with the engagement folder bind-mounted at
# /workspace — not on your host. It still executes any command without asking,
# so only use this on engagements where unattended in-scope action is intended.
# (Claude refuses --dangerously-skip-permissions as root; the container user is
# non-root by design, so the flag is honoured.)
#
# This is just the two documented steps chained together:
#   bash .devcontainer/up.sh
#   devcontainer exec --workspace-folder . claude --dangerously-skip-permissions

set -euo pipefail

# Run from the engagement root regardless of the caller's cwd.
cd "$(dirname "$(readlink -f "$0")")"

# 1. Build + start (or reuse) the container. up.sh does the BuildKit and
#    ssh-agent preflight checks and exits non-zero if they fail.
bash .devcontainer/up.sh

# 2. Attach an interactive Claude session in YOLO mode.
exec devcontainer exec --workspace-folder . claude --dangerously-skip-permissions
