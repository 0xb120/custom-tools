#!/usr/bin/env bash
# Tests for org/newPT.sh. Each test runs in a fresh mktemp -d so the working
# tree stays clean. The script under test is invoked via `bash` to avoid
# requiring +x bits on a fresh checkout.
set -eo pipefail

SCRIPT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/org/newPT.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# --- Test 1: zero args ⇒ exit 1 + usage on stderr ---
if bash "$SCRIPT" 2>/tmp/np.err; then
    fail "expected exit 1 with zero args, got exit 0"
fi
grep -q "Usage" /tmp/np.err || fail "stderr should print usage"
pass "zero args exits 1 with usage"

# --- Test 2: one arg ⇒ exit 1 (legacy single-arg form rejected) ---
if bash "$SCRIPT" client-acme 2>/tmp/np.err; then
    fail "expected exit 1 with one arg, got exit 0"
fi
grep -q "Usage" /tmp/np.err || fail "stderr should print usage for one-arg form"
pass "one arg (legacy form) exits 1"

# --- Test 2b: four args ⇒ exit 1 (too many positionals) ---
if bash "$SCRIPT" lite engagement-x kali extra 2>/tmp/np.err; then
    fail "expected exit 1 with four args, got exit 0"
fi
grep -q "Usage" /tmp/np.err || fail "stderr should print usage for 4-arg form"
pass "four args exits 1"

# --- Test 3: unknown <type> ⇒ exit 1 + helpful message ---
if bash "$SCRIPT" bogus client-acme 2>/tmp/np.err; then
    fail "expected exit 1 for unknown type, got exit 0"
fi
grep -q "unknown engagement type" /tmp/np.err || fail "stderr should name the error"
pass "unknown <type> exits 1"

# --- Test 4: each <type> resolves to the expected INSTALL_GROUPS (via --print-groups debug flag) ---
declare -A EXPECTED=(
    [web]="base,PD,praetorian,tomnomnom,recon,takeover,dictionary,sast,dast,utils,AI"
    [external]="base,PD,praetorian,tomnomnom,recon,takeover,dictionary,dast,cracking,utils,AI"
    [internal]="base,PD,tomnomnom,recon,cracking,RT,utils,AI"
    [cloud]="base,cloud,utils,AI"
    [mobile]="base,reversing,utils,AI"
    [code]="base,sast,utils,AI"
    [full]="base,PD,praetorian,tomnomnom,recon,takeover,dictionary,sast,dast,cracking,RT,cloud,reversing,utils,AI"
    [lite]="base,utils,AI"
    [none]="none"
)
for t in "${!EXPECTED[@]}"; do
    got="$(bash "$SCRIPT" --print-groups "$t")" \
        || fail "--print-groups $t failed"
    [ "$got" = "${EXPECTED[$t]}" ] || fail "type=$t expected '${EXPECTED[$t]}' got '$got'"
done
pass "every <type> maps to the documented INSTALL_GROUPS"

# --- Test 4b: each <type> resolves to its plugin groups and their expansion ---
# Containers inherit no plugins from the host, so these tables are the only thing
# that decides what an engagement starts with. Groups per type, and the concrete ids they expand to. Both are asserted: the
# group list is the thing an operator edits, the expansion is what reaches
# .claude/settings.json.
declare -A EXPECTED_PLUGIN_GROUPS=(
    [web]="burp,triage"
    [external]="burp,triage,supplychain"
    [internal]="triage"
    [cloud]="triage,supplychain"
    [mobile]="mobile,triage"
    [code]="sast,codereview,triage"
    [full]="burp,triage,sast,codereview,mobile,supplychain"
    [lite]=""
    [none]=""
)
BURP="burpsuite-project-parser@trailofbits"
TRIAGE="fp-check@trailofbits"
SAST="static-analysis@trailofbits semgrep-rule-creator@trailofbits insecure-defaults@trailofbits variant-analysis@trailofbits"
CODEREVIEW="audit-context-building@trailofbits sharp-edges@trailofbits differential-review@trailofbits"
MOBILE="firebase-apk-scanner@trailofbits c-review@trailofbits dwarf-expert@trailofbits"
SUPPLYCHAIN="supply-chain-risk-auditor@trailofbits agentic-actions-auditor@trailofbits"
declare -A EXPECTED_PLUGINS=(
    [web]="$BURP $TRIAGE"
    [external]="$BURP $TRIAGE $SUPPLYCHAIN"
    [internal]="$TRIAGE"
    [cloud]="$TRIAGE $SUPPLYCHAIN"
    [mobile]="$MOBILE $TRIAGE"
    [code]="$SAST $CODEREVIEW $TRIAGE"
    [full]="$BURP $TRIAGE $SAST $CODEREVIEW $MOBILE $SUPPLYCHAIN"
    [lite]=""
    [none]=""
)
for t in "${!EXPECTED_PLUGINS[@]}"; do
    got="$(bash "$SCRIPT" --print-plugin-groups "$t")" \
        || fail "--print-plugin-groups $t failed"
    [ "$got" = "${EXPECTED_PLUGIN_GROUPS[$t]}" ] || \
        fail "type=$t expected groups '${EXPECTED_PLUGIN_GROUPS[$t]}' got '$got'"
    got="$(bash "$SCRIPT" --print-plugins "$t")" \
        || fail "--print-plugins $t failed"
    [ "$got" = "${EXPECTED_PLUGINS[$t]}" ] || \
        fail "type=$t expected plugins '${EXPECTED_PLUGINS[$t]}' got '$got'"
