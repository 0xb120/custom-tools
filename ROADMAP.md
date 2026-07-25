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

## 4. Progressive context and bounded session handoff

**Status:** `in-progress` · **Size:** M · **Area:** `org/templates/`, `org/newPT.sh`

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

**Remaining:** commit the completed implementation and record its release reference here.

---

## Backlog — unscheduled ideas

No unscheduled items currently.

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
- **Anti-drift doctor** — checks DB↔Markdown/index consistency, missing PoC/write-up paths, unmanaged finding files, modified evidence, and unresolved observation state.
- **Stop enforcement** — blocks on structural drift, transient observations, or `#observation` journal entries that do not reference an `O####`/`F##`.

The progressive-context work in item 4 extends this shipped foundation with bounded retrieval and a session-level artifact capture gate.
