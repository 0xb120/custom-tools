# Burp MCP Scaffolding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `org/newPT.sh` scaffold every engagement with the Burp Suite MCP server pre-wired for both Claude Code (native SSE) and Codex (via the `mcp-remote` stdio bridge), reaching a host-side Burp through the container's `--network=host`.

**Architecture:** Burp runs on the host with PortSwigger's "MCP Server" extension exposing SSE at `{{BURP_MCP_URL}}` (default `http://127.0.0.1:9876/sse`). The container reaches host loopback because of `--network=host`. Claude declares an `sse` server in a project-scoped `.mcp.json`; Codex declares a stdio server in `.codex/config.toml` that spawns `npx -y mcp-remote <url>`. `newPT.sh` injects the endpoint URL into all files via one placeholder (`{{BURP_MCP_URL}}`), overridable at scaffold time with the `BURP_MCP_URL` env var.

**Tech Stack:** bash, sed, jq (test assertions), npm (bridge pre-install), devcontainer CLI (runtime only).

## Global Constraints

- Endpoint placeholder is `{{BURP_MCP_URL}}`; default value `http://127.0.0.1:9876/sse`; overridable via env var `BURP_MCP_URL` at scaffold time.
- Every scaffolded file must have all `{{...}}` placeholders substituted — a residual `{{` in an output file is a failure (existing test convention).
- Activation is unconditional: the Burp MCP is wired for **all** engagement types. No conditional branches keyed on `<type>`.
- Reachability check is **advisory only** — it must warn and continue, never abort the launcher, never hang on the SSE stream.
- Template content stays terse and placeholder-free in prose (template-terseness convention): rules over examples, no concrete client IPs/sites.
- Tests live in `tests/test-newPT.sh` and `tests/test-install-offsec-tools.sh`; run with `bash tests/<file>`. Style: linear script, `fail`/`pass` helpers, scaffold into `mktemp -d`.
- Reference for all decisions: `docs/superpowers/specs/2026-07-20-burp-mcp-scaffolding-design.md`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `org/templates/devcontainer/mcp.json` | Claude project MCP registry (one `sse` server `burp`) | **create** |
| `org/templates/claude/settings.json` | Claude engagement config | **modify** (add `enableAllProjectMcpServers`) |
| `org/templates/codex/config.toml` | Codex engagement config | **modify** (add `[mcp_servers.burp]`) |
| `org/templates/devcontainer/up.sh` | Launcher pre-flight | **modify** (add reachability probe) |
| `org/templates/AGENTS.md` | Engagement rules doc | **modify** (add Burp MCP note) |
| `org/newPT.sh` | Scaffolder | **modify** (`BURP_MCP_URL` var, copy `.mcp.json`, URL sed) |
| `org/install-offsec-tools.sh` | Toolchain installer | **modify** (`install_AI` pre-installs `mcp-remote`) |
| `tests/test-newPT.sh` | Scaffold assertions | **modify** |
| `tests/test-install-offsec-tools.sh` | Installer assertions | **modify** |

---

## Task 1: Claude MCP wiring (`.mcp.json` + settings flag + `newPT.sh` plumbing)

Introduces the `BURP_MCP_URL` variable and the URL-substitution mechanism, plus Claude's project MCP registry.

**Files:**
- Create: `org/templates/devcontainer/mcp.json`
- Modify: `org/templates/claude/settings.json`
- Modify: `org/newPT.sh` (after `CUSTOM_TOOLS_REF="main"` at :124; new MCP block before the final `cat <<EOF` at :180)
- Test: `tests/test-newPT.sh`

