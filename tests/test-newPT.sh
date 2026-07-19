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

# devcontainer.json mounts host ~/.codex and seeds it on postCreate
grep -q 'target=/seed/host-codex' engagement-internal/.devcontainer/devcontainer.json || \
    fail "devcontainer.json must bind-mount host ~/.codex to /seed/host-codex"
grep -q 'seed-codex-env.sh apply /seed/host-codex' engagement-internal/.devcontainer/devcontainer.json || \
    fail "devcontainer.json postCreate must seed Codex config"

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

# --- Test 6: scaffolding drops .claude/settings.json verbatim ---
test -f engagement-internal/.claude/settings.json || fail ".claude/settings.json missing"
grep -q "bypassPermissions" engagement-internal/.claude/settings.json || \
    fail ".claude/settings.json should contain bypassPermissions"
grep -q "SessionStart" engagement-internal/.claude/settings.json || \
    fail ".claude/settings.json should define a SessionStart hook"
# Verify file is byte-identical to the template (no substitution applied)
diff -q engagement-internal/.claude/settings.json \
        "$(dirname "$SCRIPT")/templates/claude/settings.json" \
    >/dev/null || fail ".claude/settings.json should be a verbatim copy of the template"
pass ".claude/settings.json scaffolded verbatim from template"

# --- Test 6b: .claude/hooks/ carries all three scripts, executable ---
for h in log-command render-after-db check-report-format; do
    test -x "engagement-internal/.claude/hooks/$h.sh" || \
        fail ".claude/hooks/$h.sh missing or not executable"
done
pass ".claude/hooks/ has all three hook scripts (shared + claude-only), executable"

# --- Test 6c: .codex/ scaffolded (config.toml + hooks.json + shared hooks) ---
test -f engagement-internal/.codex/config.toml || fail ".codex/config.toml missing"
grep -q 'approval_policy *= *"never"'           engagement-internal/.codex/config.toml || \
    fail ".codex/config.toml must set approval_policy = never"
grep -q 'sandbox_mode *= *"danger-full-access"' engagement-internal/.codex/config.toml || \
    fail ".codex/config.toml must set sandbox_mode = danger-full-access"

test -f engagement-internal/.codex/hooks.json || fail ".codex/hooks.json missing"
jq -e . engagement-internal/.codex/hooks.json >/dev/null || fail ".codex/hooks.json is not valid JSON"
jq -e '.hooks.SessionStart and .hooks.PreToolUse and .hooks.PostToolUse' \
    engagement-internal/.codex/hooks.json >/dev/null || \
    fail ".codex/hooks.json must define SessionStart, PreToolUse, PostToolUse"
grep -q 'check-report-format' engagement-internal/.codex/hooks.json && \
    fail ".codex/hooks.json must NOT reference the Claude-only report-format hook"

for h in log-command render-after-db; do
    test -x "engagement-internal/.codex/hooks/$h.sh" || fail ".codex/hooks/$h.sh missing or not executable"
    diff -q "engagement-internal/.codex/hooks/$h.sh" "engagement-internal/.claude/hooks/$h.sh" >/dev/null || \
        fail "$h.sh differs between .codex/ and .claude/ (should be one shared source)"
done
pass ".codex/ scaffolded: config.toml + hooks.json (3 hooks, no report-format) + shared scripts"

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

# --- Test 9: seed-codex-env.sh export copies the allowlist, gates the secret ---
SEED="$(dirname "$SCRIPT")/seed-codex-env.sh"
cd "$TMP"
rm -rf fake-codex seed-out seed-out-creds
mkdir -p fake-codex/plugins fake-codex/skills fake-codex/rules fake-codex/prompts fake-codex/sessions
printf 'approval_policy = "on-request"\n' > fake-codex/config.toml
printf '# global\n'                        > fake-codex/AGENTS.md
printf '{"token":"secret"}\n'              > fake-codex/auth.json
printf 'dummy\n'                           > fake-codex/history.jsonl

# export WITHOUT credentials: allowlist copied, auth.json skipped, denylist skipped
CODEX_HOME="$TMP/fake-codex" bash "$SEED" export "$TMP/seed-out" >/dev/null || fail "seed export failed"
for item in config.toml plugins skills rules prompts AGENTS.md; do
    test -e "seed-out/$item" || fail "seed export should copy allowlist item: $item"
done
test -e seed-out/auth.json     && fail "seed export must NOT copy auth.json without --with-credentials"
test -e seed-out/history.jsonl && fail "seed export must NOT copy denylist item history.jsonl"
test -e seed-out/sessions      && fail "seed export must NOT copy denylist dir sessions"
pass "seed-codex-env.sh export copies allowlist, skips secret + state"

# export WITH credentials: auth.json included, mode 600
CODEX_HOME="$TMP/fake-codex" bash "$SEED" export "$TMP/seed-out-creds" --with-credentials >/dev/null || \
    fail "seed export --with-credentials failed"
test -e seed-out-creds/auth.json || fail "--with-credentials should copy auth.json"
[ "$(stat -c '%a' seed-out-creds/auth.json)" = "600" ] || fail "auth.json should be chmod 600 in the seed"
pass "seed-codex-env.sh --with-credentials includes auth.json (600)"

rm -f /tmp/np.err
echo "All tests passed."