done
# Groups compose without duplicating a plugin two of them share.
[ "$(bash "$SCRIPT" --print-plugins full | tr ' ' '\n' | sort | uniq -d)" = "" ] || \
    fail "overlapping groups must not repeat a plugin id"
pass "every <type> maps to the documented plugin groups and their expansion"

# --- Test 5: scaffolding 'internal' engagement drops .devcontainer/ with substituted INSTALL_GROUPS ---
cd "$TMP"
rm -rf engagement-internal
bash "$SCRIPT" internal engagement-internal >/dev/null
test -d engagement-internal/.devcontainer || fail ".devcontainer/ not created"
test -f engagement-internal/.devcontainer/Dockerfile || fail ".devcontainer/Dockerfile missing"
test -f engagement-internal/.devcontainer/devcontainer.json || fail ".devcontainer/devcontainer.json missing"

# YOLO launcher lands at the engagement root, is executable, and carries the flag
test -x engagement-internal/yolo.sh || fail "yolo.sh missing or not executable at engagement root"
grep -q -- '--dangerously-skip-permissions' engagement-internal/yolo.sh || \
    fail "yolo.sh does not pass --dangerously-skip-permissions to claude"

# Codex YOLO launcher lands at the root, executable, carries both bypass flags
test -x engagement-internal/yolo-codex.sh || fail "yolo-codex.sh missing or not executable"
grep -q -- '--dangerously-bypass-approvals-and-sandbox' engagement-internal/yolo-codex.sh || \
    fail "yolo-codex.sh must pass --dangerously-bypass-approvals-and-sandbox"
grep -q -- '--dangerously-bypass-hook-trust' engagement-internal/yolo-codex.sh || \
    fail "yolo-codex.sh must pass --dangerously-bypass-hook-trust"

# devcontainer.json mounts the two agent credential FILES and nothing else from
# the host's agent config: plugins, marketplaces and MCP servers are declared per
# engagement, never inherited from the operator's workstation.
DCJ=engagement-internal/.devcontainer/devcontainer.json
grep -q 'HOME}/.claude/.credentials.json,target=/seed/claude-credentials.json' "$DCJ" || \
    fail "devcontainer.json must bind-mount the host Claude credentials file"
grep -q 'HOME}/.codex/auth.json,target=/seed/codex-auth.json' "$DCJ" || \
    fail "devcontainer.json must bind-mount the host Codex auth file"
grep -qE 'HOME\}/\.(claude|codex),target=' "$DCJ" && \
    fail "devcontainer.json must NOT bind-mount the whole host ~/.claude or ~/.codex"
grep -q 'seed-claude-env\|seed-codex-env\|/seed/host-' "$DCJ" && \
    fail "devcontainer.json must not reference the removed host-config seeders"
grep -q 'install -m 600 /seed/claude-credentials.json' "$DCJ" || \
    fail "devcontainer.json postCreate must install the Claude credentials"
grep -q 'install -m 600 /seed/codex-auth.json' "$DCJ" || \
    fail "devcontainer.json postCreate must install the Codex auth file"
grep -q 'sync-agent-plugins.sh /workspace' "$DCJ" || \
    fail "devcontainer.json postCreate must install the engagement's declared plugins"

# up.sh must pre-check both credential files: they are --mount-style binds, so a
# missing source aborts `devcontainer up` with a raw docker error otherwise.
grep -q '.claude/.credentials.json' engagement-internal/.devcontainer/up.sh || \
    fail "up.sh must pre-check the host Claude credentials file"
