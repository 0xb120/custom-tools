#!/bin/bash
# Bring up the engagement devcontainer with BuildKit enabled.
#
# BuildKit is required by the build-time git clone (--mount=type=ssh) that
# pulls the private custom-tools repo via ssh-agent forwarding. The legacy
# docker build (DOCKER_BUILDKIT=0) doesn't understand --mount and errors out.
#
# Prerequisites on the host:
# - ssh-agent running with a GitHub-authorised key loaded (`ssh-add -l` to verify).
# - devcontainer CLI installed (`npm i -g @devcontainers/cli`).
#
# For VS Code's "Reopen in Container" workflow this wrapper is NOT in the loop —
# enable BuildKit in /etc/docker/daemon.json ({"features":{"buildkit":true}})
# and restart the docker daemon, OR export DOCKER_BUILDKIT=1 in your shell rc.

set -euo pipefail

# Run from the engagement root regardless of where the script was invoked from.
cd "$(dirname "$(readlink -f "$0")")/.."

if ! ssh-add -l >/dev/null 2>&1; then
    echo "[!] ssh-agent has no identities — the build-time git clone will fail." >&2
    echo "    Load a GitHub-authorised key first:" >&2
    echo "      eval \"\$(ssh-agent -s)\" && ssh-add ~/.ssh/id_ed25519   # or id_rsa" >&2
    exit 1
fi

export DOCKER_BUILDKIT=1
exec devcontainer up --workspace-folder .
