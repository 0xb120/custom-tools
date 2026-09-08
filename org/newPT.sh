#!/bin/bash

usage() {
    cat >&2 <<EOF
Usage: $0 <type> <activity_name> [<base>]
  <type>: web | external | internal | cloud | mobile | code | full | lite | none
  <base>: debian (default) | kali

  code — white-box source review: SAST toolchain (semgrep + rules, gitleaks,
         jsluice, detect-secrets) and the source-oriented agent plugins, without
         the network recon/scanner stack. For secure code reviews, and for a
         black-box engagement that later receives the source.
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
  $0 code     client-acme-srcreview
  $0 lite     client-deskreview
  $0 web      client-acme         kali
  $0 none     client-docs-only
EOF
    exit 1
}

# Internal debug flags used by tests/test-newPT.sh — print the INSTALL_GROUPS or
# the plugin allowlist the script would resolve for the given type, without
# scaffolding. Not advertised in the usage banner.
PRINT_MODE=""
case "${1:-}" in
    --print-groups|--print-plugins)
        [ "$#" -eq 2 ] || { echo "Usage: $0 $1 <type>" >&2; exit 1; }
        PRINT_MODE="$1"
        type="$2"
        activity_name=""
        base="debian"
        ;;
    *)
        if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
            usage
        fi
        type="$1"
        activity_name="$2"
        base="${3:-debian}"
        ;;
esac

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
    code)     INSTALL_GROUPS="base,sast,utils,AI" ;;
    full)     INSTALL_GROUPS="base,PD,praetorian,tomnomnom,recon,takeover,dictionary,sast,dast,cracking,RT,cloud,reversing,utils,AI" ;;
    lite)     INSTALL_GROUPS="base,utils,AI" ;;
    none)     INSTALL_GROUPS="none" ;;   # install-offsec-tools.sh sentinel — exits 0 without touching the system
    *)
        echo "ERROR: unknown engagement type '$type'" >&2
        usage
        ;;
esac

# Marketplace id -> the source string `plugin marketplace add` accepts (GitHub
# owner/repo here; a URL or a local path work too). Every marketplace named
# below — base or referenced by a plugin — must resolve here, otherwise the sync
# step cannot find the plugin. Add a row when you start using a new marketplace.
marketplace_source() {
    case "$1" in
        trailofbits)             echo "trailofbits/skills" ;;
        claude-plugins-official) echo "anthropics/claude-plugins-official" ;;
        *) return 1 ;;
    esac
}

# Marketplaces every engagement declares, whether or not it enables a plugin
# from them. Declaring one is what makes it browsable in `/plugin` and
# installable by name mid-engagement (`claude plugin install <x>@trailofbits`)
# without adding the marketplace first — and it is what sync-agent-plugins.sh
# registers at project scope inside the container, which reads this list and
# nothing else. Claude Code re-registers the official one on its own too; the
# row here is what makes it reach the container's project scope.
BASE_MARKETPLACES="trailofbits claude-plugins-official"

# Plugins every engagement type declares, whatever the target is: they carry the
# reasoning and write-up side of the work (clarify an underspecified ask, spot a
# footgun API or an insecure default, build a PoC page, keep session memory,
# tidy up throwaway code, put a diagram on a board), so there is no type where
# they are dead weight. Same
# role as BASE_MARKETPLACES above, one level down — not a group: there is no
# name to resolve and no per-type mapping, it is simply always on.
#
# Two of them carry a caveat worth knowing rather than rediscovering:
# `remember` runs its own SessionStart/PostToolUse hooks alongside the
# engagement's ptctl context hooks (both write session state — deliberate
# duplication), and `miro` talks to a REMOTE MCP server at mcp.miro.com, so
# whatever an engagement hands it leaves the container.
BASE_PLUGINS="ask-questions-if-underspecified@trailofbits
sharp-edges@trailofbits
insecure-defaults@trailofbits
playground@claude-plugins-official
remember@claude-plugins-official
code-simplifier@claude-plugins-official
miro@claude-plugins-official"

