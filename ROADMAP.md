# Roadmap — planned features

Feature planner for this toolkit. One section per planned improvement: motivation, design sketch, files it touches, and open questions to resolve before building. Move an item to **Done** (with the commit) once shipped; keep the design notes so we remember *why*.

Status legend: `idea` (needs design) · `ready` (design agreed, can build) · `in-progress` · `done`.

---

## 1. Host-indexed engagement memory — ✅ done (see § Done)

**Status:** `done` · **Size:** S · **Area:** `org/templates/` (AGENT.md + a DB query/helper)

**Motivation.** When the LLM (or operator) resumes an engagement and asks *"what do we already know about `10.0.0.5`?"*, the answer today is scattered: structured columns in `db/engagement.db` (`asset`), free-text in `journal.md` (which is **chronological**, not host-indexed), and raw output under `scans/`. There is no host-centric view of prior analysis. We explicitly rejected "one note file per asset" — it fights the DB-as-source-of-truth model, drifts against the `asset`/`finding` tables, and a fragmented pile of files *hurts* LLM recall rather than helping it (more to read, more contradictions, not auto-loaded into context).

**Design.** Add the missing index without a new parallel store:

1. **Host tags in the journal.** Extend the `journal.md` convention (which already uses `#observation` / `#hypothesis` / `#dead-end` / `#decision`) with an entity tag per host: `@10.0.0.5`, `@host.example.com`. Then `grep '@10.0.0.5' journal.md` reconstructs that target's full history in one shot. Append-only, immutable — no drift, same discipline already imposed on the journal.
2. **On-demand "what-do-we-know" view.** A small helper / saved query that, given a host, concatenates: (a) the `asset` row from the DB, (b) findings referencing that host (`finding` + `finding_asset`), (c) `grep '@<host>' journal.md`. This *is* the per-asset note — but generated from existing sources, never hand-maintained.

**Files.**
- `org/templates/AGENT.md` — document the `@host` tag in § Working journal.
- `org/templates/db/queries/` — add e.g. `host-dossier.sql` (DB side of the view).
- Optional: `org/templates/db/whatweknow.sh` (or similar) joining the DB query + journal grep for a single host.

**Open questions.**
- Tag syntax: `@host` vs `#host:<x>` — `@` reads cleaner and won't collide with the existing `#tag` namespace. Lean `@`.
- Should the `SessionStart` hook surface a dossier for hosts with `access IS NULL` (still-to-crack) to prime recall? Possibly, but keep it bounded to avoid context bloat.

---

## 2. Codex configuration parity (mirror the Claude Code engagement setup)

**Status:** `idea` · **Size:** M · **Area:** `org/templates/`, `org/newPT.sh`

**Motivation.** `newPT.sh` already installs Codex (the `AI` install group: Codex, sgpt, Strix) and scaffolds a full Claude Code engagement config under `.claude/` — `settings.json` plus the three hooks (command audit log, DB→Markdown auto-render, report-prose format check) and the `SessionStart` context injection. An operator who drives the engagement with **Codex instead of Claude Code** gets none of those guardrails. Goal: bring Codex to feature parity so either agent enforces the same rules.

**Design (to be confirmed — depends on Codex's extensibility model).** Map each Claude Code mechanism to its Codex equivalent, then scaffold it from `newPT.sh` the same way `.claude/` is. Candidate target layout: `org/templates/codex/` mirroring `org/templates/claude/`, plus an `AGENTS.md` (Codex reads `AGENTS.md`, whereas the Claude pointer is `CLAUDE.md` → `AGENT.md`).

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
- Single source of truth for engagement rules: keep one `AGENT.md` and have both `CLAUDE.md` and `AGENTS.md` point to it, to avoid two diverging rule files.

**Pre-work.** Confirm the Codex extensibility surface (config + hooks/notify) against current Codex CLI docs before committing to a layout.

---

## Backlog — unscheduled ideas

- **DB-reconciliation reminder hook.** A `Stop` hook (guarded by `stop_hook_active` to avoid loops) that diffs observable state against the DB and nudges Claude when there's a concrete gap — strongest signal: `findings/<slug>.md` files with no matching row in the `finding` table (and the reverse), plus hosts present in `scans/**` artifacts but absent from `asset`. Deterministic, no semantic guessing. Pairs with passive context injection on `SessionStart`/`UserPromptSubmit` for asset drift. (Discussed; not yet scheduled.)

---

## Done

### 1. Host-indexed engagement memory — `f69dc32`

Shipped both pieces from the design, plus a third source we added during build:

- **`@host` journal tag** — documented in `org/templates/AGENT.md` § Working journal alongside the existing `#tag` namespace. `grep '@10.0.0.5' journal.md` reconstructs a target's history.
- **`host-dossier.sql`** (`org/templates/db/queries/`) — DB-side view: assets / segments / credentials / findings for a bound `:host`.
- **`whatweknow.sh`** (`org/templates/db/`) — wrapper folding **three** sources, not two: the DB view + `@host` journal grep + **raw `scans/` output mentioning the host**. The raw-scan source was added because the model doesn't always transcribe every banner / version / open port into the DB — those details survive only in the raw output, and a DB-only dossier would silently omit them. Copied into each engagement by `org/newPT.sh`. Host value is charset-guarded (`[A-Za-z0-9.:_-]`) before reaching the SQLite `.param` dot-command to close the quote-injection hole.

**Deferred (open question #2):** the `SessionStart`-hook auto-surfacing of dossiers for `access IS NULL` hosts was left out to avoid context bloat — revisit if recall priming proves worth it.
