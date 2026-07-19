#!/bin/bash
set -eo pipefail

# Seed a fresh Codex environment with the user-level config that ACTUALLY
# carries over cleanly — global config.toml, plugins (and the skills they ship),
# standalone skills, custom rules and prompts, global AGENTS.md — while
# deliberately NEVER touching the per-machine state that lives in ~/.codex.
#
# Why an allowlist and not a blind copy of ~/.codex:
#   - Most of ~/.codex is machine-local mutable state: sessions/, history.jsonl,
#     the *.sqlite stores (goals/logs/memories/state), caches, and an
#     installation_id. Copying those into a different user/home drags stale,
#     inconsistent state along and can confuse Codex on first launch.
#   - auth.json is a secret token, handled separately (opt-in below).
# So we copy the small set of things that are genuinely portable, and we leave
# Codex to regenerate its local state on first launch.
#
# Usage:
#   org/seed-codex-env.sh export <dest_dir> [--with-credentials]
#   org/seed-codex-env.sh apply  <src_dir>  [--with-credentials] [--home <home>]
#
#   export  Copy the portable subset FROM the current user's ~/.codex
#           INTO <dest_dir> (a portable seed you can stash/mount/ship).
#   apply   Copy the portable subset FROM <src_dir> (a previously-exported
#           seed, or a mounted old ~/.codex) INTO the target home's ~/.codex.
#
#   --with-credentials  Also copy auth.json (the Codex auth token). OFF by
#                       default: it is a secret, and re-login is cheap. Only
#                       use it for seeds that stay on trusted local storage.
#   --home <home>       (apply only) Seed into <home>/.codex instead of $HOME.
#                       Use with sudo to provision another user's home.
#
# Examples:
#   # On your workstation, build a shareable seed (no secrets):
#   org/seed-codex-env.sh export ./codex-seed
#   # In a fresh container/env, apply it for the current user:
#   org/seed-codex-env.sh apply /mnt/seed/codex-seed
#   # Provision a different account's home:
#   sudo org/seed-codex-env.sh apply /mnt/seed/codex-seed --home /home/pentester

usage() {
    cat >&2 <<EOF
Usage:
  $0 export <dest_dir> [--with-credentials]
  $0 apply  <src_dir>  [--with-credentials] [--home <home>]

  export  Copy the portable subset FROM the current user's ~/.codex
          INTO <dest_dir> (a portable seed you can stash/mount/ship).
  apply   Copy the portable subset FROM <src_dir> (a previously-exported
          seed, or a mounted old ~/.codex) INTO the target home's ~/.codex.

  --with-credentials  Also copy auth.json (the Codex auth token). OFF by
                      default: it is a secret, and re-login is cheap. Only
                      use it for seeds that stay on trusted local storage.
  --home <home>       (apply only) Seed into <home>/.codex instead of \$HOME.
                      Use with sudo to provision another user's home.

What travels: config.toml, plugins (+ their skills), skills, rules, prompts,
AGENTS.md. Never copied: auth.json (unless --with-credentials), sessions,
history, *.sqlite state, caches — Codex regenerates its local state on launch.

Examples:
  $0 export ./codex-seed
  $0 apply /mnt/seed/codex-seed
  sudo $0 apply /mnt/seed/codex-seed --home /home/pentester
EOF
    exit 1
}

# --- Portable subset --------------------------------------------------------
# Things that travel cleanly between users/machines. Files or dirs; missing
# entries are silently skipped. Order is cosmetic (drives the summary).
ALLOWLIST=(
    config.toml      # model / provider / MCP defaults (project .codex/config.toml layers on top)
    plugins          # plugin repos + skills they ship
    skills           # standalone user-level skills
    rules            # custom rules
    prompts          # custom prompt / slash-command files
    AGENTS.md        # global user instructions / memory
)

# auth.json is handled separately (opt-in via --with-credentials).

# Things we MUST NOT carry — informational, used to warn the operator when the
# source still contains them so it's obvious they were left behind on purpose.
DENYLIST=(
    cache sessions log memories shell_snapshots tmp
    history.jsonl installation_id version.json models_cache.json
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
# export:  SRC = current ~/.codex              DEST = <positional>
# apply:   SRC = <positional>                  DEST = <home>/.codex
if [ "$MODE" = "export" ]; then
    SRC="${CODEX_HOME:-$HOME/.codex}"
    DEST="$POSITIONAL"
else
    SRC="$POSITIONAL"
    DEST="$DEST_HOME/.codex"
fi

[ -d "$SRC" ] || { echo "ERROR: source ~/.codex dir not found: $SRC" >&2; exit 1; }
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
    if [ -e "$SRC/auth.json" ]; then
        cp -a "$SRC/auth.json" "$DEST/auth.json"
        chmod 600 "$DEST/auth.json"
        echo "  + auth.json (secret — keep this seed on trusted storage)"
        copied=$((copied + 1))
    else
        echo "  ! --with-credentials given but $SRC/auth.json not found" >&2
    fi
else
    [ -e "$SRC/auth.json" ] && \
        echo "  - auth.json  (skipped; pass --with-credentials to include, or re-login)"
fi

# --- Normalize embedded absolute paths (apply only) -------------------------
# Plugin registries record ABSOLUTE paths to the plugin cache / marketplaces,
# e.g. /home/<orig-user>/.codex/plugins/... . When we seed into a different
# home (typical case: host user 'mattia_m' -> container user 'pentester'),
# those prefixes are stale and the plugins/skills won't resolve. Rewrite any
# "<somehome>/.codex/plugins" prefix to point at the destination dir.
# Only meaningful on apply, where DEST is the real ~/.codex.
if [ "$MODE" = "apply" ] && [ -d "$DEST/plugins" ]; then
    while IFS= read -r f; do
        sed -i "s#[A-Za-z0-9._/-]*/\.codex/plugins#$DEST/plugins#g" "$f"
    done < <(find "$DEST/plugins" -maxdepth 1 -type f -name '*.json')
    echo "  ~ normalized plugin paths -> $DEST/plugins"
fi

# --- Report what we deliberately left behind --------------------------------
left=()
for item in "${DENYLIST[@]}"; do
    [ -e "$SRC/$item" ] && left+=("$item")
done

echo
echo "Seeded $copied item(s) into: $DEST"
if [ "${#left[@]}" -gt 0 ]; then
    echo "Deliberately NOT copied (per-user/per-machine state):"
    printf '  - %s\n' "${left[@]}"
fi

if [ "$MODE" = "apply" ]; then
    echo
    echo "Done. Launch 'codex'."
    [ "$WITH_CREDS" -eq 1 ] || echo "If not signed in, run the login flow once (credentials were not seeded)."
fi