grep -q '.codex/auth.json' engagement-internal/.devcontainer/up.sh || \
    fail "up.sh must pre-check the host Codex auth file"

# {{PLACEHOLDER}} markers should all be substituted
grep -q "{{" engagement-internal/.devcontainer/devcontainer.json && \
    fail "devcontainer.json still has unresolved {{PLACEHOLDER}}"
grep -q "{{" engagement-internal/.devcontainer/Dockerfile && \
    fail "Dockerfile still has unresolved {{PLACEHOLDER}}"

# Spot-check the actual substitutions
grep -q '"name": "pentest-engagement-internal"' engagement-internal/.devcontainer/devcontainer.json || \
    fail "devcontainer.json: name not substituted with activity_name"
grep -q '"INSTALL_GROUPS": "base,PD,tomnomnom,recon,cracking,RT,utils,AI"' engagement-internal/.devcontainer/devcontainer.json || \
    fail "devcontainer.json: INSTALL_GROUPS not substituted for internal profile"
grep -q '"CUSTOM_TOOLS_REF": "main"' engagement-internal/.devcontainer/devcontainer.json || \
    fail "devcontainer.json: CUSTOM_TOOLS_REF default 'main' not substituted"
grep -q '"BASE_IMAGE": "debian:trixie-slim"' engagement-internal/.devcontainer/devcontainer.json || \
    fail "devcontainer.json: BASE_IMAGE default 'debian:trixie-slim' not substituted"
pass ".devcontainer/ scaffolded with all placeholders substituted (internal profile, default base)"

# Canonical PT control plane is scaffolded and executable.
test -x engagement-internal/db/ptctl.py || fail "db/ptctl.py missing or not executable"
python3 engagement-internal/db/ptctl.py --help | grep -q observation || \
    fail "db/ptctl.py help should expose the observation workflow"
python3 engagement-internal/db/ptctl.py --help | grep -q context || \
    fail "db/ptctl.py help should expose progressive context"
test -f engagement-internal/PT_PLAYBOOK.md || fail "on-demand PT_PLAYBOOK.md missing"
test -f engagement-internal/.context/handoff.md || fail "initial session handoff missing"
test -f engagement-internal/.context/state.json || fail "initial session delta state missing"
grep -qx 'active.json' engagement-internal/.context/.gitignore || \
    fail "ephemeral active session marker should be git-ignored"
jq -e '.version == 1 and .artifacts == {}' \
    engagement-internal/.context/state.json >/dev/null || \
    fail "initial session delta state is invalid"
[ "$(wc -c < engagement-internal/AGENTS.md)" -lt 12000 ] || \
    fail "always-on AGENTS.md should remain below 12 KB"
python3 engagement-internal/db/ptctl.py session check >/dev/null || \
    fail "fresh scaffold handoff should be current"
fresh_boot="$(python3 engagement-internal/db/ptctl.py context boot)"
grep -q 'Freshness.*current' <<<"$fresh_boot" || \
    fail "fresh scaffold boot should mark the handoff current"
grep -q 'STALE' <<<"$fresh_boot" && \
    fail "fresh scaffold boot should not report a stale handoff"
python3 engagement-internal/db/ptctl.py session delta | \
    grep -q 'Capture gate: not required' || \
    fail "fresh scaffold should have no capture gate"
pass "transactional PT control plane and compact initial context scaffolded"

# --- Test 5b: explicit 'kali' base flips BASE_IMAGE to kalilinux/kali-rolling ---
cd "$TMP"
rm -rf engagement-kali
bash "$SCRIPT" lite engagement-kali kali >/dev/null
grep -q '"BASE_IMAGE": "kalilinux/kali-rolling"' engagement-kali/.devcontainer/devcontainer.json || \
    fail "devcontainer.json: BASE_IMAGE not substituted to kalilinux/kali-rolling for kali base"
grep -q "{{" engagement-kali/.devcontainer/devcontainer.json && \
    fail "kali devcontainer.json still has unresolved {{PLACEHOLDER}}"
pass "kali base scaffolds with BASE_IMAGE=kalilinux/kali-rolling"

# --- Test 5c: unknown base name aborts with helpful message ---
if bash "$SCRIPT" lite engagement-bogus alpine 2>/tmp/np.err; then
    fail "expected exit 1 for unknown base 'alpine', got exit 0"
fi
grep -q "unknown base" /tmp/np.err || fail "stderr should mention 'unknown base'"
grep -q "alpine" /tmp/np.err || fail "stderr should name the offending base"
pass "unknown base name exits 1 with helpful stderr"

