#!/bin/bash

usage() {
    cat >&2 <<EOF
Usage: $0 <type> <activity_name> [<base>]
  <type>: web | external | internal | cloud | mobile | full | lite | none
  <base>: debian (default) | kali

  lite — minimal engagement profile: only base (Claude Code + core utilities),
         utils (Go CLI helpers), and AI (Codex, sgpt, Strix). Useful when you
         don't need the recon/scanner toolchain (e.g. desk research, report
         writing, vendor liaison).
  none — scaffold-only engagement: builds the folder structure and the
         devcontainer, but install-offsec-tools.sh exits 0 without installing
         any toolchain. Useful for docs-only engagements or when you want to
         install tools manually inside the container.

  Base images:
    debian — debian:trixie-slim (stable release codename, ~75MB pre-install)
    kali   — kalilinux/kali-rolling (tracks Kali rolling; non-free already on)

Examples:
  $0 web      client-acme
  $0 internal acme-internal-2026q2
  $0 lite     client-deskreview
  $0 web      client-acme         kali
  $0 none     client-docs-only
EOF
    exit 1
}

# Internal debug flag used by tests/test-newPT.sh — prints the INSTALL_GROUPS
# string the script would resolve for the given type, without scaffolding.
# Not advertised in the usage banner.
if [ "${1:-}" = "--print-groups" ]; then
    [ "$#" -eq 2 ] || { echo "Usage: $0 --print-groups <type>" >&2; exit 1; }
    type="$2"
    activity_name=""
    base="debian"
else
    if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
        usage
    fi
    type="$1"
    activity_name="$2"
    base="${3:-debian}"
fi

# Map base alias → concrete image tag. Both bases are Debian-derived, so
# install-offsec-tools.sh works on either without per-distro branches (the
# one branch that exists, install_docker, already detects Kali correctly).
case "$base" in
    debian) BASE_IMAGE="debian:trixie-slim" ;;
    kali)   BASE_IMAGE="kalilinux/kali-rolling" ;;
    *)
        echo "ERROR: unknown base '$base'" >&2
        echo "       valid bases: debian, kali" >&2
        usage
        ;;
esac
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template_dir="$script_dir/templates"

case "$type" in
    web)      INSTALL_GROUPS="base,PD,praetorian,tomnomnom,recon,takeover,dictionary,sast,dast,utils,AI" ;;
    external) INSTALL_GROUPS="base,PD,praetorian,tomnomnom,recon,takeover,dictionary,dast,cracking,utils,AI" ;;
    internal) INSTALL_GROUPS="base,PD,tomnomnom,recon,cracking,RT,utils,AI" ;;
    cloud)    INSTALL_GROUPS="base,cloud,utils,AI" ;;
    mobile)   INSTALL_GROUPS="base,reversing,utils,AI" ;;
    full)     INSTALL_GROUPS="base,PD,praetorian,tomnomnom,recon,takeover,dictionary,sast,dast,cracking,RT,cloud,reversing,utils,AI" ;;
    lite)     INSTALL_GROUPS="base,utils,AI" ;;
    none)     INSTALL_GROUPS="none" ;;   # install-offsec-tools.sh sentinel — exits 0 without touching the system
    *)
        echo "ERROR: unknown engagement type '$type'" >&2
        usage
        ;;
esac

# --print-groups short-circuit: print resolved groups and exit before any I/O.
if [ -z "$activity_name" ]; then
    echo "$INSTALL_GROUPS"
    exit 0
fi

# Create the folder structure
mkdir -p "$activity_name"/{attachments,scans,poc,findings,wl,logs}

# The command audit log (written by the .claude/hooks/log-command.sh hook) can
# embed secrets (sprayed passwords, auth headers, SSH keys). Keep logs/ out of
# any shared repo — same rule as wl/.
printf '*\n!.gitignore\n' > "$activity_name/logs/.gitignore"

# Create the scope files and the per-engagement empty files
touch "$activity_name"/scope.txt
touch "$activity_name"/out-of-scope.txt
touch "$activity_name"/journal.md
touch "$activity_name"/TODO.md

# Activity notes / findings index — copy template and inject the activity name
cp "$template_dir/activity.md" "$activity_name"/"$activity_name".md
sed -i "s|{{ACTIVITY_NAME}}|$activity_name|g" "$activity_name"/"$activity_name".md

# Drop in the engagement-level AGENTS.md (rules + scaffolding) and CLAUDE.md (pointer)
cp "$template_dir/AGENTS.md" "$activity_name"/AGENTS.md
cp "$template_dir/CLAUDE.md" "$activity_name"/CLAUDE.md

# Per-finding reference template — operator copies to findings/<finding_slug>.md per issue
cp "$template_dir/finding.md" "$activity_name"/findings/_template.md

# Kickoff notes — operator pastes raw notes here; the LLM reads them at the
# first session to auto-populate AGENTS.md placeholders.
cp "$template_dir/_init_notes.txt" "$activity_name"/_init_notes.txt

# Engagement SQLite DB: schema + render script + saved query snippets.
# DB is the source of truth for assets/credentials/findings metadata; the
# markdown tables in <activity>.md are rendered from it by db/render.sh.
mkdir -p "$activity_name/db/queries"
cp "$template_dir/db/schema.sql"  "$activity_name/db/schema.sql"
cp "$template_dir/db/render.sh"   "$activity_name/db/render.sh"
cp "$template_dir/db/whatweknow.sh" "$activity_name/db/whatweknow.sh"
cp "$template_dir/db/queries/"*.sql "$activity_name/db/queries/"
sqlite3 "$activity_name/db/engagement.db" < "$template_dir/db/schema.sql" >/dev/null

CUSTOM_TOOLS_REF="main"

