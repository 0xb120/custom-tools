#!/bin/bash
# YOLO launcher (Codex): build/start the engagement devcontainer, then drop
# into an interactive Codex session with approvals + sandbox disabled and the
# engagement's scaffolded hooks auto-trusted.
#
# Why this is acceptable: Codex runs as the non-root `pentester` user INSIDE a
# disposable container with the engagement bind-mounted at /workspace — not on
# your host. --dangerously-bypass-approvals-and-sandbox is intended precisely
# for externally-sandboxed environments like this container;
# --dangerously-bypass-hook-trust lets .codex/hooks run without the interactive
# one-time trust prompt. Only use on engagements where unattended in-scope
# action is intended.
#
# This is just the two documented steps chained together:
#   bash .devcontainer/up.sh
#   devcontainer exec --workspace-folder . codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust

set -euo pipefail

# Run from the engagement root regardless of the caller's cwd.
cd "$(dirname "$(readlink -f "$0")")"

# 1. Build + start (or reuse) the container. up.sh does the BuildKit and
#    ssh-agent preflight checks and exits non-zero if they fail.
bash .devcontainer/up.sh

# 2. Attach an interactive Codex session in YOLO mode.
exec devcontainer exec --workspace-folder . codex \
    --dangerously-bypass-approvals-and-sandbox \
    --dangerously-bypass-hook-trust