**Interfaces:**
- Produces: env var `BURP_MCP_URL` (default `http://127.0.0.1:9876/sse`); the scaffolded file `<activity>/.mcp.json`; a `sed -i "s|{{BURP_MCP_URL}}|$BURP_MCP_URL|g"` pass that later tasks extend with more files.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-newPT.sh` immediately after Test 6c's `pass` line (`.codex/ scaffolded: ...`, at :162):

```bash
# --- Test 6d: .mcp.json wires the Burp MCP server for Claude (native SSE) ---
test -f engagement-internal/.mcp.json || fail ".mcp.json missing at engagement root"
jq -e . engagement-internal/.mcp.json >/dev/null || fail ".mcp.json is not valid JSON"
jq -e '.mcpServers.burp.type == "sse"' engagement-internal/.mcp.json >/dev/null || \
    fail ".mcp.json must declare mcpServers.burp with type=sse"
jq -e '.mcpServers.burp.url == "http://127.0.0.1:9876/sse"' engagement-internal/.mcp.json >/dev/null || \
    fail ".mcp.json burp.url must be the default Burp MCP endpoint"
grep -q "{{" engagement-internal/.mcp.json && fail ".mcp.json still has an unresolved {{PLACEHOLDER}}"
pass ".mcp.json scaffolded with the Burp MCP server (native SSE, URL substituted)"

# --- Test 6e: settings.json auto-approves project MCP servers (yolo-safe) ---
jq -e '.enableAllProjectMcpServers == true' engagement-internal/.claude/settings.json >/dev/null || \
    fail ".claude/settings.json must set enableAllProjectMcpServers=true"
pass ".claude/settings.json enables project MCP servers (no trust prompt in yolo)"

# --- Test 6f: BURP_MCP_URL env override flows into .mcp.json ---
cd "$TMP"
rm -rf engagement-burpurl
BURP_MCP_URL="http://127.0.0.1:18080/sse" bash "$SCRIPT" lite engagement-burpurl >/dev/null
jq -e '.mcpServers.burp.url == "http://127.0.0.1:18080/sse"' engagement-burpurl/.mcp.json >/dev/null || \
    fail "BURP_MCP_URL override should flow into .mcp.json"
