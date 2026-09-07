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

usage() {
    cat >&2 <<EOF
Usage: $0 [--pull]

  --pull   Build against a freshly pulled base image instead of the local one.
           \`FROM <tag>\` resolves whatever the LOCAL tag points at, and docker
           never re-resolves it — so a base pulled months ago stays the base
           indefinitely. That matters here because both bases are moving tags
           (debian:trixie-slim gets rebuilt for security updates,
           kalilinux/kali-rolling moves continuously): a long-lived local copy
           means building on an outdated, sometimes broken, userland. This
           pulls the tag first; if the digest actually moved, \`FROM\` lands on
           a new layer and everything above it rebuilds (~30 min).

Related: to discard the build cache without touching the base image, call the
CLI directly — devcontainer up --workspace-folder . --build-no-cache
EOF
    exit 1
}

PULL=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --pull)    PULL=1; shift ;;
        -h|--help) usage ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage ;;
    esac
done

# Run from the engagement root regardless of where the script was invoked from.
cd "$(dirname "$(readlink -f "$0")")/.."

if ! ssh-add -l >/dev/null 2>&1; then
    echo "[!] ssh-agent has no identities — the build-time git clone will fail." >&2
    echo "    Load a GitHub-authorised key first:" >&2
    echo "      eval \"\$(ssh-agent -s)\" && ssh-add ~/.ssh/id_ed25519   # or id_rsa" >&2
    exit 1
fi

# Agent credentials. devcontainer.json mounts exactly two files from the host —
# the Claude and Codex tokens — and nothing else from ~/.claude / ~/.codex, so
# the engagement's plugins, marketplaces and MCP servers stay per-engagement.
# Those are --mount-style binds: docker aborts container creation if a source
# file does not exist, so check here and say what to do about it.
missing=()
[ -f "$HOME/.claude/.credentials.json" ] || missing+=("~/.claude/.credentials.json   run 'claude' on the host and log in")
[ -f "$HOME/.codex/auth.json" ]          || missing+=("~/.codex/auth.json            run 'codex login' on the host")
if [ "${#missing[@]}" -gt 0 ]; then
    echo "[!] host credential file(s) missing — the container mounts these read-only:" >&2
    printf '      %s\n' "${missing[@]}" >&2
    echo "    Log in on the host once, or delete that mount line from" >&2
    echo "    .devcontainer/devcontainer.json and log in inside the container instead." >&2
    exit 1
fi

# --pull: repoint the local base-image tag at the published one before building.
# There is no --pull on `devcontainer up`, and none is needed: `FROM <tag>` in
# the Dockerfile resolves the LOCAL tag, so pulling here is what decides which
# image the build starts from. If the digest is unchanged this is a no-op and
# every cached layer stays valid; if it moved, FROM becomes a new layer and the
# whole toolchain above it rebuilds.
base_image="{{BASE_IMAGE}}"
container_name="{{ACTIVITY_NAME}}"
if [ "$PULL" -eq 1 ]; then
    # `devcontainer up` reuses an existing container and skips the build
    # entirely (that is also why the CLI's own --build-no-cache is documented as
    # applying "if the container does not exist"). Pulling would then change
    # nothing, so say so rather than appearing to work.
    if docker container inspect "$container_name" >/dev/null 2>&1; then
        echo "[!] container '$container_name' already exists — devcontainer up will reuse it" >&2
        echo "    and skip the build, so --pull would have no effect. Remove it first:" >&2
        echo "      docker rm -f $container_name" >&2
        exit 1
    fi

    before="$(docker images --no-trunc --quiet "$base_image" 2>/dev/null || true)"
    echo "[+] Pulling $base_image ..."
    if ! docker pull "$base_image"; then
        echo "[!] pull of $base_image failed — refusing to silently build on the local copy." >&2
        echo "    Re-run without --pull to accept the image already on this host." >&2
        exit 1
    fi
    after="$(docker images --no-trunc --quiet "$base_image")"
    if [ "$before" = "$after" ]; then
        echo "[=] $base_image was already at the published digest — cached layers stay valid."
    elif [ -z "$before" ]; then
        echo "[+] $base_image pulled for the first time on this host — full build ahead."
    else
        echo "[+] $base_image moved (${before:7:12} -> ${after:7:12}) — the toolchain layer"
        echo "    rebuilds from scratch, so expect the long build (~30 min)."
    fi
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