# Per-type plugin allowlist — one row per <type>, 1:1 with the INSTALL_GROUPS
# table above, holding what that type adds ON TOP of BASE_PLUGINS. This and the
# base set are the only things that decide what an engagement starts with: the
# container inherits nothing from the operator's host. Ids are
# `<plugin>@<marketplace>`, space-separated, and every marketplace named must
# resolve in marketplace_source() above.
#
# Match the row to what the type can actually do — a plugin whose toolchain is
# not in that type's INSTALL_GROUPS is a skill with no binary underneath.
# `static-analysis` (CodeQL + Semgrep) is the clearest case: install_sast()
# ships those, and `sast` is only in web/code/full.
#
# Keep the rows short — every enabled plugin costs always-on context in *every*
# session of the engagement, used or not.
type_plugins() {
    case "$1" in
        web)      echo "burpsuite-project-parser@trailofbits fp-check@trailofbits playwright@claude-plugins-official code-review@claude-plugins-official" ;;
        external) echo "burpsuite-project-parser@trailofbits fp-check@trailofbits playwright@claude-plugins-official code-review@claude-plugins-official" ;;
        internal) echo "fp-check@trailofbits" ;;
        cloud)    echo "fp-check@trailofbits supply-chain-risk-auditor@trailofbits" ;;
        mobile)   echo "fp-check@trailofbits audit-context-building@trailofbits variant-analysis@trailofbits code-review@claude-plugins-official \
                        claude-security@claude-plugins-official firebase-apk-scanner@trailofbits supply-chain-risk-auditor@trailofbits" ;;
        code)     echo "audit-context-building@trailofbits variant-analysis@trailofbits static-analysis@trailofbits fp-check@trailofbits code-review@claude-plugins-official \
                        claude-security@claude-plugins-official supply-chain-risk-auditor@trailofbits trailmark@trailofbits" ;;
        full)     echo "burpsuite-project-parser@trailofbits fp-check@trailofbits playwright@claude-plugins-official code-review@claude-plugins-official \
                        audit-context-building@trailofbits variant-analysis@trailofbits static-analysis@trailofbits claude-security@claude-plugins-official \
                        firebase-apk-scanner@trailofbits supply-chain-risk-auditor@trailofbits trailmark@trailofbits" ;;
        lite)     echo "" ;;
        none)     echo "" ;;
        *) return 1 ;;
    esac
}

# A missing row is a bug in the table above (a type added to INSTALL_GROUPS and
# forgotten here), not operator error — fail loudly instead of scaffolding a
# silently plugin-less engagement.
type_extra_plugins="$(type_plugins "$type")" || {
    echo "ERROR: no plugin row for engagement type '$type'" >&2
    echo "       add one to type_plugins() in $0" >&2
    exit 1
}

# Base set first, then the type's own additions. Unquoted on purpose: word
# splitting normalises the padding and newlines both lists are written with.
# The dedup keeps a row that repeats a base plugin from installing it twice.
# shellcheck disable=SC2086
ENGAGEMENT_PLUGINS=""
for plugin_id in $BASE_PLUGINS $type_extra_plugins; do
    case " $ENGAGEMENT_PLUGINS " in
        *" $plugin_id "*) continue ;;
    esac
    ENGAGEMENT_PLUGINS="${ENGAGEMENT_PLUGINS:+$ENGAGEMENT_PLUGINS }$plugin_id"
done

# --print-* short-circuit: print the resolved value and exit before any I/O.
if [ -n "$PRINT_MODE" ]; then
    case "$PRINT_MODE" in
        --print-groups)  echo "$INSTALL_GROUPS" ;;
        --print-plugins) echo "$ENGAGEMENT_PLUGINS" ;;
    esac
    exit 0
fi

