# Design — Codex configuration parity (mirror `.claude/` → `.codex/`)

**Date:** 2026-07-19
**Status:** design (awaiting review)
**Area:** `org/templates/`, `org/newPT.sh`, `org/seed-codex-env.sh` (new)
**Supersedes:** ROADMAP §2 ("Codex configuration parity") — this is that item, with the open questions resolved by research against the installed Codex CLI.

## Goal

`newPT.sh` scaffolds a full Claude Code engagement config under `.claude/` (permissions + three hooks + SessionStart context injection) and seeds the host's `~/.claude` into the container so `claude` runs turnkey. An operator who drives the engagement with **Codex** instead gets none of those guardrails. Bring Codex to feature parity so either agent enforces the same rules from the same engagement folder.

## Background — what Codex actually provides (verified against `codex-cli 0.144.6`)

The ROADMAP feared Codex might lack tool-lifecycle hooks. It does not — the surface is nearly a 1:1 match with Claude Code:

- **Hooks are a stable, on-by-default feature** (`codex features list` → `hooks  stable  true`). No feature flag to enable.
- **Hook config** lives in `<repo>/.codex/hooks.json` (JSON, same shape as Claude's `settings.json` hooks block) or inline `[hooks]` tables in `<repo>/.codex/config.toml`. Discovery order includes both `~/.codex/` and the repo `.codex/`.
- **Lifecycle events** include `SessionStart`, `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop` — the ones we use.
- **stdin payload is payload-compatible** with our hook scripts: `cwd`, `tool_name`, `tool_input.command`, exit-code-`2`-blocks-with-stderr, and hook **stdout is injected as developer context** (so the SessionStart `cat` trick works identically).
- **Sandbox / approvals**: `sandbox_mode` (`read-only` | `workspace-write` | `danger-full-access`) and `approval_policy` (`untrusted` | `on-failure` | `on-request` | `never`) in `config.toml`. YOLO flag: `--dangerously-bypass-approvals-and-sandbox`. Hook-trust bypass for unattended runs: `--dangerously-bypass-hook-trust`.
- **`AGENTS.md`** is read natively — no `CLAUDE.md`-style pointer needed.

## Mapping

| `.claude/` mechanism | `.codex/` equivalent | Reuse |
|---|---|---|
| `settings.json` → `defaultMode: bypassPermissions` | `config.toml` → `approval_policy="never"`, `sandbox_mode="danger-full-access"` | rewrite |
| `SessionStart` inline (`cat AGENTS.md + TODO.md + journal.md`) | `hooks.json` `SessionStart` — same inline command | verbatim |
| `PreToolUse(Bash)` → `log-command.sh` | `hooks.json` `PreToolUse` matcher `Bash` → same script | **verbatim** |
| `PostToolUse(Bash)` → `render-after-db.sh` | `PostToolUse` matcher `Bash` → same script | **verbatim** |
| `PostToolUse(Write\|Edit)` → `check-report-format.sh` | ⚠️ Codex edits are `apply_patch` (payload = patch blob, no `file_path`) | **deferred** (see Decisions) |
| `yolo.sh` → `claude --dangerously-skip-permissions` | `yolo-codex.sh` → `codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust` | mirror |
| `seed-claude-env.sh` + `~/.claude` mount | `seed-codex-env.sh` + `~/.codex` mount | mirror |

## Decisions (agreed)

1. **Report-format hook: deferred.** Codex has no Write/Edit tool with a `file_path`; edits go through `apply_patch` whose payload is a patch blob. The report-prose format check ships for Claude only for now; the Codex gap is documented (see Deliverables §6). Revisit as a `PostToolUse(apply_patch)` or `Stop` hook later.
2. **Full container parity.** Add `seed-codex-env.sh`, a `~/.codex` devcontainer bind-mount + postCreate seed, and a Codex YOLO launcher — so `codex` runs in-container exactly like `claude`.
3. **Hook scripts: one template source, copied to both agents.** The two payload-compatible scripts (`log-command.sh`, `render-after-db.sh`) move to a shared `org/templates/hooks/` and are copied into *both* `.claude/hooks/` and `.codex/hooks/` at scaffold time. `check-report-format.sh` stays Claude-only under `org/templates/claude/hooks/`. Template stays DRY; each engagement dir stays self-contained.

## Deliverables

### 1. `org/templates/hooks/` (shared hook scripts — moved)
`git mv` `log-command.sh` and `render-after-db.sh` from `org/templates/claude/hooks/` here. Contents unchanged — both already resolve the engagement root via `${CLAUDE_PROJECT_DIR:-${cwd:-/workspace}}`, and `cwd` is present in Codex's payload, so they run unmodified under Codex.

### 2. `org/templates/codex/config.toml`
```toml
# Engagement-scoped Codex config. The devcontainer IS the security boundary,
# so run sandbox-free inside it (mirrors .claude/ bypassPermissions).
approval_policy = "never"
sandbox_mode   = "danger-full-access"
```
(Hooks need no feature flag on 0.144.6+; hook trust is handled by the launcher flag.)

### 3. `org/templates/codex/hooks.json`
Mirrors the `.claude/settings.json` hooks block, minus the report-format entry:
- `SessionStart` (matcher covering `startup`/`resume`) → inline `cat AGENTS.md + TODO.md + journal.md`.
- `PreToolUse` matcher `Bash` → `.codex/hooks/log-command.sh`.
- `PostToolUse` matcher `Bash` → `.codex/hooks/render-after-db.sh`.

Hook commands locate their script via the engagement root. `.claude` uses `$CLAUDE_PROJECT_DIR`; the Codex equivalent env var is unverified, so scripts are referenced by the container-stable absolute path `/workspace/.codex/hooks/…` (the engagement is always bind-mounted at `/workspace`). **Verify** whether Codex exports a project-dir env var and prefer it if so.

### 4. `org/seed-codex-env.sh`
Structural clone of `seed-claude-env.sh` (`export`/`apply`, `--with-credentials`, `--home`, plugin-path normalization). Codex-specific lists derived from a real `~/.codex`:
- **Allowlist (portable):** `config.toml`, `plugins`, `skills`, `rules`, `prompts`, `AGENTS.md` (each skipped if absent).
- **Secret (opt-in `--with-credentials`):** `auth.json`.
- **Denylist (never — per-user/machine state):** `cache`, `sessions`, `log`, `history.jsonl`, `installation_id`, `version.json`, `models_cache.json`, `memories`, `shell_snapshots`, `.tmp`, `tmp`, and every `*.sqlite*` (`goals_*`, `logs_*`, `memories_*`, `state_*`).
- Plugin-path normalization rewrites stale `…/.codex/plugins` prefixes → dest (mirrors the `.claude/plugins` logic). **Verify** Codex plugin registries actually embed absolute paths before relying on this.

### 5. `newPT.sh` integration
- New `.codex/` scaffold block beside the existing `.claude/` one (~L158–164): `mkdir -p "$activity_name/.codex/hooks"`, copy `codex/config.toml` + `codex/hooks.json`, copy the two shared scripts into `.codex/hooks/`, `chmod +x`.
- Update the `.claude/` block to copy shared scripts from the new `org/templates/hooks/` plus `check-report-format.sh` from `claude/hooks/`.
- Copy `yolo-codex.sh` to the engagement root (`chmod +x`).

### 6. Container plumbing (`org/templates/devcontainer/`)
- `devcontainer.json`: add mount `source=${localEnv:HOME}/.codex,target=/seed/host-codex,type=bind,readonly`; extend `postCreateCommand` to also run `seed-codex-env.sh apply /seed/host-codex --with-credentials` (non-fatal on failure, mirroring the Claude seed).
- `yolo-codex.sh`: mirror `yolo.sh` — `up.sh` then `devcontainer exec --workspace-folder . codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust`.
- Document the deferred report-format check as a known Codex-side gap (a comment in `codex/hooks.json` and a line in the scaffold's next-steps / AGENTS.md § tooling).

## Testing

Extend `tests/test-newPT.sh` (throwaway-scaffold style):
- A scaffolded engagement contains `.codex/config.toml`, `.codex/hooks.json`, and both `.codex/hooks/*.sh` (executable).
- `.codex/hooks.json` is valid JSON and wires exactly SessionStart + PreToolUse(Bash) + PostToolUse(Bash) — and does **not** reference the report-format script.
- `config.toml` sets `approval_policy="never"` and `sandbox_mode="danger-full-access"`.
- The shared scripts are byte-identical between `.claude/hooks/` and `.codex/hooks/`.
- `seed-codex-env.sh export` copies the allowlist and skips `auth.json` without `--with-credentials`; `--with-credentials` includes it `chmod 600`; denylist items are never copied.
- `yolo-codex.sh` is scaffolded and executable and carries both dangerous flags.

## Out of scope

- The report-format check for Codex (deferred; documented gap).
- Any change to Claude-side runtime behavior — the `.claude` setup must be byte-for-byte unchanged except the hook-script source path move.
- Codex MCP server wiring (separate concern; `codex mcp` manages it).

## Verification checklist (resolve during implementation)

- [ ] Exact `SessionStart` matcher syntax/semantics for injecting context (sources `startup`/`resume`).
- [ ] Whether Codex exports a project-dir env var for hook commands (else keep the `/workspace/.codex/hooks/` absolute path).
- [ ] Project `.codex/config.toml` scalar precedence over `~/.codex/config.toml` (approval/sandbox must win at engagement scope).
- [ ] Codex plugin registries embed absolute paths (justifies the normalization step).
- [ ] `--dangerously-bypass-approvals-and-sandbox` behavior as the non-root container `pentester` user.