# --- Test 5d: the image always lands the CURRENT Claude Code release ---
# The engagement Dockerfile refreshes Claude Code in a thin trailing layer,
# keyed on the scaffold date. Two properties make that work, and both are
# asserted here because breaking either silently ships a stale agent:
#   1. the refresh RUN must come AFTER the heavy install-offsec-tools.sh layer,
#      or a changed cache key would invalidate the 30-minute toolchain build;
#   2. CLAUDE_REFRESH must carry a per-scaffold value, or BuildKit reuses the
#      cached layer and the new engagement inherits an old release.
cd "$TMP"
dockerfile="engagement-internal/.devcontainer/Dockerfile"
grep -q '^ARG CLAUDE_CHANNEL=' "$dockerfile" || \
    fail "Dockerfile must declare ARG CLAUDE_CHANNEL"
grep -q '^ARG CLAUDE_REFRESH=' "$dockerfile" || \
    fail "Dockerfile must declare ARG CLAUDE_REFRESH (the refresh layer's cache key)"
grep -q -- '--claude-only=' "$dockerfile" || \
    fail "Dockerfile refresh layer must call install-offsec-tools.sh --claude-only=<channel>"
grep -q '\${CLAUDE_REFRESH}' "$dockerfile" || \
    fail "the refresh RUN must reference \${CLAUDE_REFRESH}, or BuildKit ignores the cache key"
# The refresh layer must re-sync the clone before invoking it. CUSTOM_TOOLS_REF
# is a moving ref, but the cached layer above pins whatever commit was HEAD when
# it was first built — running that outdated script fails the build outright
# (a pre-merge copy does not know --claude-only). Needs the ssh mount: private repo.
grep -q 'git -C /home/pentester/custom-tools fetch' "$dockerfile" || \
    fail "the refresh layer must re-sync the custom-tools clone (cached layer pins a stale commit)"
grep -q 'reset --hard FETCH_HEAD' "$dockerfile" || \
    fail "the refresh layer must reset the clone to the fetched ref"
awk '/--claude-only=/{exit found?0:1} /--mount=type=ssh/{found=1}' "$dockerfile" || \
    fail "the refresh layer needs --mount=type=ssh to fetch from the private repo"
main_layer="$(grep -n 'install-offsec-tools.sh \\$' "$dockerfile" | head -1 | cut -d: -f1)"
refresh_layer="$(grep -n -- '--claude-only=' "$dockerfile" | head -1 | cut -d: -f1)"
[ -n "$main_layer" ] && [ -n "$refresh_layer" ] && [ "$main_layer" -lt "$refresh_layer" ] || \
    fail "the Claude refresh layer must come AFTER the toolchain layer (main=$main_layer refresh=$refresh_layer)"
# Never resurrect the root-owned npm global install: it cannot self-update.
grep -q 'npm install -g @anthropic-ai/claude-code' "$dockerfile" && \
    fail "Dockerfile must not install Claude Code via npm -g (breaks the autoupdater)"
# Build args carry the channel and a dated (per-scaffold) refresh key.
dcjson="engagement-internal/.devcontainer/devcontainer.json"
grep -q '"CLAUDE_CHANNEL": "latest"' "$dcjson" || \
    fail "devcontainer.json must default CLAUDE_CHANNEL to 'latest'"
grep -qE '"CLAUDE_REFRESH": "[0-9]{4}-[0-9]{2}-[0-9]{2}"' "$dcjson" || \
    fail "devcontainer.json CLAUDE_REFRESH must be the scaffold date (YYYY-MM-DD)"
pass "Dockerfile refreshes Claude Code in a thin trailing layer keyed on the scaffold date"

# --- Test 5e: auto-update is on by default and documented as switchable ---
grep -q 'DISABLE_AUTOUPDATER' engagement-internal/.devcontainer/Dockerfile || \
    fail "Dockerfile should document the DISABLE_AUTOUPDATER escape hatch"
output="$(bash "$SCRIPT" lite engagement-autoupd)" || fail "newPT.sh lite engagement-autoupd failed"
echo "$output" | grep -q "claude:[[:space:]]*latest" || \
    fail "post-scaffold output should name the Claude Code channel"
echo "$output" | grep -q "DISABLE_AUTOUPDATER" || \
    fail "post-scaffold output should point at the auto-update off-switch"
pass "auto-update on by default, off-switch surfaced at scaffold time"

