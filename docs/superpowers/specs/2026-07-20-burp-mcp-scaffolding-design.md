# Design — Burp MCP pre-wired into engagement scaffolding

**Date:** 2026-07-20
**Status:** design (awaiting review)
**Area:** `org/newPT.sh`, `org/templates/` (`devcontainer/`, `claude/`, `codex/`, `AGENTS.md`), `org/install-offsec-tools.sh`, `tests/test-newPT.sh`
**Fills:** the "Codex MCP server wiring" item left explicitly out of scope by `2026-07-19-codex-config-parity-design.md` (§Out of scope, "separate concern").

## Goal

`newPT.sh` scaffolds a turnkey engagement config for both Claude Code (`.claude/`) and Codex (`.codex/`). Neither agent currently has any MCP server wired. Make every scaffolded engagement come with the **Burp Suite MCP server pre-configured for both agents**, so an operator who has Burp running can drive it from the agent immediately — no per-engagement manual MCP setup.

Topology (decided): **Burp runs on the host** (GUI, operator-driven) with PortSwigger's "MCP Server" BApp extension exposing an SSE endpoint; the agent runs **in the container** and connects to that endpoint. This is trivially reachable because the engagement container already runs with `--network=host` (`org/templates/devcontainer/devcontainer.json`), so `127.0.0.1` inside the container is the host's localhost.

Non-goal: running Burp headless inside the container (topology B) — heavier (needs Java, a Burp install, a project file, a licence in a disposable environment) and out of scope.

## Background — the constraints that shape the design

Verified on the host (2026-07-20):

- **Claude Code 2.1.215** supports the `sse`/`http` MCP transports natively in a project-scoped `.mcp.json`. It can point straight at Burp's SSE URL.
- **Codex 0.144.6** reads a project-scoped `.codex/config.toml` (established by the parity work) in addition to `~/.codex/config.toml`. Its native `url` MCP transport speaks *Streamable-HTTP* (the newer transport), whereas the Burp extension historically exposes *SSE* (the legacy transport) → **native compatibility is uncertain and version-dependent**.
- **node/npx is present in the container** (installed by `install_base`); **Java is not** (the installer never installs a JDK). Any bridge must therefore be node-based (`mcp-remote`), not a Java proxy jar.
- The engagement container runs with `--network=host`, so a host-side Burp SSE server at `127.0.0.1:9876/sse` is reachable from inside the container with no extra plumbing.

### Decisions (agreed during brainstorming)

1. **Activation: always, all engagement types.** No conditional branches in `newPT.sh`. With Burp off, the MCP tools are simply absent — no error — so wiring it unconditionally is harmless even for `cloud`/`internal`/`mobile`/`lite`.
2. **Transport: hybrid.** Claude uses its native SSE transport; Codex uses a node stdio↔SSE bridge (`mcp-remote`). Each agent takes its most reliable path. `mcp-remote` is pre-installed in the image to avoid a cold `npx` fetch; the config still invokes it via `npx -y` so it works even if the global install is missing.
3. **Accessories: all three.** Configurable URL (placeholder + env override), a non-blocking reachability check in the launcher, and a short Burp-MCP note in the `AGENTS.md` template.

## Architecture / data flow

```
HOST:  Burp Suite + "MCP Server" extension  ──►  SSE @ {{BURP_MCP_URL}}  (default 127.0.0.1:9876/sse)
                     ▲  (--network=host: the container's localhost IS the host's localhost)
CONTAINER  /workspace (bind-mounted engagement root):
   Claude ── .mcp.json {type:sse, url} ─────────────────────────►  Burp SSE
   Codex  ── .codex/config.toml [mcp_servers.burp]
              └► npx -y mcp-remote <url>  (stdio↔SSE bridge) ─────►  Burp SSE
```

