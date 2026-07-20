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

# Advisory: warn (non-fatal) if the host-side Burp MCP endpoint isn't listening.
# Burp runs on the host with the "MCP Server" extension; with --network=host the
# in-container agent reaches it at this URL. If Burp is down the agent still
# launches, just without Burp tools — so this never blocks. `timeout` guards
# against the SSE stream hanging the probe; the `if !` keeps set -e happy.
burp_url="{{BURP_MCP_URL}}"
burp_hostport="${burp_url#*://}"; burp_hostport="${burp_hostport%%/*}"
burp_host="${burp_hostport%%:*}"; burp_port="${burp_hostport##*:}"
[ "$burp_host" = "$burp_port" ] && burp_port=80   # URL had no explicit :port
if ! timeout 2 bash -c ">/dev/tcp/$burp_host/$burp_port" 2>/dev/null; then
    echo "[!] Burp MCP endpoint $burp_url not reachable — start Burp + the 'MCP Server'" >&2
    echo "    extension on the host, or the agent launches without Burp tools." >&2
fi

export DOCKER_BUILDKIT=1
exec devcontainer up --workspace-folder .