# Fail early on a typo in the tables above rather than at container postCreate.
for plugin_id in $ENGAGEMENT_PLUGINS; do
    case "$plugin_id" in
        *@*) ;;
        *) echo "ERROR: plugin '$plugin_id' must be <plugin>@<marketplace>" >&2; exit 1 ;;
    esac
    marketplace_source "${plugin_id##*@}" >/dev/null || {
        echo "ERROR: no marketplace source known for '${plugin_id##*@}'" >&2
        echo "       add it to marketplace_source() in $0" >&2
        exit 1
    }
done
for marketplace in $BASE_MARKETPLACES; do
    marketplace_source "$marketplace" >/dev/null || {
        echo "ERROR: no marketplace source known for base marketplace '$marketplace'" >&2
        echo "       add it to marketplace_source() in $0" >&2
        exit 1
    }
done

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

# Drop in the small always-on rules, on-demand playbook, and Claude pointer.
cp "$template_dir/AGENTS.md" "$activity_name"/AGENTS.md
cp "$template_dir/PT_PLAYBOOK.md" "$activity_name"/PT_PLAYBOOK.md
cp "$template_dir/CLAUDE.md" "$activity_name"/CLAUDE.md

# Per-finding reference template — ptctl copies it atomically when promoting an observation.
cp "$template_dir/finding.md" "$activity_name"/findings/_template.md

# Kickoff notes — operator pastes raw notes here; the LLM reads them at the
# first session to auto-populate AGENTS.md placeholders.
cp "$template_dir/_init_notes.txt" "$activity_name"/_init_notes.txt

# Engagement SQLite DB: schema, transactional PT registry, render script, and
# saved query snippets. DB is the source of truth for observations, evidence,
# assets, credentials, and finding metadata.
mkdir -p "$activity_name/db/queries"
cp "$template_dir/db/schema.sql"  "$activity_name/db/schema.sql"
cp "$template_dir/db/render.sh"   "$activity_name/db/render.sh"
cp "$template_dir/db/whatweknow.sh" "$activity_name/db/whatweknow.sh"
cp "$template_dir/db/ptctl.py"    "$activity_name/db/ptctl.py"
cp "$template_dir/db/queries/"*.sql "$activity_name/db/queries/"
chmod +x "$activity_name/db/render.sh" \
         "$activity_name/db/whatweknow.sh" \
         "$activity_name/db/ptctl.py"
sqlite3 "$activity_name/db/engagement.db" < "$template_dir/db/schema.sql" >/dev/null

CUSTOM_TOOLS_REF="main"

# Claude Code release channel baked into the engagement image.
#   latest  (default) — newest release; what you want unless you have a reason.
#   stable            — the slower release ring.
#   X.Y.Z             — pin, for an engagement that must stay reproducible.
# Override at scaffold time: CLAUDE_CHANNEL=stable bash newPT.sh web client-acme
CLAUDE_CHANNEL="${CLAUDE_CHANNEL:-latest}"

# Cache key for the thin Claude Code layer at the end of the Dockerfile. The
# heavy toolchain layer above it is shared across engagements via the BuildKit
# cache, which would otherwise pin every new engagement to whatever release was
# current when that cache entry was first created. Stamping the scaffold date
# here re-runs only the ~10s Claude layer per engagement. Engagements scaffolded
# on the same day share it, which is exactly what we want.
SCAFFOLD_DATE="$(date -u +%Y-%m-%d)"

