#!/bin/bash
set -eo pipefail

# Install the agent plugins an engagement declares, and nothing else.
#
# The engagement container mounts only the agents' credential files from the
# host, so it starts with no plugins and no marketplaces (see
# templates/devcontainer/devcontainer.json). Each engagement instead declares
# its own set in its project settings file:
#
#   .claude/settings.json
#     "extraKnownMarketplaces": { "<name>": { "source": {...} } }
#     "enabledPlugins":         { "<plugin>@<name>": true }
#
# That file is the single source of truth. It is what Claude Code itself reads,
# and it is also what `claude plugin install --scope project` writes, so editing
# it by hand and using the CLI converge on the same place. newPT.sh seeds it
# from the engagement type; you add or remove rows by hand afterwards.
#
# Declaring is NOT enough on its own: a declared-but-uninstalled plugin gets its
# cache materialised but does not load (its skills never reach the session).
# `claude plugin install` is the step that records it and makes it live — that is
# what this script does, idempotently, for every declared entry.
#
# Run by postCreateCommand at container creation, and by hand after editing the
# list:
#
#   bash ~/custom-tools/org/sync-agent-plugins.sh /workspace
#   bash ~/custom-tools/org/sync-agent-plugins.sh /workspace --dry-run
#
# Restart the agent afterwards — plugins are loaded at session start.

usage() {
    cat >&2 <<EOF
Usage: $0 [<engagement_dir>] [--dry-run] [--claude-only|--codex-only]

  <engagement_dir>  Engagement root holding .claude/settings.json (default: cwd).

  --dry-run      Print the plan without touching anything.
  --claude-only  Skip the Codex pass.
  --codex-only   Skip the Claude pass.

Reads "extraKnownMarketplaces" and "enabledPlugins" from
<engagement_dir>/.claude/settings.json, registers the marketplaces, installs
every plugin whose value is not false, then verifies the result. Safe to re-run.

Claude plugins install at PROJECT scope, so the install is recorded in the
engagement's own settings file. Codex has no project scope for plugins (same as
its MCP servers), so its plugins land in the container-global ~/.codex — which
is per-engagement anyway, the container being disposable.
EOF
    exit 1
}

DIR=""
DRY_RUN=0
DO_CLAUDE=1
DO_CODEX=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)     DRY_RUN=1; shift ;;
        --claude-only) DO_CODEX=0; shift ;;
        --codex-only)  DO_CLAUDE=0; shift ;;
        -h|--help)     usage ;;
        -*) echo "ERROR: unknown flag: $1" >&2; usage ;;
        *)
            [ -z "$DIR" ] || { echo "ERROR: unexpected extra argument: $1" >&2; usage; }
            DIR="$1"; shift ;;
    esac
done
DIR="${DIR:-$PWD}"

SETTINGS="$DIR/.claude/settings.json"
if [ ! -f "$SETTINGS" ]; then
    echo "ERROR: no settings file at $SETTINGS" >&2
    echo "       pass the engagement root, or run this from inside it." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required to read $SETTINGS" >&2
    echo "       it ships with the 'base' install group; a --groups=none" >&2
    echo "       workspace has no toolchain, so install it or skip this step." >&2
    exit 1
fi

# The marketplace clone defaults to git@github.com, and there is no ssh-agent
# inside the container (--ssh=default is build-time only, for the custom-tools
# clone). Over HTTPS a public marketplace needs no credentials at all.
export CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1