# --- Test 5g: up.sh --pull forces a freshly pulled base image ---
# `FROM <tag>` resolves the LOCAL tag and docker never re-resolves it, so both
# moving bases (debian:trixie-slim, kalilinux/kali-rolling) can silently stay
# months old. `devcontainer up` has no --pull, so up.sh pulls the tag itself.
upsh="engagement-internal/.devcontainer/up.sh"
grep -q -- '--pull)' "$upsh" || fail "up.sh must accept a --pull flag"
grep -q 'docker pull "\$base_image"' "$upsh" || \
    fail "up.sh --pull must pull the base image before building"
grep -q 'base_image="debian:trixie-slim"' "$upsh" || \
    fail "up.sh: BASE_IMAGE not substituted at scaffold time"
grep -q 'container_name="engagement-internal"' "$upsh" || \
    fail "up.sh: ACTIVITY_NAME not substituted (needed for the existing-container guard)"
grep -q 'docker container inspect' "$upsh" || \
    fail "up.sh --pull must refuse when the container already exists (up would skip the build)"
# Go-template braces would trip the no-{{PLACEHOLDER}} assertion in Test 6h,
# so the digest comparison must not use `docker inspect -f`.
grep -q 'docker images --no-trunc --quiet' "$upsh" || \
    fail "up.sh should compare digests via 'docker images --no-trunc --quiet' (no {{ }} templates)"
# Both YOLO launchers forward flags so `./yolo.sh --pull` works.
grep -q 'up.sh "\$@"' engagement-internal/yolo.sh || \
    fail "yolo.sh must forward its arguments to up.sh (./yolo.sh --pull)"
grep -q 'up.sh "\$@"' engagement-internal/yolo-codex.sh || \
    fail "yolo-codex.sh must forward its arguments to up.sh"
pass "up.sh --pull rebuilds on a freshly pulled base; both launchers forward it"

# --- Test 5f: CLAUDE_CHANNEL env override pins the release (reproducible engagements) ---
cd "$TMP"
rm -rf engagement-pinned
CLAUDE_CHANNEL="2.1.263" bash "$SCRIPT" lite engagement-pinned >/dev/null
grep -q '"CLAUDE_CHANNEL": "2.1.263"' engagement-pinned/.devcontainer/devcontainer.json || \
    fail "CLAUDE_CHANNEL env override should flow into the devcontainer build args"
cd "$TMP"
pass "CLAUDE_CHANNEL env override pins the Claude Code release at scaffold time"

# --- Test 6: scaffolding drops .claude/settings.json with the plugin allowlist ---
SET=engagement-internal/.claude/settings.json
test -f "$SET" || fail ".claude/settings.json missing"
grep -q "bypassPermissions" "$SET" || \
    fail ".claude/settings.json should contain bypassPermissions"
grep -q "SessionStart" "$SET" || \
    fail ".claude/settings.json should define a SessionStart hook"
jq -e . "$SET" >/dev/null || fail ".claude/settings.json must stay valid JSON after injection"
# Everything the template carries verbatim must survive the plugin injection.
jq -e '.hooks.PreToolUse and .permissions.defaultMode == "bypassPermissions"' "$SET" >/dev/null || \
    fail ".claude/settings.json lost template content during plugin injection"
# internal => one plugin, and the marketplace it comes from, resolved to a source
jq -e '.enabledPlugins == {"fp-check@trailofbits": true}' "$SET" >/dev/null || \
    fail ".claude/settings.json must carry the internal profile's plugin allowlist"
jq -e '.extraKnownMarketplaces.trailofbits.source.repo == "trailofbits/skills"' "$SET" >/dev/null || \
    fail ".claude/settings.json must declare the marketplace each plugin comes from"
pass ".claude/settings.json scaffolded with the engagement's plugin allowlist"

# --- Test 6a: a type with no default plugins still shows the empty placeholders ---
cd "$TMP"
rm -rf engagement-lite
bash "$SCRIPT" lite engagement-lite >/dev/null
jq -e '.enabledPlugins == {}' engagement-lite/.claude/settings.json >/dev/null || \
    fail "a no-plugin type must scaffold an empty enabledPlugins placeholder"
# The base marketplace is declared regardless: that is what makes it browsable
# in /plugin and installable by name mid-engagement.
jq -e '.extraKnownMarketplaces.trailofbits.source.repo == "trailofbits/skills"' \
    engagement-lite/.claude/settings.json >/dev/null || \
    fail "every engagement must declare the base marketplace, plugins or not"
pass "no-plugin types keep the base marketplace and an empty allowlist"
cd "$TMP"

# --- Test 6b: .claude/hooks/ carries shared + Claude-only scripts, executable ---
for h in log-command render-after-db engagement-doctor check-report-format; do
    test -x "engagement-internal/.claude/hooks/$h.sh" || \
        fail ".claude/hooks/$h.sh missing or not executable"
