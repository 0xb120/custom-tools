# Codex Config Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold a `.codex/` engagement config (mirroring `.claude/`) plus container auth-seeding and a Codex YOLO launcher, so an operator driving an engagement with Codex gets the same guardrails as with Claude Code.

**Architecture:** `newPT.sh` gains a `.codex/` scaffold block beside the existing `.claude/` one. The two payload-compatible hook scripts move to a shared `org/templates/hooks/` and are copied into both agents' `hooks/` dirs. A new `seed-codex-env.sh` (clone of `seed-claude-env.sh`) plus a devcontainer mount seeds `~/.codex` into the container. A `yolo-codex.sh` launcher mirrors `yolo.sh`.

**Tech Stack:** POSIX-ish bash, JSON (`hooks.json`), TOML (`config.toml`), devcontainer.json. Tests are bash assertions in `tests/test-newPT.sh` (existing harness: `fail`/`pass` helpers, scaffold into `mktemp -d`).

## Global Constraints

- Verified against `codex-cli 0.144.6`: `hooks` is a **stable, on-by-default** feature (no feature flag needed). YOLO flag: `--dangerously-bypass-approvals-and-sandbox`. Hook-trust bypass: `--dangerously-bypass-hook-trust`.
- The engagement is **always bind-mounted at `/workspace`** in the devcontainer — hook commands may reference `/workspace/.codex/hooks/…` as a stable absolute path.
- Codex `hooks.json` shape: top-level `"hooks"` map → event name → array of matcher-groups → each group has optional `"matcher"` (regex) and a `"hooks"` array of `{ "type": "command", "command": "…" }`. A `SessionStart` group with **no** `matcher` fires on all sources (mirrors Claude's `"*"`). Tool events use `"matcher": "^Bash$"`.
- **The Claude-side runtime must stay behavior-identical.** The only permitted `.claude` change is the hook-script *source path* move. `tests/test-newPT.sh` Test 6 `diff`s `.claude/settings.json` against the template byte-for-byte — do not edit that file.
- Report-prose format check is **Claude-only** (Codex edits are `apply_patch`, no `file_path`). Do not wire `check-report-format.sh` into Codex. Document the gap.
- Commit after each task. Branch is `feat/codex-config-parity` (already checked out, stacked on the AGENTS.md rename).

---

### Task 1: Move shared hook scripts to `org/templates/hooks/`

Two hook scripts are payload-compatible between Claude and Codex; make them a single template source copied into both agents at scaffold time. `check-report-format.sh` stays Claude-only.

**Files:**
- Move: `org/templates/claude/hooks/log-command.sh` → `org/templates/hooks/log-command.sh`
- Move: `org/templates/claude/hooks/render-after-db.sh` → `org/templates/hooks/render-after-db.sh`
- Keep: `org/templates/claude/hooks/check-report-format.sh` (unchanged, Claude-only)
- Modify: `org/newPT.sh` (the `.claude/` scaffold block, ~L161–164)
- Test: `tests/test-newPT.sh`

- [ ] **Step 1: Move the two shared scripts (preserve history)**

```bash
cd /opt/custom-tools
mkdir -p org/templates/hooks
git mv org/templates/claude/hooks/log-command.sh   org/templates/hooks/log-command.sh
git mv org/templates/claude/hooks/render-after-db.sh org/templates/hooks/render-after-db.sh
```

- [ ] **Step 2: Update the `.claude/` scaffold block in `newPT.sh` to copy from both sources**

Replace the current block (around L161–164):

```bash
mkdir -p "$activity_name/.claude/hooks"
cp "$template_dir/claude/settings.json" "$activity_name/.claude/settings.json"
cp "$template_dir/claude/hooks/"*.sh "$activity_name/.claude/hooks/"
chmod +x "$activity_name/.claude/hooks/"*.sh
```

with:

```bash
mkdir -p "$activity_name/.claude/hooks"
cp "$template_dir/claude/settings.json" "$activity_name/.claude/settings.json"
# Shared hooks (used by both Claude and Codex) live in templates/hooks/;
# check-report-format.sh is Claude-only and stays under templates/claude/hooks/.
cp "$template_dir/hooks/"*.sh              "$activity_name/.claude/hooks/"
cp "$template_dir/claude/hooks/"*.sh       "$activity_name/.claude/hooks/"
chmod +x "$activity_name/.claude/hooks/"*.sh
```

- [ ] **Step 3: Add a regression assertion to `tests/test-newPT.sh`**

After Test 6 (the `.claude/settings.json` block, ~L120), insert:

```bash
# --- Test 6b: .claude/hooks/ carries all three scripts, executable ---
for h in log-command render-after-db check-report-format; do
    test -x "engagement-internal/.claude/hooks/$h.sh" || \
        fail ".claude/hooks/$h.sh missing or not executable"
done
pass ".claude/hooks/ has all three hook scripts (shared + claude-only), executable"
```

- [ ] **Step 4: Run the newPT + DB test suites; expect all green**

```bash
cd /opt/custom-tools
bash tests/test-newPT.sh && bash tests/test-db-host-mapping.sh
```
Expected: both end with `All tests passed.` (Test 6's `diff` of `.claude/settings.json` still passes — settings.json is untouched.)

- [ ] **Step 5: Commit**

```bash
git add org/templates/hooks org/templates/claude/hooks org/newPT.sh tests/test-newPT.sh
git commit -m "refactor(templates): share log-command/render-after-db hooks across agents

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Codex config templates + `.codex/` scaffold block

**Files:**
- Create: `org/templates/codex/config.toml`
- Create: `org/templates/codex/hooks.json`
- Modify: `org/newPT.sh` (add a `.codex/` block after the `.claude/` block)
- Test: `tests/test-newPT.sh`

**Interfaces:**
- Produces: a scaffolded `<engagement>/.codex/` containing `config.toml`, `hooks.json`, and `hooks/{log-command,render-after-db}.sh`. Consumed by the devcontainer + launcher in Task 4.

- [ ] **Step 1: Create `org/templates/codex/config.toml`**

```toml
# Engagement-scoped Codex config — mirror of .claude/settings.json's
# bypassPermissions. The devcontainer IS the security boundary, so run
# sandbox-free with no approval prompts INSIDE it. Never use this outside the
# disposable engagement container.
approval_policy = "never"
sandbox_mode   = "danger-full-access"

# NOTE (known gap): the Claude-side PostToolUse(Write|Edit) report-prose format
# check is not mirrored for Codex. Codex edits go through apply_patch (a patch
# blob with no file_path), so that hook needs separate handling. Tracked in
# docs/superpowers/specs/2026-07-19-codex-config-parity-design.md.
```

- [ ] **Step 2: Create `org/templates/codex/hooks.json`**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "printf '\\n--- AGENTS.md ---\\n'; cat /workspace/AGENTS.md; printf '\\n--- TODO.md ---\\n'; cat /workspace/TODO.md; printf '\\n--- journal.md (last 100 lines) ---\\n'; tail -n 100 /workspace/journal.md"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "^Bash$",
        "hooks": [
          {
            "type": "command",
            "command": "bash /workspace/.codex/hooks/log-command.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "^Bash$",
        "hooks": [
          {
            "type": "command",
            "command": "bash /workspace/.codex/hooks/render-after-db.sh"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Add the `.codex/` scaffold block to `newPT.sh`**

Immediately after the `.claude/` block from Task 1 (after its `chmod +x` line), insert:

```bash
# .codex/ — engagement-scoped Codex config (mirror of .claude/). config.toml
# sets the bypass baseline; hooks.json wires the same SessionStart context
# injection + Bash audit-log + DB-render hooks (report-format is Claude-only).
mkdir -p "$activity_name/.codex/hooks"
cp "$template_dir/codex/config.toml" "$activity_name/.codex/config.toml"
cp "$template_dir/codex/hooks.json"  "$activity_name/.codex/hooks.json"
cp "$template_dir/hooks/"*.sh        "$activity_name/.codex/hooks/"
chmod +x "$activity_name/.codex/hooks/"*.sh
```

- [ ] **Step 4: Write failing assertions in `tests/test-newPT.sh`**

After the Test 6b block from Task 1, insert:

```bash
# --- Test 6c: .codex/ scaffolded (config.toml + hooks.json + shared hooks) ---
test -f engagement-internal/.codex/config.toml || fail ".codex/config.toml missing"
grep -q 'approval_policy *= *"never"'          engagement-internal/.codex/config.toml || \
    fail ".codex/config.toml must set approval_policy = never"
grep -q 'sandbox_mode *= *"danger-full-access"' engagement-internal/.codex/config.toml || \
    fail ".codex/config.toml must set sandbox_mode = danger-full-access"

test -f engagement-internal/.codex/hooks.json || fail ".codex/hooks.json missing"
# valid JSON
jq -e . engagement-internal/.codex/hooks.json >/dev/null || fail ".codex/hooks.json is not valid JSON"
# wires exactly the three intended events, and NOT the report-format hook
jq -e '.hooks.SessionStart and .hooks.PreToolUse and .hooks.PostToolUse' \
    engagement-internal/.codex/hooks.json >/dev/null || \
    fail ".codex/hooks.json must define SessionStart, PreToolUse, PostToolUse"
grep -q 'check-report-format' engagement-internal/.codex/hooks.json && \
    fail ".codex/hooks.json must NOT reference the Claude-only report-format hook"

# shared scripts are byte-identical between the two agents
for h in log-command render-after-db; do
    test -x "engagement-internal/.codex/hooks/$h.sh" || fail ".codex/hooks/$h.sh missing or not executable"
    diff -q "engagement-internal/.codex/hooks/$h.sh" "engagement-internal/.claude/hooks/$h.sh" >/dev/null || \
        fail "$h.sh differs between .codex/ and .claude/ (should be one shared source)"
done
pass ".codex/ scaffolded: config.toml + hooks.json (3 hooks, no report-format) + shared scripts"
```

- [ ] **Step 5: Run the test suite; expect green**

```bash
cd /opt/custom-tools && bash tests/test-newPT.sh
```
Expected: `All tests passed.` (If `jq` is required and missing, install per repo tooling — it is already a declared dependency.)

- [ ] **Step 6: Commit**

```bash
git add org/templates/codex org/newPT.sh tests/test-newPT.sh
git commit -m "feat(codex): scaffold .codex/ config + hooks mirroring .claude/

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `seed-codex-env.sh` (container auth/config seed)

Clone `org/seed-claude-env.sh` and retarget it at `~/.codex`. Same CLI (`export`/`apply`, `--with-credentials`, `--home`), same allowlist-copy + plugin-path-normalization structure.

**Files:**
- Create: `org/seed-codex-env.sh`
- Test: `tests/test-newPT.sh` (new self-contained section — does not scaffold an engagement)

- [ ] **Step 1: Copy the Claude seed as the starting point**

```bash
cd /opt/custom-tools
cp org/seed-claude-env.sh org/seed-codex-env.sh
```

- [ ] **Step 2: Apply these exact edits to `org/seed-codex-env.sh`**

Make every substitution below (they are the only differences from the Claude seed):

1. **Header/usage prose:** replace every `~/.claude` → `~/.codex`, `.claude/` → `.codex/`, `Claude Code` → `Codex`, `claude` (the launch command) → `codex`, `~/.claude.json` explanations → drop (Codex has no sibling state-blob file; its state is inside `~/.codex`). Update the "What travels" line to: `config.toml, plugins (+skills), skills, rules, prompts, AGENTS.md. Never copied: auth (unless --with-credentials), sessions, history, sqlite state, caches.`
2. **ALLOWLIST array** → replace with:
```bash
ALLOWLIST=(
    config.toml      # model / provider / MCP defaults (project .codex/config.toml layers on top)
    plugins          # plugin repos + skills they ship
    skills           # standalone user-level skills
    rules            # custom rules
    prompts          # custom prompt/slash-command files
    AGENTS.md        # global user instructions
)
```
3. **Credentials file:** replace all three `.credentials.json` occurrences (the `--with-credentials` copy block, the "skipped" message, and the OFF-by-default hint) with `auth.json`. Keep the `chmod 600`. Update the comment "the OAuth token" → "the Codex auth token".
4. **DENYLIST array** → replace with the stable-named per-user/machine state:
```bash
DENYLIST=(
    cache sessions log memories shell_snapshots tmp
    history.jsonl installation_id version.json models_cache.json
)
```
5. **Source/dest resolution:** `CLAUDE_HOME:-$HOME/.claude` → `CODEX_HOME:-$HOME/.codex`; `$DEST_HOME/.claude` → `$DEST_HOME/.codex`.
6. **Plugin-path normalization:** `.claude/plugins` → `.codex/plugins` in both the `sed` expression and its comment.
7. **Sibling-file check:** delete the line `[ -e "$SRC/../.claude.json" ] && left+=(".claude.json (sibling of ~/.claude)")` (no Codex equivalent).
8. **Final `apply` messages:** `Launch 'claude' — it will regenerate a clean ~/.claude.json.` → `Launch 'codex'.`; keep the "not signed in → log in once" line.

- [ ] **Step 3: Write failing tests for the seed script in `tests/test-newPT.sh`**

Append before the final `rm -f /tmp/np.err` / `echo "All tests passed."`:

```bash
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
```

- [ ] **Step 4: Run the suite; expect green**

```bash
cd /opt/custom-tools && bash tests/test-newPT.sh
```
Expected: `All tests passed.`

- [ ] **Step 5: Commit**

```bash
git add org/seed-codex-env.sh tests/test-newPT.sh
git commit -m "feat(codex): add seed-codex-env.sh to seed ~/.codex into the container

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Devcontainer plumbing + Codex YOLO launcher

**Files:**
- Modify: `org/templates/devcontainer/devcontainer.json`
- Create: `org/templates/devcontainer/yolo-codex.sh`
- Modify: `org/newPT.sh` (copy `yolo-codex.sh` to the engagement root; extend the next-steps output)
- Test: `tests/test-newPT.sh`

- [ ] **Step 1: Add the `~/.codex` mount to `devcontainer.json`**

In the `"mounts"` array, add a line after the host-claude mount:

```json
    "source=${localEnv:HOME}/.codex,target=/seed/host-codex,type=bind,readonly",
```

- [ ] **Step 2: Extend `postCreateCommand` to also seed Codex**

Replace the existing `postCreateCommand` value with:

```json
  "postCreateCommand": "bash /home/pentester/custom-tools/org/seed-claude-env.sh apply /seed/host-claude --with-credentials || echo '[!] Claude config seed failed — launch claude and log in manually'; bash /home/pentester/custom-tools/org/seed-codex-env.sh apply /seed/host-codex --with-credentials || echo '[!] Codex config seed failed — launch codex and log in manually'; echo 'Engagement container ready. Run: claude  (or: codex)'"
```

- [ ] **Step 3: Create `org/templates/devcontainer/yolo-codex.sh`**

```bash
#!/bin/bash
# YOLO launcher (Codex): build/start the engagement devcontainer, then drop
# into an interactive Codex session with approvals + sandbox disabled and the
# engagement's scaffolded hooks auto-trusted.
#
# Why this is acceptable: Codex runs as the non-root `pentester` user INSIDE a
# disposable container with the engagement bind-mounted at /workspace — not on
# your host. --dangerously-bypass-approvals-and-sandbox is intended precisely
# for externally-sandboxed environments like this container;
# --dangerously-bypass-hook-trust lets .codex/hooks run without the interactive
# one-time trust prompt. Only use on engagements where unattended in-scope
# action is intended.
#
# This is just the two documented steps chained together:
#   bash .devcontainer/up.sh
#   devcontainer exec --workspace-folder . codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust

set -euo pipefail

# Run from the engagement root regardless of the caller's cwd.
cd "$(dirname "$(readlink -f "$0")")"

# 1. Build + start (or reuse) the container. up.sh does the BuildKit and
#    ssh-agent preflight checks and exits non-zero if they fail.
bash .devcontainer/up.sh

# 2. Attach an interactive Codex session in YOLO mode.
exec devcontainer exec --workspace-folder . codex \
    --dangerously-bypass-approvals-and-sandbox \
    --dangerously-bypass-hook-trust
```

- [ ] **Step 4: Scaffold `yolo-codex.sh` + update next-steps in `newPT.sh`**

After the existing `yolo.sh` copy/chmod lines (~L131–133), add:

```bash
cp "$template_dir/devcontainer/yolo-codex.sh" "$activity_name/yolo-codex.sh"
chmod +x "$activity_name/yolo-codex.sh"
```

In the `Next steps:` heredoc (~L179), add a Codex line under the `./yolo.sh` line:

```
  ./yolo-codex.sh                              # same, but launches Codex (--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust)
```

- [ ] **Step 5: Write failing assertions in `tests/test-newPT.sh`**

In Test 5 (the `internal` scaffold block), after the existing `yolo.sh` checks (~L73), add:

```bash
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
```

- [ ] **Step 6: Run the full suite; expect green**

```bash
cd /opt/custom-tools && bash tests/test-newPT.sh && bash tests/test-db-host-mapping.sh
```
Expected: both `All tests passed.`

- [ ] **Step 7: Commit**

```bash
git add org/templates/devcontainer/devcontainer.json org/templates/devcontainer/yolo-codex.sh org/newPT.sh tests/test-newPT.sh
git commit -m "feat(codex): seed ~/.codex in the devcontainer + yolo-codex.sh launcher

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Documentation (README + ROADMAP + CLAUDE.md)

Reflect Codex parity in the docs the way other engagement features are documented.

**Files:**
- Modify: `ROADMAP.md` (move §2 to Done with the commit range)
- Modify: `README.md` (if it documents the `.claude/` scaffold — add the `.codex/` mirror + `yolo-codex.sh`)
- Modify: `CLAUDE.md` (Workflow Notes: mention `.codex/` alongside `.claude/`)

- [ ] **Step 1: Check where `.claude/`, `yolo.sh`, and the engagement setup are documented**

```bash
cd /opt/custom-tools
grep -rn "yolo.sh\|\.claude/\|seed-claude-env\|newPT" README.md CLAUDE.md | head -40
```

- [ ] **Step 2: Update `README.md`** — wherever the `.claude/` engagement config / `yolo.sh` / seeding is described, add the parallel `.codex/` scaffold (`config.toml` + `hooks.json` + shared hooks), `seed-codex-env.sh`, the `~/.codex` mount, and `yolo-codex.sh`. Note the one deferred item: report-prose format check is Claude-only. (If README does not cover this area, skip — do not invent a section.)

- [ ] **Step 3: Update `CLAUDE.md`** — in *Workflow Notes* / the scaffolding bullet, note that `newPT.sh` now scaffolds both `.claude/` and `.codex/` from the shared `org/templates/hooks/` plus each agent's own config, and that `check-report-format.sh` is Claude-only.

- [ ] **Step 4: Update `ROADMAP.md`** — move §2 "Codex configuration parity" into the **Done** section, referencing this plan and the Task 1–4 commits; note the deferred report-format check as the one follow-up.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md ROADMAP.md
git commit -m "docs(codex): document .codex parity; mark ROADMAP §2 done

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- config.toml (bypass) → Task 2 ✓
- hooks.json (SessionStart + 2 Bash hooks, report-format deferred) → Task 2 ✓
- shared hook scripts, one source → both agents → Task 1 ✓
- seed-codex-env.sh (allowlist/secret/denylist/normalization) → Task 3 ✓
- newPT `.codex/` scaffold + yolo-codex copy → Tasks 2, 4 ✓
- devcontainer mount + seed → Task 4 ✓
- yolo-codex.sh launcher → Task 4 ✓
- deferred-gap documentation → config.toml comment (Task 2) + docs (Task 5) ✓
- tests extend test-newPT.sh → every task ✓

**Placeholder scan:** No TBD/TODO in steps; every code step shows full content or an exact, enumerated edit list against a named existing file.

**Type/name consistency:** Script paths (`/workspace/.codex/hooks/{log-command,render-after-db}.sh`), file names, config keys (`approval_policy`, `sandbox_mode`), and flag strings (`--dangerously-bypass-approvals-and-sandbox`, `--dangerously-bypass-hook-trust`) are identical across the plan, the spec, and the tests.

## Runtime verification (post-implementation, in a real container)

Unit tests assert scaffold *shape*, not live Codex behavior. Before calling this done, in a throwaway engagement container confirm: (1) `codex` starts under `yolo-codex.sh` as `pentester` with the bypass flags accepted; (2) the `SessionStart` hook injects AGENTS/TODO/journal; (3) a `Bash` tool call appends to `logs/commands.log`; (4) an `engagement.db` write triggers `render.sh`. If Codex exports a project-dir env var, switch the hook-command paths from `/workspace/.codex/hooks/…` to it.