# Burp Suite MCP endpoint (SSE) both agents connect to. Burp runs on the HOST
# with the "MCP Server" extension; the container reaches it via --network=host.
# Overridable at scaffold time: BURP_MCP_URL=http://host:port/sse bash newPT.sh ...
BURP_MCP_URL="${BURP_MCP_URL:-http://127.0.0.1:9876/sse}"

# .devcontainer/ — Docker sandbox configuration for Claude Code agents.
mkdir -p "$activity_name/.devcontainer"
cp "$template_dir/devcontainer/Dockerfile"      "$activity_name/.devcontainer/Dockerfile"
cp "$template_dir/devcontainer/devcontainer.json" "$activity_name/.devcontainer/devcontainer.json"
cp "$template_dir/devcontainer/up.sh"           "$activity_name/.devcontainer/up.sh"
# YOLO launchers at the engagement root: `up.sh` + the agent in bypass mode.
cp "$template_dir/devcontainer/yolo.sh"         "$activity_name/yolo.sh"
chmod +x "$activity_name/yolo.sh"
cp "$template_dir/devcontainer/yolo-codex.sh"   "$activity_name/yolo-codex.sh"
chmod +x "$activity_name/yolo-codex.sh"
sed -i \
    -e "s|{{ACTIVITY_NAME}}|$activity_name|g" \
    -e "s|{{INSTALL_GROUPS}}|$INSTALL_GROUPS|g" \
    -e "s|{{CUSTOM_TOOLS_REF}}|$CUSTOM_TOOLS_REF|g" \
    -e "s|{{BASE_IMAGE}}|$BASE_IMAGE|g" \
    "$activity_name/.devcontainer/Dockerfile" \
    "$activity_name/.devcontainer/devcontainer.json"

# Per-engagement secrets file (consumed by Docker via --env-file in devcontainer.json
# runArgs). Source of truth is org/conf/devcontainer.env — gitignored, populated
# once with real keys, then reused for every new engagement. If absent, fall back
# to the committed example and print a one-time setup hint.
master_env="$script_dir/conf/devcontainer.env"
if [ -f "$master_env" ]; then
    cp "$master_env" "$activity_name/.devcontainer/.env"
else
    cp "$template_dir/devcontainer/env-example" "$activity_name/.devcontainer/.env"
    echo "[!] $master_env not found — scaffolded an empty .env from env-example." >&2
    echo "    Create it once with your real keys to skip this step in future engagements:" >&2
    echo "      cp $template_dir/devcontainer/env-example $master_env" >&2
fi
chmod 600 "$activity_name/.devcontainer/.env"
cp "$template_dir/devcontainer/gitignore" "$activity_name/.devcontainer/.gitignore"

# .claude/ — engagement-scoped Claude Code config (verbatim copy, no placeholders).
# settings.json wires the hooks below; hooks/ holds the scripts it calls
# (command audit log, DB→Markdown auto-render, report-prose formatting check).
mkdir -p "$activity_name/.claude/hooks"
cp "$template_dir/claude/settings.json" "$activity_name/.claude/settings.json"
# Shared hooks (used by both Claude and Codex) live in templates/hooks/;
# check-report-format.sh is Claude-only and stays under templates/claude/hooks/.
cp "$template_dir/hooks/"*.sh        "$activity_name/.claude/hooks/"
cp "$template_dir/claude/hooks/"*.sh "$activity_name/.claude/hooks/"
chmod +x "$activity_name/.claude/hooks/"*.sh

# .codex/ — engagement-scoped Codex config (mirror of .claude/). config.toml
# sets the bypass baseline; hooks.json wires the same SessionStart context
# injection + Bash audit-log + DB-render hooks (report-format is Claude-only).
mkdir -p "$activity_name/.codex/hooks"
cp "$template_dir/codex/config.toml" "$activity_name/.codex/config.toml"
cp "$template_dir/codex/hooks.json"  "$activity_name/.codex/hooks.json"
cp "$template_dir/hooks/"*.sh        "$activity_name/.codex/hooks/"
chmod +x "$activity_name/.codex/hooks/"*.sh

# --- Burp MCP wiring (both agents) -----------------------------------------
# .mcp.json is Claude's project-scoped MCP registry (native SSE). The Codex
# entry lives in .codex/config.toml, and up.sh carries a reachability probe;
# both gain the {{BURP_MCP_URL}} placeholder in later steps. Inject the endpoint.
cp "$template_dir/devcontainer/mcp.json" "$activity_name/.mcp.json"
sed -i "s|{{BURP_MCP_URL}}|$BURP_MCP_URL|g" \
    "$activity_name/.mcp.json" \
    "$activity_name/.codex/config.toml" \
    "$activity_name/.devcontainer/up.sh"

cat <<EOF

Structure for '$activity_name' created successfully.

  type:        $type
  groups:      $INSTALL_GROUPS
  base:        $base ($BASE_IMAGE)
  ref:         $CUSTOM_TOOLS_REF
  Dockerfile:  $activity_name/.devcontainer/Dockerfile

Next steps:
  cd $activity_name/
  \$EDITOR _init_notes.txt                      # paste kickoff notes (then ask Claude to fill AGENTS.md from them)
  ./yolo.sh                                    # one-shot: build/start container + Claude in YOLO mode (--dangerously-skip-permissions)
  ./yolo-codex.sh                              # same, but launches Codex (--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust)
  # ...or do it by hand:
  bash .devcontainer/up.sh                     # builds + starts the container (BuildKit + ssh-agent checks)
  devcontainer exec --workspace-folder . claude
  # VS Code alternative: open the folder and accept "Reopen in Container" —
  #   requires DOCKER_BUILDKIT=1 host-wide (export in ~/.zshrc, or set
  #   {"features":{"buildkit":true}} in /etc/docker/daemon.json + restart docker).
EOF