done
grep -q 'context boot --include-rules --max-chars 16000' engagement-internal/.claude/settings.json || \
    fail "Claude SessionStart should bridge bounded hard rules"
grep -q 'session start --client claude --quiet' engagement-internal/.claude/settings.json || \
    fail "Claude SessionStart should open the capture gate"
grep -q 'journal.md\\|ptctl.py board\\|cat /workspace/TODO.md' engagement-internal/.claude/settings.json && \
    fail "Claude SessionStart must not preload journal, full TODO, or board"
jq -e '.hooks.Stop' engagement-internal/.claude/settings.json >/dev/null || \
    fail "Claude settings must run the anti-drift Stop hook"
pass ".claude/hooks/ has bounded boot + anti-drift lifecycle hooks"

# --- Test 6c: .codex/ scaffolded (config.toml + hooks.json + shared hooks) ---
test -f engagement-internal/.codex/config.toml || fail ".codex/config.toml missing"
grep -q 'approval_policy *= *"never"'           engagement-internal/.codex/config.toml || \
    fail ".codex/config.toml must set approval_policy = never"
grep -q 'sandbox_mode *= *"danger-full-access"' engagement-internal/.codex/config.toml || \
    fail ".codex/config.toml must set sandbox_mode = danger-full-access"

test -f engagement-internal/.codex/hooks.json || fail ".codex/hooks.json missing"
jq -e . engagement-internal/.codex/hooks.json >/dev/null || fail ".codex/hooks.json is not valid JSON"
jq -e '.hooks.SessionStart and .hooks.PreToolUse and .hooks.PostToolUse and .hooks.Stop' \
    engagement-internal/.codex/hooks.json >/dev/null || \
    fail ".codex/hooks.json must define SessionStart, PreToolUse, PostToolUse, Stop"
grep -q 'check-report-format' engagement-internal/.codex/hooks.json && \
    fail ".codex/hooks.json must NOT reference the Claude-only report-format hook"
grep -q 'context boot --max-chars 16000' engagement-internal/.codex/hooks.json || \
    fail "Codex SessionStart should load bounded context"
grep -q 'session start --client codex --quiet' engagement-internal/.codex/hooks.json || \
    fail "Codex SessionStart should open the capture gate"
grep -q -- '--include-rules' engagement-internal/.codex/hooks.json && \
    fail "Codex SessionStart must not duplicate native AGENTS.md"
grep -q 'journal.md\\|ptctl.py board\\|cat /workspace/TODO.md' engagement-internal/.codex/hooks.json && \
    fail "Codex SessionStart must not preload journal, full TODO, or board"

for h in log-command render-after-db engagement-doctor; do
    test -x "engagement-internal/.codex/hooks/$h.sh" || fail ".codex/hooks/$h.sh missing or not executable"
    diff -q "engagement-internal/.codex/hooks/$h.sh" "engagement-internal/.claude/hooks/$h.sh" >/dev/null || \
        fail "$h.sh differs between .codex/ and .claude/ (should be one shared source)"
done
pass ".codex/ scaffolded: native rules + bounded boot + shared Stop checks"

# --- Test 6d: .mcp.json wires the Burp MCP server for Claude (native SSE) ---
test -f engagement-internal/.mcp.json || fail ".mcp.json missing at engagement root"
jq -e . engagement-internal/.mcp.json >/dev/null || fail ".mcp.json is not valid JSON"
jq -e '.mcpServers.burp.type == "sse"' engagement-internal/.mcp.json >/dev/null || \
    fail ".mcp.json must declare mcpServers.burp with type=sse"
jq -e '.mcpServers.burp.url == "http://127.0.0.1:9876"' engagement-internal/.mcp.json >/dev/null || \
    fail ".mcp.json burp.url must be the default Burp MCP endpoint (SSE at root, no /sse)"
grep -q "{{" engagement-internal/.mcp.json && fail ".mcp.json still has an unresolved {{PLACEHOLDER}}"
pass ".mcp.json scaffolded with the Burp MCP server (native SSE, URL substituted)"

# --- Test 6e: settings.json auto-approves project MCP servers (yolo-safe) ---
jq -e '.enableAllProjectMcpServers == true' engagement-internal/.claude/settings.json >/dev/null || \
    fail ".claude/settings.json must set enableAllProjectMcpServers=true"
