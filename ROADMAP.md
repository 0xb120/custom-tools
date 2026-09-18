# Roadmap — planned features

Feature planner for this toolkit. One section per planned improvement: motivation, design sketch, files it touches, and open questions to resolve before building. Move an item to **Done** (with the commit) once shipped; keep the design notes so we remember *why*.

Status legend: `idea` (needs design) · `ready` (design agreed, can build) · `in-progress` · `done`.

---

## 1. Host-indexed engagement memory — ✅ done (see § Done)

**Status:** `done` · **Size:** S · **Area:** `org/templates/` (AGENTS.md + a DB query/helper)

**Motivation.** When the LLM (or operator) resumes an engagement and asks *"what do we already know about `10.0.0.5`?"*, the answer today is scattered: structured columns in `db/engagement.db` (`asset`), free-text in `journal.md` (which is **chronological**, not host-indexed), and raw output under `scans/`. There is no host-centric view of prior analysis. We explicitly rejected "one note file per asset" — it fights the DB-as-source-of-truth model, drifts against the `asset`/`finding` tables, and a fragmented pile of files *hurts* LLM recall rather than helping it (more to read, more contradictions, not auto-loaded into context).

**Design.** Add the missing index without a new parallel store:

1. **Host tags in the journal.** Extend the `journal.md` convention (which already uses `#observation` / `#hypothesis` / `#dead-end` / `#decision`) with an entity tag per host: `@10.0.0.5`, `@host.example.com`. Then `grep '@10.0.0.5' journal.md` reconstructs that target's full history in one shot. Append-only, immutable — no drift, same discipline already imposed on the journal.
2. **On-demand "what-do-we-know" view.** A small helper / saved query that, given a host, concatenates: (a) the `asset` row from the DB, (b) findings referencing that host (`finding` + `finding_asset`), (c) `grep '@<host>' journal.md`. This *is* the per-asset note — but generated from existing sources, never hand-maintained.

**Files.**
- `org/templates/AGENTS.md` — document the `@host` tag in § Working journal.
- `org/templates/db/queries/` — add e.g. `host-dossier.sql` (DB side of the view).
- Optional: `org/templates/db/whatweknow.sh` (or similar) joining the DB query + journal grep for a single host.

**Open questions.**
- Tag syntax: `@host` vs `#host:<x>` — `@` reads cleaner and won't collide with the existing `#tag` namespace. Lean `@`.
- Should the `SessionStart` hook surface a dossier for hosts with `access IS NULL` (still-to-crack) to prime recall? Possibly, but keep it bounded to avoid context bloat.

---

## 2. Codex configuration parity (mirror the Claude Code engagement setup) — ✅ done (see § Done)

**Status:** `done` · **Size:** M · **Area:** `org/templates/`, `org/newPT.sh`

**Motivation.** `newPT.sh` already installs Codex (the `AI` install group: Codex, sgpt, Strix) and scaffolds a full Claude Code engagement config under `.claude/` — `settings.json` plus the three hooks (command audit log, DB→Markdown auto-render, report-prose format check) and the `SessionStart` context injection. An operator who drives the engagement with **Codex instead of Claude Code** gets none of those guardrails. Goal: bring Codex to feature parity so either agent enforces the same rules.

