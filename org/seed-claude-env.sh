#!/bin/bash
set -eo pipefail

# Seed a fresh Claude Code environment with the user-level config that
# ACTUALLY carries over cleanly — plugins (and the skills they ship), custom
# commands/agents, settings, global CLAUDE.md — while deliberately NEVER
# touching ~/.claude.json and ~/.claude/backups/.
#
# Why an allowlist and not a blind copy of ~/.claude (or ~/.claude.json):
#   - Skills/plugins live in ~/.claude/plugins/, NOT in ~/.claude.json.
#   - User-scope MCP would live in ~/.claude.json's top-level `mcpServers`,
#     but project-scope MCP belongs in a repo-versioned .mcp.json — neither
#     benefits from transplanting the whole state file.
#   - ~/.claude.json is a single mutable state blob: per-project history keyed
#     to ABSOLUTE paths, oauthAccount, userID, growthbook/statsig caches,
#     startup counters. Copying it into a different user/home (e.g. pentester)
#     drags machine-specific, inconsistent state along and triggers the
#     "configuration file not found / a backup exists" restore prompt when the
#     backups/ dir is present but the live file is not.
# So we copy the small set of things that are genuinely portable, and we leave
# Claude Code to regenerate a clean ~/.claude.json on first launch.
#
# Usage:
#   org/seed-claude-env.sh export <dest_dir> [--with-credentials]
#   org/seed-claude-env.sh apply  <src_dir>  [--with-credentials] [--home <home>]
#
#   export  Copy the portable subset FROM the current user's ~/.claude
#           INTO <dest_dir> (a portable seed you can stash/mount/ship).
#   apply   Copy the portable subset FROM <src_dir> (a previously-exported
#           seed, or a mounted old ~/.claude) INTO the target home's ~/.claude.
#
#   --with-credentials  Also copy .credentials.json (the OAuth token). OFF by
#                       default: it is a secret, and re-login is cheap. Only
#                       use it for seeds that stay on trusted local storage.
#   --home <home>       (apply only) Seed into <home>/.claude instead of $HOME.
#                       Use with sudo to provision another user's home.
#
# Examples:
#   # On your workstation, build a shareable seed (no secrets):
#   org/seed-claude-env.sh export ./claude-seed
#   # In a fresh container/env, apply it for the current user:
#   org/seed-claude-env.sh apply /mnt/seed/claude-seed
#   # Provision a different account's home:
#   sudo org/seed-claude-env.sh apply /mnt/seed/claude-seed --home /home/pentester

usage() {
    cat >&2 <<EOF
Usage:
  $0 export <dest_dir> [--with-credentials]
  $0 apply  <src_dir>  [--with-credentials] [--home <home>]

  export  Copy the portable subset FROM the current user's ~/.claude
          INTO <dest_dir> (a portable seed you can stash/mount/ship).
  apply   Copy the portable subset FROM <src_dir> (a previously-exported
          seed, or a mounted old ~/.claude) INTO the target home's ~/.claude.

  --with-credentials  Also copy .credentials.json (the OAuth token). OFF by
                      default: it is a secret, and re-login is cheap. Only
                      use it for seeds that stay on trusted local storage.
  --home <home>       (apply only) Seed into <home>/.claude instead of \$HOME.
                      Use with sudo to provision another user's home.

What travels: plugins (+ their skills), skills, commands, agents,
settings.json, CLAUDE.md. Never copied: ~/.claude.json, backups/, projects/,
history, caches — Claude regenerates a clean ~/.claude.json on first launch.

Examples:
  $0 export ./claude-seed
  $0 apply /mnt/seed/claude-seed
  sudo $0 apply /mnt/seed/claude-seed --home /home/pentester
EOF
    exit 1
}

# --- Portable subset --------------------------------------------------------
# Things that travel cleanly between users/machines. Files or dirs; missing
# entries are silently skipped. Order is cosmetic (drives the summary).
ALLOWLIST=(
    plugins          # plugin repos + skills they ship; marketplaces; install state
    skills           # standalone user-level skills (if you keep any outside plugins)
    commands         # custom slash commands
    agents           # custom subagents
    settings.json    # hooks, permissions, enabledPlugins, model
    CLAUDE.md         # global user instructions / memory
)

# .credentials.json is handled separately (opt-in via --with-credentials).

# Things we MUST NOT carry — informational, used to warn the operator when the
# source still contains them so it's obvious they were left behind on purpose.
DENYLIST=(
    backups projects history.jsonl file-history todos shell-snapshots
    statsig debug downloads cache
)