# Both prompts must be pre-accepted at PROJECT scope: the host's ~/.claude is no
# longer copied into the container, so nothing else pre-accepts them and
# ./yolo.sh would stop on the bypass-permissions dialog.
jq -e '.skipDangerousModePermissionPrompt == true' engagement-internal/.claude/settings.json >/dev/null || \
    fail ".claude/settings.json must set skipDangerousModePermissionPrompt=true"
pass ".claude/settings.json enables project MCP servers (no trust prompt in yolo)"

# --- Test 6f: BURP_MCP_URL env override flows into .mcp.json ---
cd "$TMP"
rm -rf engagement-burpurl
BURP_MCP_URL="http://127.0.0.1:18080" bash "$SCRIPT" lite engagement-burpurl >/dev/null
jq -e '.mcpServers.burp.url == "http://127.0.0.1:18080"' engagement-burpurl/.mcp.json >/dev/null || \
    fail "BURP_MCP_URL override should flow into .mcp.json"
cd "$TMP"
pass "BURP_MCP_URL env override is honored at scaffold time"

# --- Test 6g: Codex Burp MCP is registered into the container's GLOBAL config via
# postCreate. Codex 0.144.6 ignores project-scoped mcp_servers (verified), so the
# .codex/config.toml must NOT declare it; the server is added by `codex mcp add`. ---
grep -q 'codex mcp add burp' engagement-internal/.devcontainer/devcontainer.json || \
    fail "devcontainer.json postCreate must register the Burp MCP server for Codex"
grep -q 'mcp-remote' engagement-internal/.devcontainer/devcontainer.json || \
    fail "devcontainer.json codex mcp add must use the mcp-remote bridge"
grep -q 'mcp-remote http://127.0.0.1:9876' engagement-internal/.devcontainer/devcontainer.json || \
    fail "devcontainer.json codex mcp add must carry the substituted Burp MCP URL"
grep -q '\[mcp_servers.burp\]' engagement-internal/.codex/config.toml && \
    fail ".codex/config.toml must NOT declare [mcp_servers.burp] (Codex ignores project mcp_servers)"
pass "Codex Burp MCP registered via postCreate codex mcp add (global config)"

# --- Test 6h: up.sh carries a non-blocking Burp MCP reachability probe ---
test -f engagement-internal/.devcontainer/up.sh || fail ".devcontainer/up.sh missing"
grep -q 'Burp MCP endpoint' engagement-internal/.devcontainer/up.sh || \
    fail "up.sh must warn when the Burp MCP endpoint is unreachable"
grep -q 'http://127.0.0.1:9876' engagement-internal/.devcontainer/up.sh || \
    fail "up.sh probe must carry the substituted Burp MCP URL"
grep -q "{{" engagement-internal/.devcontainer/up.sh && \
    fail "up.sh still has an unresolved {{PLACEHOLDER}}"
pass "up.sh scaffolded with a non-blocking Burp MCP reachability probe"

# --- Test 6i: AGENTS.md documents the pre-wired Burp MCP channel ---
grep -q 'Burp MCP' engagement-internal/AGENTS.md || \
    fail "AGENTS.md must document the pre-wired Burp MCP channel"
pass "AGENTS.md documents the Burp MCP channel and scope caution"

# --- Test 7: verbose post-scaffold output names type, groups, Dockerfile, next-step cmds ---
cd "$TMP"
rm -rf engagement-cloud
output="$(bash "$SCRIPT" cloud engagement-cloud)" || fail "newPT.sh cloud engagement-cloud failed"
echo "$output" | grep -q "type:[[:space:]]*cloud"                  || fail "output should name the type"
echo "$output" | grep -q "groups:[[:space:]]*base,cloud,utils"     || fail "output should print the resolved groups"
echo "$output" | grep -q "base:[[:space:]]*debian"                 || fail "output should print the resolved base"
echo "$output" | grep -q "engagement-cloud/.devcontainer/Dockerfile" || fail "output should print the Dockerfile path"
echo "$output" | grep -q "up.sh"                                   || fail "output should suggest the .devcontainer/up.sh wrapper"
echo "$output" | grep -q "Reopen in Container"                     || fail "output should mention the VS Code 'Reopen in Container' alternative"
pass "verbose post-scaffold output covers type, groups, base, Dockerfile, next steps"

# --- Test 8: render.sh resolves <activity>.md by marker, not by folder name ---
# Regression: inside the devcontainer the engagement is bind-mounted at /workspace,
# so a basename-derived name looked for workspace.md and failed. render.sh must
# find the activity file by its db:render marker regardless of the root dir name.
cd "$TMP"
rm -rf SN2026_Example workspace
bash "$SCRIPT" none SN2026_Example >/dev/null || fail "newPT.sh none SN2026_Example failed"
mv SN2026_Example workspace        # mimic the /workspace bind-mount
render_out="$(bash workspace/db/render.sh)" || fail "render.sh failed under a 'workspace' root"
echo "$render_out" | grep -q "SN2026_Example.md" || \
    fail "render.sh should resolve the activity file by marker, got: $render_out"