**Design (to be confirmed — depends on Codex's extensibility model).** Map each Claude Code mechanism to its Codex equivalent, then scaffold it from `newPT.sh` the same way `.claude/` is. Candidate target layout: `org/templates/codex/` mirroring `org/templates/claude/`. Engagement rules already live in the canonical `AGENTS.md`, which Codex reads natively and the Claude pointer (`CLAUDE.md` → `AGENTS.md`) also targets — so both agents share one rules file with no extra scaffolding.

| Claude Code mechanism | Codex equivalent (RESEARCH) |
|-----------------------|------------------------------|
| `.claude/settings.json` permissions / `bypassPermissions` | Codex approval mode / sandbox policy in `~/.codex/config.toml` (or per-project) |
| `SessionStart` hook → inject AGENT/TODO/journal | Codex session-start / instructions injection — `AGENTS.md`? a startup notify? |
| `PreToolUse(Bash)` → command audit log | **Open** — does Codex expose a pre-exec / per-tool hook? If not, log via a shell wrapper or accept the gap |
| `PostToolUse(Bash)` → auto-render on DB writes | **Open** — same question; may need a different trigger |
| `PostToolUse(Write\|Edit)` → report-format check | **Open** — same question |

**Open questions (resolve FIRST — design hinges on these).**
- Does Codex CLI have lifecycle / tool-event hooks comparable to Claude Code's `PreToolUse`/`PostToolUse`/`SessionStart`? If the granular tool hooks don't exist, the audit-log / auto-render / format-check features have no direct home — decide between (a) a tool wrapper, (b) a post-hoc reconciliation pass, or (c) documenting the gap.
- Where does per-project Codex config live, and how is it pinned per engagement (mirror the bind-mounted `/workspace` model)?
- Reuse vs duplicate: the three hook scripts in `org/templates/claude/hooks/` are plain bash reading a JSON payload on stdin. If Codex passes a compatible payload, the scripts could be shared rather than forked — verify the payload schema before duplicating.
- Single source of truth for engagement rules: the canonical file is now `AGENTS.md` (read directly by Codex), with `CLAUDE.md` as the only pointer to it — no second rule file to diverge.

**Pre-work.** Confirm the Codex extensibility surface (config + hooks/notify) against current Codex CLI docs before committing to a layout.

---

## 4. Progressive context and bounded session handoff — ✅ done (see § Done)

**Status:** `done` · **Size:** M · **Area:** `org/templates/`, `org/newPT.sh`

**Motivation.** The old SessionStart hook preloaded all of `AGENTS.md`, `TODO.md`, recent journal prose, and the full finding board. That consumed context, biased new investigations toward old conclusions, and still did not guarantee that tool-generated `scans/`/`poc/` artifacts were captured or assessed before the session ended.

**Design.**

1. Keep `AGENTS.md` below 12 KB with only hard scope, authorization, capture, and continuity rules. Move detailed severity, SQL, naming, and reporting reference material to the on-demand `PT_PLAYBOOK.md`.
2. Start sessions with `ptctl.py context boot`: compact scope, latest handoff, canonical counts, and a bounded number of open task titles. Exclude journal/finding prose, evidence bodies, scans, completed tasks, and the full board.
3. Retrieve progressively with `context focus`, `context history`, and `context resume F##|O####`; expose `context explain` so the automatic boundary is auditable.
4. Track content changes under `scans/` and `poc/` plus canonical registry changes. Require a structured `captured`, `no-finding`, `mixed`, or `administrative` outcome before the Stop hook permits the session to end.

**Files.**

- `org/templates/db/ptctl.py` — context router, artifact delta, capture gate, and structured session handoff.
- `org/templates/context/` — initial handoff, safe state baseline, and git-ignore rule for the active marker.
- `org/templates/AGENTS.md` / `PT_PLAYBOOK.md` — always-on versus on-demand split.
- `org/templates/{claude,codex}/` and `org/templates/hooks/engagement-doctor.sh` — bounded boot and stop-time enforcement.
- `tests/test-context-router.sh` plus scaffold/finding regression coverage.

**Shipped:** `7e16599`.

---

## 5. Make the recon orchestrator location-independent

**Status:** `ready` · **Size:** S · **Area:** `utils/recon/`

**Motivation.** `utils/recon/recon-orchestrator.sh` currently invokes workers through hard-coded `/opt/custom-tools/recon/...` paths, while the repository stores them under `utils/recon/`. A checkout or devcontainer can therefore have every worker present and still fail at the first orchestration step.

**Design.**

1. Resolve the worker directory once from `BASH_SOURCE[0]`.
2. Invoke every worker through that resolved directory while keeping engagement output relative to the operator's current directory.
3. Add an offline orchestrator smoke test with stub workers, covering paths that contain spaces and invocation from outside the repository.
4. Align the root and recon READMEs with the tested invocation.

**Files.**

- `utils/recon/recon-orchestrator.sh`
- `utils/recon/tests/`
- `README.md`
- `utils/recon/README.md`

---

## 6. Upgrade existing engagement workspaces

**Status:** `idea` · **Size:** L · **Area:** `org/`

**Motivation.** `newPT.sh` produces the current control plane only for new workspaces. Existing engagements do not automatically receive the transactional registry, progressive context files, updated hooks, or schema changes, and copying templates manually risks overwriting engagement-specific rules and report prose.

**Design questions.**

- Where should scaffold/schema version metadata live?
- Should upgrades be a separate `upgradePT.sh` or a `newPT.sh upgrade` command?
- Which generated files can be replaced safely, and which need a three-way merge?
- How should database migrations remain transactional, restartable, and backwards-compatible?
- What backup and dry-run guarantees are required before touching a live engagement?

**Acceptance direction.** An operator can preview and apply an idempotent upgrade to a pre-`f3b3195` fixture without losing scope, journal, TODO, findings, evidence, credentials, or custom agent rules.

---

## 7. Live agent lifecycle smoke test

**Status:** `ready` · **Size:** S · **Area:** `tests/`, `org/templates/`

**Motivation.** Offline tests cover the context router, registry, hooks, and capture gate, but do not execute a real Claude/Codex session inside the generated devcontainer. Payload or lifecycle differences in the installed CLIs could therefore escape the harness.

**Design.**

1. Scaffold a `none` engagement and build the minimal devcontainer.
2. Exercise SessionStart and Stop with both installed agents.
3. Cover `captured`, `no-finding`, and context-only `administrative` outcomes.
4. Keep Burp reachability non-blocking; add an opt-in MCP probe when the extension is available.
5. Make the test explicitly opt-in so normal offline CI remains deterministic.

---

## 8. Single-tenant session layer removed — ✅ done (see § Done)

**Status:** `done` · **Size:** M · **Area:** `org/templates/`, `org/newPT.sh`, `tests/`

**Motivation.** Item 4's capture gate assumed exactly one agent per engagement. With two sessions open, the second never opened its own marker (`.context/active.json` is global), and the first to close rewrote the global baseline (`.context/state.json`), absorbing the other's in-flight artifacts and silently reporting `Capture gate: not required` for work nobody had accounted for. `handoff.md` was last-writer-wins on top of that, and the Stop hook's `doctor`/`session check` blocked each session on the others' work in progress.

**Shipped.** `.context/` and the whole `session` command group are gone. What the handoff held that the registry cannot reconstruct moved into two DB tables — `cleanup` (what testing left on the target) and `coverage` (what was actually tried, tries that found nothing included) — both INSERT-only or single-row updates, so concurrent sessions never contend. The Stop hook reports instead of blocking; `doctor --strict` is the gate that still fails, at reporting freeze. Bridged hard rules also stopped being silently truncated: the boot budget was 18000 chars with a 12000-char rules cap, and any clipped section is announced in an `INCOMPLETE BOOT` block. (The bridge itself is gone as of item 10; the truncation warning stays.)

## 9. Registry vocabulary: record facts, decide nothing — ✅ done

**Status:** `done` · **Size:** L · **Area:** `org/templates/db/`, `org/templates/AGENTS.md`, `org/templates/PT_PLAYBOOK.md`, `tests/`

**Motivation.** The registry asked agents for two judgements they cannot make honestly. The seven-state observation lifecycle mixed *who decided what* (`linked`, `rejected`) with *how sure the agent was* (`new`, `validating`, `confirmed`, `inconclusive`), and `AGENTS.md` required every observation to be resolved before stopping — closure on an exploration that has no natural end, with an escape hatch (`or explicitly left in validating`) that made the rule ritual rather than enforcement. The coverage ledger asked for the same thing at asset level: `negative` and `partial` differed only by a completeness claim, and `positive` duplicated the observation registry. Both produced `doctor` warnings on entirely normal work in progress, and a check that fires on normal state is one everybody learns to ignore.

**Shipped.** Observation `state` now records only who decided what — `proposed` → `accepted` (only via `finding create`/`finding attach`, so an agent never promotes its own work) or `dismissed` (reason mandatory). Agent confidence moved to its own `confidence` field (`suspected` / `reproduced`), and `decided_by` keeps an agent's dismissal distinguishable from an operator's. Coverage lost its verdict column and became an append-only attempt log with a mandatory note. Nothing asks an agent to conclude anything: `doctor` reports deliverable defects only and never fails on the queue, `ptctl.py inbox` is the operator's review queue, and the Stop hook hands it over instead of flagging it. Capture friction dropped with `observation add --from-http`, which derives method/route/selector from a saved request and registers it as the mandatory `http-request` evidence. Read paths caught up: `observation list` reads dismissals and their reasons back, and `whatweknow.sh` finally shows the observations and attempts that never became findings. Live engagement DBs migrate in place on the next `ptctl.py` call (`tests/test-registry-migration.sh` covers the mapping, the foreign keys and idempotency).

## 10. Stop paying for AGENTS.md twice — ✅ done

**Status:** `done` · **Size:** S · **Area:** `org/templates/`, `tests/`

**Motivation.** Item 4 bridged `AGENTS.md` into the Claude bootstrap because only Codex read it natively. Claude Code has since made `CLAUDE.md` / `AGENTS.md` discovery native and hardcoded, so the bridge put the same ~11 KB of rules in context twice — roughly 3k tokens per session, re-paid on every `resume`, `clear`, and `compact`, since the `SessionStart` matcher is `*`. Measured on a fresh scaffold: boot was 12964 chars, of which 11805 were the duplicated rules.

**Shipped.** `--include-rules` is removed from `context boot` / `context explain`; boot is now DB-derived only (identity, scope, open cleanup, counts, open task titles) and `DEFAULT_BOOT_CHARS` drops 18000 → 8000, which is what those sections actually need. Both SessionStart hooks call `context boot --max-chars 8000`. The same pass moved the `ptctl` capture syntax out of the always-on `AGENTS.md` into `PT_PLAYBOOK.md` § Capture recipes, leaving the obligation in the rules and the invocation on demand. Fresh-scaffold boot: 12964 → 1467 chars; `AGENTS.md`: 11805 → 11091 bytes.

**Verified.** `claude -p` in a directory containing only an `AGENTS.md` (and again with a `CLAUDE.md` alongside it) obeys a rule stated exclusively in `AGENTS.md`, confirming native discovery on Claude Code 2.1.274.

---

## Backlog — unscheduled ideas

- **Codex report-format parity.** Adapt the Claude-only report prose check to Codex's `apply_patch`/Stop lifecycle without scanning unrelated Markdown.
- **Automatic host dossier hints.** Reconsider surfacing hosts with `access IS NULL` at SessionStart only after measuring context cost and operator value.
- **Gowitness v3 screenshots.** Replace the current `httpx -screenshot` path when the report-serve UI justifies the dependency and migration effort.

---

## Done

### 1. Host-indexed engagement memory — `f69dc32`

Shipped both pieces from the design, plus a third source we added during build:

- **`@host` journal tag** — documented in `org/templates/AGENTS.md` § Working journal alongside the existing `#tag` namespace. `grep '@10.0.0.5' journal.md` reconstructs a target's history.
- **`host-dossier.sql`** (`org/templates/db/queries/`) — DB-side view: assets / segments / credentials / findings for a bound `:host`.
- **`whatweknow.sh`** (`org/templates/db/`) — wrapper folding **three** sources, not two: the DB view + `@host` journal grep + **raw `scans/` output mentioning the host**. The raw-scan source was added because the model doesn't always transcribe every banner / version / open port into the DB — those details survive only in the raw output, and a DB-only dossier would silently omit them. Copied into each engagement by `org/newPT.sh`. Host value is charset-guarded (`[A-Za-z0-9.:_-]`) before reaching the SQLite `.param` dot-command to close the quote-injection hole.

**Deferred (open question #2):** the `SessionStart`-hook auto-surfacing of dossiers for `access IS NULL` hosts was left out to avoid context bloat — revisit if recall priming proves worth it.

### 2. Codex configuration parity — `8db0db9`…`e6e0b61`

Research against `codex-cli 0.144.6` collapsed the design's biggest unknown: Codex ships a **stable, on-by-default hooks system** that is payload-compatible with Claude Code (`SessionStart`/`PreToolUse`/`PostToolUse`, `tool_input.command`, `cwd`, exit-2-blocks, stdout-as-context), so most of `.claude/` mirrors almost verbatim. `newPT.sh` now scaffolds `.codex/` beside `.claude/`:

- **Shared hooks** — `log-command.sh` + `render-after-db.sh` moved to `org/templates/hooks/`, copied into both agents' `hooks/` dirs (one source, two consumers).
- **`.codex/config.toml`** — `approval_policy="never"` + `sandbox_mode="danger-full-access"` (the `bypassPermissions` analog); **`.codex/hooks.json`** wires SessionStart context injection + Bash audit-log + DB-render.
- **`seed-codex-env.sh`** + a `~/.codex` devcontainer bind-mount/seed, and **`yolo-codex.sh`** (`--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust`) — so `codex` runs in-container exactly like `claude`.

Design + plan: `docs/superpowers/specs/2026-07-19-codex-config-parity-design.md`, `docs/superpowers/plans/2026-07-19-codex-config-parity.md`.

**Deferred (one follow-up):** the report-prose format check (`check-report-format.sh`) stays Claude-only — Codex edits go through `apply_patch` (a patch blob, no `file_path`), so it needs a `PostToolUse(apply_patch)` or `Stop`-hook adaptation before it can mirror.

### 3. Transactional observation/finding workflow — `f3b3195`

Shipped a canonical control plane for the path from candidate evidence to report issue:

- **Observation registry** — idempotent `O####` capture with semantic fingerprints, state transitions, and immutable evidence hashes.
- **Finding workflow** — atomic create/attach/update/asset/merge operations, semantic `group_key` deduplication, managed Markdown metadata/evidence blocks, and automatic findings-index rendering.
- **Anti-drift doctor** — checks DB↔Markdown/index consistency, missing PoC/write-up paths, unmanaged finding files, and modified evidence.
- **Stop enforcement** — blocks on structural drift, transient observations, or `#observation` journal entries that do not reference an `O####`/`F##`.

The progressive-context work in item 4 extends this shipped foundation with bounded retrieval and a session-level artifact capture gate.

### 4. Progressive context and bounded session handoff — `7e16599`

Shipped a bias-resistant, auditable session lifecycle:

- **Bounded boot** — compact scope, current handoff, canonical counts, and open task titles, without journal/finding prose, evidence bodies, scans, completed task history, or the full board.
- **Progressive retrieval** — `context focus`, `history`, `resume`, `pending`, and `explain` expose only the layer intentionally requested.
- **Structured handoff** — content-based `scans/`/`poc/` and registry deltas feed a compact `.context/handoff.md`.
- **Capture gate** — every interactive session closes with a `captured`, `no-finding`, `mixed`, or `administrative` outcome; unchanged historical references cannot account for new artifacts.
- **Shared enforcement** — Claude and Codex SessionStart/Stop hooks use the same control plane while avoiding duplicate native rules in Codex.

The implementation also added the on-demand `PT_PLAYBOOK.md`, full operator documentation under `org/README.md`, and regression coverage for context isolation and handoff freshness.