# Burp Suite MCP endpoint both agents connect to. Burp runs on the HOST with the
# "MCP Server" extension; the container reaches it via --network=host. Transport
# is SSE served at the ROOT path (verified against the extension: /sse and /mcp
# return 404, the SSE stream is at /). Overridable at scaffold time:
# BURP_MCP_URL=http://host:port bash newPT.sh ...
BURP_MCP_URL="${BURP_MCP_URL:-http://127.0.0.1:9876}"

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
    -e "s|{{CLAUDE_CHANNEL}}|$CLAUDE_CHANNEL|g" \
    -e "s|{{SCAFFOLD_DATE}}|$SCAFFOLD_DATE|g" \
    "$activity_name/.devcontainer/Dockerfile" \
    "$activity_name/.devcontainer/devcontainer.json" \
    "$activity_name/.devcontainer/up.sh"

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
# (command audit, DB→Markdown auto-render, report formatting, stop-time doctor).
mkdir -p "$activity_name/.claude/hooks"
cp "$template_dir/claude/settings.json" "$activity_name/.claude/settings.json"

# Write the engagement's plugin allowlist into the settings copy. The template
# ships both keys as {} so the placeholders are visible even when a type has no
# default plugins — that is where you add them by hand later.
#
# Marketplaces = the always-declared base set, then any additional one a plugin
# comes from. The base set stays even for a type with no plugins, so /plugin can
# browse it and `plugin install` resolves names mid-engagement.
engagement_marketplaces=""
for marketplace in $BASE_MARKETPLACES $(for p in $ENGAGEMENT_PLUGINS; do echo "${p##*@}"; done); do
    case " $engagement_marketplaces " in
        *" $marketplace="*) continue ;;   # already resolved
    esac
    engagement_marketplaces="$engagement_marketplaces $marketplace=$(marketplace_source "$marketplace")"
done
if ! ENGAGEMENT_PLUGINS="$ENGAGEMENT_PLUGINS" \
     ENGAGEMENT_MARKETPLACES="$engagement_marketplaces" \
     python3 - "$activity_name/.claude/settings.json" <<'PY'
import json, os, sys

path = sys.argv[1]
markets = {}
for pair in os.environ.get("ENGAGEMENT_MARKETPLACES", "").split():
    name, _, repo = pair.partition("=")
    markets[name] = {"source": {"source": "github", "repo": repo}}

with open(path) as fh:
    cfg = json.load(fh)
# Both keys exist in the template, so assigning preserves their position near
# the top of the file instead of appending them after the hooks block.
cfg["extraKnownMarketplaces"] = markets
cfg["enabledPlugins"] = {p: True for p in os.environ.get("ENGAGEMENT_PLUGINS", "").split()}
with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
PY
then
    echo "ERROR: could not write the plugin allowlist into .claude/settings.json" >&2
    exit 1
fi
# Shared hooks (used by both Claude and Codex) live in templates/hooks/;
# check-report-format.sh is Claude-only and stays under templates/claude/hooks/.
cp "$template_dir/hooks/"*.sh        "$activity_name/.claude/hooks/"
cp "$template_dir/claude/hooks/"*.sh "$activity_name/.claude/hooks/"
chmod +x "$activity_name/.claude/hooks/"*.sh

# .codex/ — engagement-scoped Codex config (mirror of .claude/). config.toml
# sets the bypass baseline; hooks.json wires bounded SessionStart context
# (without duplicating native AGENTS.md) + audit/render + stop-time checks.
mkdir -p "$activity_name/.codex/hooks"
cp "$template_dir/codex/config.toml" "$activity_name/.codex/config.toml"
cp "$template_dir/codex/hooks.json"  "$activity_name/.codex/hooks.json"
cp "$template_dir/hooks/"*.sh        "$activity_name/.codex/hooks/"
chmod +x "$activity_name/.codex/hooks/"*.sh

# --- Burp MCP wiring (both agents) -----------------------------------------
# .mcp.json is Claude's project-scoped MCP registry (native SSE). Codex ignores
# project-scoped mcp_servers, so its Burp server is registered into the global
# ~/.codex/config.toml by the devcontainer.json postCreate `codex mcp add` step.
# up.sh carries a reachability probe. Inject the endpoint into all three.
cp "$template_dir/devcontainer/mcp.json" "$activity_name/.mcp.json"
sed -i "s|{{BURP_MCP_URL}}|$BURP_MCP_URL|g" \
    "$activity_name/.mcp.json" \
    "$activity_name/.devcontainer/up.sh" \
    "$activity_name/.devcontainer/devcontainer.json"