Each unit has one job and a stable interface:
- **`.mcp.json`** — Claude's project MCP registry; declares one `sse` server named `burp`.
- **`.codex/config.toml` `[mcp_servers.burp]`** — Codex's MCP registry entry; a stdio server that spawns the bridge.
- **`mcp-remote`** — transport shim; consumes an SSE URL, presents stdio to Codex. Replaceable by native Codex `url` if verification proves it works.
- **`up.sh` check** — advisory pre-flight; probes the URL, warns, never blocks.
- **`BURP_MCP_URL`** — the single source of the endpoint; flows into every file via one sed pass.

## Deliverables

### 1. New template `org/templates/devcontainer/mcp.json`
Claude's project-scoped MCP registry, scaffolded to `<activity>/.mcp.json`:
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

### 2. `org/templates/claude/settings.json`
Add `"enableAllProjectMcpServers": true` at the top level (beside `permissions`/`hooks`). Rationale: in `bypassPermissions`/yolo mode Claude still prompts once to approve a server found in `.mcp.json`; this flag auto-approves project MCP servers so the yolo launcher stays non-interactive. Only `burp` is ever in `.mcp.json`, so blanket-enabling project servers is acceptable and simpler than an explicit `enabledMcpjsonServers` allowlist.

### 3. Codex MCP registration (via devcontainer postCreate, NOT project config.toml)
**Superseded during implementation** — see the Verification checklist. Codex 0.144.6 ignores project-scoped `mcp_servers`, so the server is **not** declared in `org/templates/codex/config.toml` (a NOTE comment records why). Instead the devcontainer `postCreateCommand` (Deliverable §6-container) registers it into the container's **global** `~/.codex/config.toml`, right after the Codex seed:
```
codex mcp get burp >/dev/null 2>&1 || codex mcp add burp -- npx -y mcp-remote {{BURP_MCP_URL}} || echo '[!] codex mcp add burp failed — add manually: ...'
```
`{{BURP_MCP_URL}}` is substituted into `devcontainer.json` by `newPT.sh`. The `codex mcp get` guard makes it idempotent across container recreations.

### 4. `org/templates/devcontainer/up.sh`
Add a non-blocking reachability probe near the existing ssh-agent pre-flight. It must not trip `set -euo pipefail` and must not hang on the SSE stream (short timeout). Approach: derive host/port from `{{BURP_MCP_URL}}` (or curl with a short `--max-time` and treat connection-refused, exit 7 / empty status, as "not listening"); on failure print a one-line warning and continue:
```
[!] Burp MCP endpoint {{BURP_MCP_URL}} not reachable — start Burp + the "MCP Server"
    extension on the host, or the agent will launch without Burp tools.
```
The probe runs on the host (where up.sh executes and where Burp runs), so it is a true check.

### 5. `org/newPT.sh`
- Define near the other scaffold vars:
  ```sh
  BURP_MCP_URL="${BURP_MCP_URL:-http://127.0.0.1:9876/sse}"
  ```
- Copy the new template: `cp "$template_dir/devcontainer/mcp.json" "$activity_name/.mcp.json"`.
- Extend the placeholder-substitution so `{{BURP_MCP_URL}}` is injected into the three files that carry it: `<activity>/.mcp.json`, `<activity>/.devcontainer/up.sh`, `<activity>/.devcontainer/devcontainer.json` (the last for the postCreate `codex mcp add`). A focused second `sed` invocation handles this placeholder.
- Order matters: substitute **after** `.mcp.json`, `up.sh`, and `devcontainer.json` are copied.

### 6. `org/install-offsec-tools.sh` (`install_AI`)
Pre-install the bridge so the Codex path resolves without a first-run network fetch:
```sh
# mcp-remote — node stdio<->SSE/HTTP bridge used by Codex to reach the host's
# Burp MCP (SSE). Pre-installed so `npx -y mcp-remote` resolves offline.
sudo npm install -g mcp-remote
```
Global npm bins land in `/usr/local/bin` (on the image PATH), so `npx` finds it without a fetch. Idempotent guard optional (mirror the `claude`/`codex` `command -v` skip pattern) but not required — `npm i -g` is safe to repeat.