cd "$TMP"
pass "BURP_MCP_URL env override is honored at scaffold time"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-newPT.sh`
Expected: FAIL at `.mcp.json missing at engagement root` (the file isn't scaffolded yet).

- [ ] **Step 3: Create the `.mcp.json` template**

Create `org/templates/devcontainer/mcp.json`:

```json
{
  "mcpServers": {
    "burp": {
      "type": "sse",
      "url": "{{BURP_MCP_URL}}"
    }
  }
}
```

- [ ] **Step 4: Add the `enableAllProjectMcpServers` flag to Claude settings**

In `org/templates/claude/settings.json`, add the flag as the first top-level key. Change the opening:

```json
{
  "permissions": {
```

to:

```json
{
  "enableAllProjectMcpServers": true,
  "permissions": {
```

- [ ] **Step 5: Add `BURP_MCP_URL` and the MCP wiring block to `newPT.sh`**

In `org/newPT.sh`, after the line `CUSTOM_TOOLS_REF="main"` (:124), insert:

```bash

# Burp Suite MCP endpoint (SSE) both agents connect to. Burp runs on the HOST
# with the "MCP Server" extension; the container reaches it via --network=host.
# Overridable at scaffold time: BURP_MCP_URL=http://host:port/sse bash newPT.sh ...
BURP_MCP_URL="${BURP_MCP_URL:-http://127.0.0.1:9876/sse}"
```

Then, immediately before the final `cat <<EOF` block (:180), insert:

```bash
# --- Burp MCP wiring (both agents) -----------------------------------------
# .mcp.json is Claude's project-scoped MCP registry (native SSE). The Codex
# entry lives in .codex/config.toml, and up.sh carries a reachability probe;
# both gain the {{BURP_MCP_URL}} placeholder in later steps. Inject the endpoint.
cp "$template_dir/devcontainer/mcp.json" "$activity_name/.mcp.json"
sed -i "s|{{BURP_MCP_URL}}|$BURP_MCP_URL|g" \
    "$activity_name/.mcp.json"

```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/test-newPT.sh`
Expected: PASS — including the new `6d`, `6e`, `6f` lines; all prior tests still PASS (Test 6's `diff -q` against the template still holds because the template itself changed).

- [ ] **Step 7: Commit**

```bash
git add org/templates/devcontainer/mcp.json org/templates/claude/settings.json org/newPT.sh tests/test-newPT.sh
git commit -m "feat(newPT): wire Burp MCP for Claude via project .mcp.json"
```

---

## Task 2: Codex MCP wiring (`config.toml` + `mcp-remote` install + `newPT.sh` sed)

**Files:**
- Modify: `org/templates/codex/config.toml`
- Modify: `org/install-offsec-tools.sh` (`install_AI`, after the Codex block at :813)
- Modify: `org/newPT.sh` (extend the URL `sed` file list added in Task 1)
- Test: `tests/test-newPT.sh`, `tests/test-install-offsec-tools.sh`

**Interfaces:**
- Consumes: `BURP_MCP_URL` and the `sed -i "s|{{BURP_MCP_URL}}|...|g"` pass from Task 1.
- Produces: `[mcp_servers.burp]` in the scaffolded `.codex/config.toml`, invoking `npx -y mcp-remote <url>`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test-newPT.sh` immediately after the Test 6f `pass` line from Task 1:

```bash
# --- Test 6g: .codex/config.toml wires Burp via the mcp-remote stdio bridge ---
grep -q '\[mcp_servers.burp\]' engagement-internal/.codex/config.toml || \
    fail ".codex/config.toml must declare [mcp_servers.burp]"
grep -q 'mcp-remote' engagement-internal/.codex/config.toml || \
    fail ".codex/config.toml burp server must invoke the mcp-remote bridge"
grep -q 'http://127.0.0.1:9876/sse' engagement-internal/.codex/config.toml || \
    fail ".codex/config.toml must carry the substituted Burp MCP URL"
grep -q "{{" engagement-internal/.codex/config.toml && \
    fail ".codex/config.toml still has an unresolved {{PLACEHOLDER}}"
pass ".codex/config.toml scaffolded with the Burp MCP bridge (URL substituted)"
```

Add to `tests/test-install-offsec-tools.sh` immediately before the final `echo "All tests passed."` (:66):

```bash
# --- Test 7: install_AI pre-installs the mcp-remote bridge (Codex <-> Burp MCP) ---
grep -q 'npm install -g mcp-remote' "$SCRIPT" || \
    fail "install_AI must pre-install mcp-remote (Codex Burp MCP bridge)"
pass "install_AI pre-installs mcp-remote"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/test-newPT.sh`
Expected: FAIL at `.codex/config.toml must declare [mcp_servers.burp]`.
Run: `bash tests/test-install-offsec-tools.sh`
Expected: FAIL at `install_AI must pre-install mcp-remote ...`.

- [ ] **Step 3: Add the Burp server to the Codex config template**

Append to `org/templates/codex/config.toml` (after the existing deferred-hook NOTE comment):

```toml

# Burp Suite MCP server. Burp runs on the HOST with the "MCP Server" extension
# exposing SSE; the container reaches it via --network=host. Codex's native url
# transport is Streamable-HTTP (uncertain against Burp's SSE), so we bridge with
# mcp-remote (node; pre-installed in the image, npx -y falls back to a fetch).
[mcp_servers.burp]
command = "npx"
args    = ["-y", "mcp-remote", "{{BURP_MCP_URL}}"]
```

- [ ] **Step 4: Pre-install `mcp-remote` in `install_AI`**

In `org/install-offsec-tools.sh`, inside `install_AI`, after the Codex install block (the `fi` at :813) and before the sgpt comment (:815), insert:

```bash

    # mcp-remote — node stdio<->SSE/HTTP bridge. Codex reaches the host's Burp
    # MCP (SSE) through it; pre-installed so `npx -y mcp-remote` resolves without
    # a first-run fetch. Global npm bins land on the image PATH (/usr/local/bin).
    sudo npm install -g mcp-remote
```

- [ ] **Step 5: Add `.codex/config.toml` to the URL sed list in `newPT.sh`**

In `org/newPT.sh`, extend the `sed` added in Task 1 to include the Codex config. The block becomes:

```bash
cp "$template_dir/devcontainer/mcp.json" "$activity_name/.mcp.json"
sed -i "s|{{BURP_MCP_URL}}|$BURP_MCP_URL|g" \
    "$activity_name/.mcp.json" \
    "$activity_name/.codex/config.toml"

```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/test-newPT.sh`
Expected: PASS (new `6g` included; Test 6c's approval/sandbox assertions still hold).
Run: `bash tests/test-install-offsec-tools.sh`
Expected: PASS (new Test 7 included).

- [ ] **Step 7: Commit**

```bash
git add org/templates/codex/config.toml org/install-offsec-tools.sh org/newPT.sh tests/test-newPT.sh tests/test-install-offsec-tools.sh
git commit -m "feat(newPT): wire Burp MCP for Codex via mcp-remote bridge"
```

---

## Task 3: Reachability probe in `up.sh`

**Files:**
- Modify: `org/templates/devcontainer/up.sh` (after the ssh-agent check block at :21-26, before `export DOCKER_BUILDKIT=1` at :28)
- Modify: `org/newPT.sh` (extend the URL `sed` file list)
- Test: `tests/test-newPT.sh`

**Interfaces:**
- Consumes: `BURP_MCP_URL` and the `sed` pass from Tasks 1–2.
- Produces: an advisory, non-blocking TCP probe in the scaffolded `.devcontainer/up.sh` carrying the substituted URL.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-newPT.sh` immediately after the Test 6g `pass` line from Task 2:

```bash
# --- Test 6h: up.sh carries a non-blocking Burp MCP reachability probe ---
test -f engagement-internal/.devcontainer/up.sh || fail ".devcontainer/up.sh missing"
grep -q 'Burp MCP endpoint' engagement-internal/.devcontainer/up.sh || \
    fail "up.sh must warn when the Burp MCP endpoint is unreachable"
grep -q 'http://127.0.0.1:9876/sse' engagement-internal/.devcontainer/up.sh || \
    fail "up.sh probe must carry the substituted Burp MCP URL"
grep -q "{{" engagement-internal/.devcontainer/up.sh && \
    fail "up.sh still has an unresolved {{PLACEHOLDER}}"
pass "up.sh scaffolded with a non-blocking Burp MCP reachability probe"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-newPT.sh`
Expected: FAIL at `up.sh must warn when the Burp MCP endpoint is unreachable`.

- [ ] **Step 3: Add the probe to `up.sh`**

In `org/templates/devcontainer/up.sh`, after the ssh-agent `fi` (:26) and before `export DOCKER_BUILDKIT=1` (:28), insert:

```bash

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
```

- [ ] **Step 4: Add `.devcontainer/up.sh` to the URL sed list in `newPT.sh`**

In `org/newPT.sh`, extend the `sed` to include up.sh. The block becomes:

```bash
cp "$template_dir/devcontainer/mcp.json" "$activity_name/.mcp.json"
sed -i "s|{{BURP_MCP_URL}}|$BURP_MCP_URL|g" \
    "$activity_name/.mcp.json" \
    "$activity_name/.codex/config.toml" \
    "$activity_name/.devcontainer/up.sh"

```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test-newPT.sh`
Expected: PASS (new `6h` included).

- [ ] **Step 6: Lint the generated probe with bash**

Run: `BURP_MCP_URL="http://127.0.0.1:9876/sse" bash org/newPT.sh lite /tmp/burp-lint-check >/dev/null && bash -n /tmp/burp-lint-check/.devcontainer/up.sh && echo "up.sh parses" && rm -rf /tmp/burp-lint-check`
Expected: prints `up.sh parses` (the substituted script is syntactically valid bash).

- [ ] **Step 7: Commit**

```bash
git add org/templates/devcontainer/up.sh org/newPT.sh tests/test-newPT.sh
git commit -m "feat(newPT): add advisory Burp MCP reachability probe to up.sh"
```

---

## Task 4: Document the Burp MCP channel in `AGENTS.md`

**Files:**
- Modify: `org/templates/AGENTS.md` (insert a subsection before the `## Credentials` heading at :37)
- Test: `tests/test-newPT.sh`

**Interfaces:**
- Consumes: nothing (AGENTS.md is copied verbatim by `newPT.sh:104`, so the scaffolded copy equals the template).
- Produces: a `### Burp MCP` subsection in the scaffolded `AGENTS.md`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test-newPT.sh` immediately after the Test 6h `pass` line from Task 3:

```bash
# --- Test 6i: AGENTS.md documents the pre-wired Burp MCP channel ---
grep -q 'Burp MCP' engagement-internal/AGENTS.md || \
    fail "AGENTS.md must document the pre-wired Burp MCP channel"
pass "AGENTS.md documents the Burp MCP channel and scope caution"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-newPT.sh`
Expected: FAIL at `AGENTS.md must document the pre-wired Burp MCP channel`.

- [ ] **Step 3: Add the subsection to `AGENTS.md`**

In `org/templates/AGENTS.md`, immediately before the `## Credentials` heading (:37), insert:

```markdown
### Burp MCP

This engagement is pre-wired to a Burp Suite MCP server (SSE, host-side; see `.mcp.json` and `.codex/config.toml`). When Burp is running with the "MCP Server" extension, the agent can drive proxy history, Repeater, and the scanner directly. Treat every action through it as live traffic to client infrastructure — stay within the testing window, source IPs, and scope defined above.

```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-newPT.sh`
Expected: PASS (new `6i` included).

- [ ] **Step 5: Commit**

```bash
git add org/templates/AGENTS.md tests/test-newPT.sh
git commit -m "docs(newPT): document the pre-wired Burp MCP channel in AGENTS.md"
```

---

## Task 5: Post-implementation runtime verification (manual, no code)

The unit tests prove the scaffolding emits the right config; they cannot prove the two agents actually connect to a live Burp. Resolve the spec's verification checklist against a running Burp before considering the feature done. These are checks, not code changes — record results in the engagement notes or a follow-up.

- [ ] **Step 1: Confirm Claude connects (native SSE)**

Scaffold a throwaway engagement, start Burp on the host with the "MCP Server" extension listening on `127.0.0.1:9876`, launch `./yolo.sh`, and in Claude run `/mcp`. Expected: the `burp` server shows connected and its tools are listed, with no trust prompt (validates `enableAllProjectMcpServers`).

- [ ] **Step 2: Confirm Codex registers `[mcp_servers.burp]` from the project config**

In the same container launch `./yolo-codex.sh` and confirm Codex lists the `burp` MCP server. If it does **not** appear, the project `.codex/config.toml` table is not merged with `~/.codex/config.toml` — fall back to injecting the server into the seeded `~/.codex/config.toml` (via `seed-codex-env.sh`/`postCreateCommand`), per the spec's Verification checklist.

- [ ] **Step 3: (Optional simplification) Test Codex native transport**

Temporarily replace the Codex `[mcp_servers.burp]` `command`/`args` with `url = "http://127.0.0.1:9876/sse"` and confirm Codex connects to Burp's SSE. If it connects cleanly, follow up with a change that drops `mcp-remote` for Codex and reconsiders the `install_AI` pre-install. If it does not, keep the bridge (the shipped default).

- [ ] **Step 4: Confirm the probe behaves**

With Burp **down**, run `bash .devcontainer/up.sh` and confirm it prints the `[!] Burp MCP endpoint ... not reachable` warning and still proceeds to `devcontainer up`. With Burp **up**, confirm the warning is absent and the probe returns promptly (no hang on the SSE stream).