# Initialize the compact handoff last. Its mtime is the session-check baseline,
# so it must be newer than the freshly created DB, TODO, journal, and report.
mkdir -p "$activity_name/.context"
cp "$template_dir/context/handoff.md" "$activity_name/.context/handoff.md"
cp "$template_dir/context/state.json" "$activity_name/.context/state.json"
cp "$template_dir/context/gitignore" "$activity_name/.context/.gitignore"
(
    cd "$activity_name"
    python3 db/ptctl.py session close \
        --focus 'Engagement initialization' \
        --outcome administrative \
        --assessment 'engagement scaffold initialization' \
        --completed 'Engagement scaffold created' \
        --blocker 'Scope and engagement placeholders may still need operator input' \
        --next 'Fill AGENTS.md, scope.txt, and out-of-scope.txt from authorized kickoff material' \
        --next 'Define segments in db/engagement.db' \
        --reference AGENTS.md \
        --reference scope.txt >/dev/null
) || {
    echo "ERROR: could not initialize the session delta baseline" >&2
    exit 1
}

cat <<EOF

Structure for '$activity_name' created successfully.

  type:        $type
  groups:      $INSTALL_GROUPS
  base:        $base ($BASE_IMAGE)
  ref:         $CUSTOM_TOOLS_REF
  claude:      $CLAUDE_CHANNEL (refresh key $SCAFFOLD_DATE; auto-update ON — set
               DISABLE_AUTOUPDATER=1 in .devcontainer/.env to freeze the version)
  plugins:     $(echo "$ENGAGEMENT_PLUGINS" | wc -w) enabled (base + $type)
               ${ENGAGEMENT_PLUGINS:-(none — add a row to type_plugins() in newPT.sh)}
  markets:     $BASE_MARKETPLACES (declared, so /plugin can browse and install by name)
  Dockerfile:  $activity_name/.devcontainer/Dockerfile

Next steps:
  cd $activity_name/
  \$EDITOR _init_notes.txt                      # paste kickoff notes (then ask Claude to fill AGENTS.md from them)
  \$EDITOR .claude/settings.json                # the engagement's plugin/marketplace allowlist (nothing comes from your host)
  bash ~/custom-tools/org/sync-agent-plugins.sh . --dry-run
                                               # ...preview what that list installs; postCreate applies it in the container
  python3 db/ptctl.py context explain           # audit the small session bootstrap
  python3 db/ptctl.py context pending           # list all open work on demand
  python3 db/ptctl.py board                     # full canonical registry, on demand
  python3 db/ptctl.py doctor                    # check DB / Markdown / evidence drift
  ./yolo.sh                                    # one-shot: build/start container + Claude in YOLO mode (--dangerously-skip-permissions)
  ./yolo-codex.sh                              # same, but launches Codex (--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust)
  # ...or do it by hand:
  bash .devcontainer/up.sh                     # builds + starts the container (BuildKit + ssh-agent checks)
  bash .devcontainer/up.sh --pull              # ...same, but on a freshly pulled base image (both bases are
                                               #    moving tags; docker otherwise reuses the local copy forever)
                                               #    also works via ./yolo.sh --pull and ./yolo-codex.sh --pull
  devcontainer exec --workspace-folder . claude
  # Claude Code self-updates inside the container. To force a refresh without a rebuild:
  #   devcontainer exec --workspace-folder . sudo bash ~/custom-tools/org/install-offsec-tools.sh --claude-only /opt
  # VS Code alternative: open the folder and accept "Reopen in Container" —
  #   requires DOCKER_BUILDKIT=1 host-wide (export in ~/.zshrc, or set
  #   {"features":{"buildkit":true}} in /etc/docker/daemon.json + restart docker).
EOF