if [ -e workspace/workspace.md ]; then fail "render.sh must not create/expect workspace.md"; fi
pass "render.sh resolves <activity>.md by db:render marker even when root is /workspace"

# --- Test 9: no host agent-config seeding survives anywhere in org/ ---
# The host's ~/.claude / ~/.codex are no longer imported: the per-engagement
# plugin/marketplace/MCP set is declared in the engagement, so nothing may copy
# the operator's own agent config into the container.
ORG_DIR="$(dirname "$SCRIPT")"
test -e "$ORG_DIR/seed-claude-env.sh" && fail "org/seed-claude-env.sh must be gone"
test -e "$ORG_DIR/seed-codex-env.sh"  && fail "org/seed-codex-env.sh must be gone"
if grep -rn 'seed-claude-env\|seed-codex-env\|/seed/host-' "$ORG_DIR" >/dev/null 2>&1; then
    fail "org/ still references the removed host-config seeders"
fi
pass "host agent-config seeding fully removed from org/"

# --- Test 10: sync-agent-plugins.sh plans exactly what settings.json declares ---
# It is the only thing that turns the declared allowlist into installed plugins
# (declaring alone materialises the cache but never loads the plugin), so its
# plan must match the settings file row for row. --dry-run touches no network.
SYNC="$ORG_DIR/sync-agent-plugins.sh"
test -x "$SYNC" || fail "org/sync-agent-plugins.sh must exist and be executable"

cd "$TMP"
rm -rf engagement-sync
bash "$SCRIPT" web engagement-sync >/dev/null
plan="$(bash "$SYNC" engagement-sync --dry-run)" || fail "sync --dry-run failed"
echo "$plan" | grep -q 'would run: claude plugin marketplace add trailofbits/skills --scope project' || \
    fail "plan must register each declared marketplace at project scope"
for p in burpsuite-project-parser fp-check; do
    echo "$plan" | grep -q "would run: claude plugin install $p@trailofbits --scope project -y" || \
        fail "plan must install declared plugin $p at project scope"
done
echo "$plan" | grep -q "would run: codex plugin add burpsuite-project-parser@trailofbits" || \
    fail "plan must apply the same list to Codex"

# An entry set to false is declared-but-off and must not be installed.
jq '.enabledPlugins["fp-check@trailofbits"] = false' \
    engagement-sync/.claude/settings.json > "$TMP/s.json" && \
    mv "$TMP/s.json" engagement-sync/.claude/settings.json
bash "$SYNC" engagement-sync --dry-run | grep -q 'install fp-check@trailofbits' && \
    fail "a plugin set to false must not be installed"

# No allowlist at all: exit 0 with nothing to do (cloud/mobile/lite/none types).
rm -rf engagement-sync-empty
bash "$SCRIPT" lite engagement-sync-empty >/dev/null
out="$(bash "$SYNC" engagement-sync-empty --dry-run)" || fail "empty allowlist should exit 0"
echo "$out" | grep -q 'none enabled' || fail "empty allowlist should say nothing is enabled"
echo "$out" | grep -q 'would run: claude plugin marketplace add trailofbits/skills' || \
    fail "an empty allowlist must still register the base marketplace"
echo "$out" | grep -q 'plugin install' && \
    fail "an empty allowlist must not install anything"

# Wrong directory: refuse instead of silently doing nothing.
if bash "$SYNC" "$TMP/not-an-engagement" --dry-run 2>/dev/null; then
    fail "sync must exit non-zero when there is no .claude/settings.json"
fi
pass "sync-agent-plugins.sh plans exactly the declared allowlist (and refuses a bad dir)"

# --- Test 11: a typo in the newPT.sh plugin tables fails at scaffold time ---
# marketplace_source() must know every marketplace referenced by a default list;
# otherwise the mistake would only surface inside the container's postCreate.
grep -q 'no marketplace source known' "$SCRIPT" || \
    fail "newPT.sh must validate that every plugin's marketplace resolves to a source"
grep -q 'unknown plugin group' "$SCRIPT" || \
    fail "newPT.sh must reject a plugin group name that does not resolve"
pass "newPT.sh validates its plugin tables before scaffolding"

rm -f /tmp/np.err
echo "All tests passed."