# --- Arg parsing ------------------------------------------------------------
MODE="${1:-}"
[ "$MODE" = "export" ] || [ "$MODE" = "apply" ] || usage
shift

POSITIONAL=""
WITH_CREDS=0
DEST_HOME="$HOME"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --with-credentials) WITH_CREDS=1; shift ;;
        --home)
            [ "$MODE" = "apply" ] || { echo "ERROR: --home is only valid for 'apply'." >&2; exit 1; }
            [ -n "${2:-}" ] || { echo "ERROR: --home needs a directory." >&2; exit 1; }
            DEST_HOME="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*) echo "ERROR: unknown flag: $1" >&2; usage ;;
        *)
            [ -z "$POSITIONAL" ] || { echo "ERROR: unexpected extra argument: $1" >&2; usage; }
            POSITIONAL="$1"; shift ;;
    esac
done
[ -n "$POSITIONAL" ] || usage

# --- Resolve source / destination ------------------------------------------
# export:  SRC = current ~/.claude              DEST = <positional>
# apply:   SRC = <positional>                   DEST = <home>/.claude
if [ "$MODE" = "export" ]; then
    SRC="${CLAUDE_HOME:-$HOME/.claude}"
    DEST="$POSITIONAL"
else
    SRC="$POSITIONAL"
    DEST="$DEST_HOME/.claude"
fi

[ -d "$SRC" ] || { echo "ERROR: source ~/.claude dir not found: $SRC" >&2; exit 1; }
if [ "$SRC" = "$DEST" ]; then
    echo "ERROR: source and destination are the same dir ($SRC) — nothing to do." >&2
    exit 1
fi

mkdir -p "$DEST"

# --- Copy the allowlist -----------------------------------------------------
copied=0
for item in "${ALLOWLIST[@]}"; do
    if [ -e "$SRC/$item" ]; then
        # -a preserves mode/timestamps; trailing-slash-free so dirs copy whole.
        # Remove a stale destination first so dirs merge predictably.
        rm -rf "$DEST/$item"
        cp -a "$SRC/$item" "$DEST/$item"
        echo "  + $item"
        copied=$((copied + 1))
    fi
done

if [ "$WITH_CREDS" -eq 1 ]; then
    if [ -e "$SRC/.credentials.json" ]; then
        cp -a "$SRC/.credentials.json" "$DEST/.credentials.json"
        chmod 600 "$DEST/.credentials.json"
        echo "  + .credentials.json (secret — keep this seed on trusted storage)"
        copied=$((copied + 1))
    else
        echo "  ! --with-credentials given but $SRC/.credentials.json not found" >&2
    fi
else
    [ -e "$SRC/.credentials.json" ] && \
        echo "  - .credentials.json  (skipped; pass --with-credentials to include, or re-login)"
fi

# --- Normalize embedded absolute paths (apply only) -------------------------
# Plugin registries record ABSOLUTE paths to the plugin cache / marketplaces,
# e.g. /home/<orig-user>/.claude/plugins/... . When we seed into a different
# home (typical case: host user 'mattia_m' -> container user 'pentester'),
# those prefixes are stale and the plugins/skills won't resolve. Rewrite any
# "<somehome>/.claude/plugins" prefix to point at the destination dir.
# Only meaningful on apply, where DEST is the real ~/.claude.
if [ "$MODE" = "apply" ] && [ -d "$DEST/plugins" ]; then
    while IFS= read -r f; do
        sed -i "s#[A-Za-z0-9._/-]*/\.claude/plugins#$DEST/plugins#g" "$f"
    done < <(find "$DEST/plugins" -maxdepth 1 -type f -name '*.json')
    echo "  ~ normalized plugin paths -> $DEST/plugins"
fi

# --- Report what we deliberately left behind --------------------------------
left=()
for item in "${DENYLIST[@]}"; do
    [ -e "$SRC/$item" ] && left+=("$item")
done
[ -e "$SRC/../.claude.json" ] && left+=(".claude.json (sibling of ~/.claude)")

echo
echo "Seeded $copied item(s) into: $DEST"
if [ "${#left[@]}" -gt 0 ]; then
    echo "Deliberately NOT copied (per-user/per-machine state):"
    printf '  - %s\n' "${left[@]}"
fi

if [ "$MODE" = "apply" ]; then
    echo
    echo "Done. Launch 'claude' — it will regenerate a clean ~/.claude.json."
    [ "$WITH_CREDS" -eq 1 ] || echo "If not signed in, run the login flow once (credentials were not seeded)."
fi