# name<TAB>source — source is whatever `plugin marketplace add` accepts: a
# GitHub owner/repo, an HTTPS URL, or a local path.
MARKETPLACES="$(jq -r '
    (.extraKnownMarketplaces // {}) | to_entries[]
    | "\(.key)\t\(.value.source.repo // .value.source.url // .value.source.path // "")"
' "$SETTINGS")"

# Every entry that is not explicitly false. Besides `true`, the setting accepts
# an object form carrying a version constraint, which counts as enabled too.
PLUGINS="$(jq -r '
    (.enabledPlugins // {}) | to_entries[]
    | select(.value != false and .value != null) | .key
' "$SETTINGS")"

if [ -z "$PLUGINS" ]; then
    echo "[=] no plugins declared in $SETTINGS — nothing to install."
    echo "    Add them under \"enabledPlugins\" (plus their \"extraKnownMarketplaces\")."
    exit 0
fi

echo "[+] engagement: $DIR"
echo "    marketplaces: $(echo "$MARKETPLACES" | cut -f1 | xargs)"
echo "    plugins:      $(echo "$PLUGINS" | xargs)"
[ "$DRY_RUN" -eq 1 ] && echo "    (dry run — no commands will be executed)"

# Run from the engagement root: --scope project resolves the settings file from
# the working directory.
cd "$DIR"

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    would run: $*"
        return 0
    fi
    "$@"
}

# Same, but swallowing the command's own output. Redirecting at the call site
# instead would also swallow the dry-run plan.
run_quiet() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    would run: $*"
        return 0
    fi
    "$@" >/dev/null 2>&1
}

# --- Claude Code ------------------------------------------------------------
if [ "$DO_CLAUDE" -eq 1 ]; then
    if ! command -v claude >/dev/null 2>&1; then
        echo "[!] claude not in PATH — skipping the Claude pass." >&2
        DO_CLAUDE=0
    fi
fi
if [ "$DO_CLAUDE" -eq 1 ]; then
    echo "[+] Claude Code"
    while IFS=$'\t' read -r name source; do
        [ -n "$name" ] || continue
        if [ -z "$source" ]; then
            echo "    [!] marketplace '$name' declares no repo/url/path — skipping" >&2
            continue
        fi
        # Idempotent: re-adding a known marketplace reports "already on disk".
        run claude plugin marketplace add "$source" --scope project || \
            echo "    [!] marketplace add failed: $name ($source)" >&2
    done <<< "$MARKETPLACES"

    while IFS= read -r plugin; do
        [ -n "$plugin" ] || continue
        # Keep going when one entry fails (a typo in the id, or a marketplace
        # that does not carry it): the remaining plugins still install and the
        # verification pass below reports the whole picture at once, instead of
        # `set -e` killing the run on the first bad row.
        run claude plugin install "$plugin" --scope project -y || \
            echo "    [!] install failed: $plugin" >&2
    done <<< "$PLUGINS"
fi

# --- Codex ------------------------------------------------------------------
# Best effort: Codex plugin support is newer and its marketplace names are
# derived independently, so a failure here warns and never fails the run.
if [ "$DO_CODEX" -eq 1 ]; then
    if ! command -v codex >/dev/null 2>&1; then
        echo "[=] codex not in PATH — skipping the Codex pass."
        DO_CODEX=0
    fi
fi
if [ "$DO_CODEX" -eq 1 ]; then
    echo "[+] Codex"
    while IFS=$'\t' read -r name source; do
        [ -n "$name" ] && [ -n "$source" ] || continue
        run_quiet codex plugin marketplace add "$source" || \
            echo "    [=] codex marketplace add did not apply: $name ($source)"
    done <<< "$MARKETPLACES"

    while IFS= read -r plugin; do
        [ -n "$plugin" ] || continue
        run_quiet codex plugin add "$plugin" || \
            echo "    [=] codex plugin add did not apply: $plugin"
    done <<< "$PLUGINS"
fi

# --- Verify -----------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ] || [ "$DO_CLAUDE" -eq 0 ]; then
    exit 0
fi

echo "[+] verifying"
ACTIVE="$(claude plugin list --json 2>/dev/null | jq -r '.[] | select(.enabled) | .id' || true)"
missing=0
while IFS= read -r plugin; do
    [ -n "$plugin" ] || continue
    if printf '%s\n' "$ACTIVE" | grep -Fxq "$plugin"; then
        echo "    ok      $plugin"
    else
        echo "    MISSING $plugin" >&2
        missing=$((missing + 1))
    fi
done <<< "$PLUGINS"

if [ "$missing" -gt 0 ]; then
    echo "[!] $missing declared plugin(s) are not active. Common causes: the id is" >&2
    echo "    not in that marketplace, the marketplace clone failed (no network)," >&2
    echo "    or the name after @ does not match the marketplace's own name." >&2
    echo "    Re-run after fixing $SETTINGS." >&2
    exit 1
fi

echo "[+] all declared plugins are installed and enabled — restart the agent to load them."