### 7. `org/templates/AGENTS.md`
Add a short subsection (in the tooling area) documenting the channel and the scope caution:
> **Burp MCP.** This engagement is pre-wired to a Burp Suite MCP server (SSE, host-side). Claude reads it from `.mcp.json`; Codex is registered at container setup (`codex mcp add burp`). When Burp is running with the "MCP Server" extension, the agent can drive proxy history, Repeater, and the scanner. Treat it as live traffic to client infrastructure — respect the testing window and scope in this file.

Keep it terse and placeholder-free (per the template-terseness convention).

## Testing

Extend `tests/test-newPT.sh` (throwaway-scaffold style, matching existing assertions):
- Scaffolded engagement contains `.mcp.json`; it is valid JSON, declares `mcpServers.burp` with `type=sse`, and its `url` contains no residual `{{` (placeholder substituted).
- `.devcontainer/devcontainer.json` postCreate contains `codex mcp add burp` with `mcp-remote` and the substituted URL; `.codex/config.toml` does **not** declare `[mcp_servers.burp]`.
- `.claude/settings.json` sets `enableAllProjectMcpServers` to `true`.
- `.devcontainer/up.sh` contains the reachability check and the substituted URL (no `{{`).
- URL override honored: running the scaffold with `BURP_MCP_URL=http://127.0.0.1:18080/sse` produces that URL in `.mcp.json`.
- `tests/test-install-offsec-tools.sh`: `install_AI` source contains `npm install -g mcp-remote`.

## Verification checklist (results)

Resolved during implementation (2026-07-20, `codex-cli 0.144.6`, `claude 2.1.215`):

- [x] **Codex table merge — RESOLVED (fallback taken).** Codex 0.144.6 loads `mcp_servers` **only** from the global `~/.codex/config.toml`, not from a project-scoped `.codex/config.toml`: with the block in a global `CODEX_HOME/config.toml`, `codex mcp list` shows `burp enabled`; with the identical block in the engagement's project `.codex/config.toml`, `codex mcp list`/`get` report no such server (even after `git init`). Implemented the fallback: the project config.toml no longer declares the server, and the devcontainer `postCreateCommand` registers it into the container's global config via `codex mcp get burp >/dev/null 2>&1 || codex mcp add burp -- npx -y mcp-remote <url>` (verified idempotent — a second run is skipped by the guard, no duplicate block).
- [x] **Claude registration — VERIFIED.** From within a scaffolded engagement, `claude mcp list` shows `burp: <url> (SSE)` and attempts to connect (`✘ Failed to connect` only because no Burp was listening) — confirming Claude discovers and registers the server from the project `.mcp.json`.
- [x] **up.sh probe — VERIFIED (logic).** The substituted `up.sh` parses (`bash -n`); the probe warns on a closed port, returns immediately (connection-refused is instant), and does not trip `set -euo pipefail`.
- [ ] **Claude auto-approve (runtime).** Confirm `enableAllProjectMcpServers: true` suppresses the `.mcp.json` trust prompt under `--dangerously-skip-permissions` in an actual `./yolo.sh` run. (Needs a built container.)
- [ ] **mcp-remote availability (runtime).** Confirm the pre-installed global is on PATH for the `pentester` user in the built image and that `npx -y mcp-remote` uses it rather than re-fetching. (Needs a built container.)
- [ ] **End-to-end connect (runtime).** With Burp + the "MCP Server" extension live on the host, confirm both `claude` and `codex` connect and list Burp tools from inside the container.

**Native Codex path (not taken):** `codex mcp add` supports `--url` (native Streamable-HTTP), but Burp exposes SSE and native SSE↔Streamable-HTTP compatibility is unverified, so the `mcp-remote` bridge is kept as the reliable default.

## Out of scope

- Burp headless inside the container (topology B).
- Runtime reconfiguration of the endpoint after scaffold (operator edits the files).
- Authentication/tokens for the Burp MCP endpoint (the extension is localhost-only and unauthenticated by default; with `--network=host` the host loopback is the trust boundary).
- Any change to existing Claude/Codex runtime behavior beyond the additive MCP wiring.
