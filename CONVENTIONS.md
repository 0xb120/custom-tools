# CONVENTIONS — output & workspace contract

Rules for **every new or modified pipeline/worker** in this toolkit. Goal: stop the two failure
modes that grow with the pipeline — *"which file was the right one?"* and *"a tool renamed its
output / changed its path and a later step broke"*. The fix is the same in both cases: **paths are
a contract you own, never something a tool decides implicitly.**

Scope: all of `recon/` and any future workers the orchestrator dispatches. Existing scripts predate
these rules (see § Current state) — apply the contract when you touch them, don't rewrite wholesale.

---

## 1. The workspace is a contract, not a free directory

Each app workspace has a **fixed schema**, and raw tool output is kept separate from the **canonical
artifacts** that downstream steps consume:

```
targets/<app_id>/
  meta.json                    # identity: host, title, base_url, tech, cluster members
  raw/<tool>/<run>/...         # raw tool output, namespaced by tool — append-only, never overwritten
  endpoints.txt                # CANONICAL artifact: stable name, this is what the pipeline reads
  subs.txt
  screenshot.png               # (or screenshot.failed)
  findings/takeover.txt
  manifest.jsonl               # logical role -> real path + provenance
```

**Golden rule: no step reads from `raw/`.** Tools dump into `raw/<tool>/`; a small *normalize* step
promotes the result to its canonical name. When a tool changes its output name or format, only that
tool's normalize step breaks — never a downstream consumer. One place to fix, not the whole chain.

## 2. One source of truth for paths — no hardcoding

No worker writes a path literal. Centralize path computation so a rename happens once and everything
follows:

```bash
# lib/paths.sh — sourced by every worker
app_dir()   { echo "$BASE/targets/$1"; }
endpoints() { echo "$(app_dir "$1")/endpoints.txt"; }
subs()      { echo "$(app_dir "$1")/subs.txt"; }
raw_dir()   { echo "$(app_dir "$1")/raw/$2"; }     # raw_dir <app_id> <tool>
```

Steps call `endpoints "$app"`, never `"$dir/all_endpoints_clean.txt"`. In a Taskfile this is `vars`;
in Nextflow files travel through channels and are never referenced by path at all.

## 3. A manifest per workspace

`manifest.jsonl` maps logical **role → real path + provenance**. It is the answer to *"which file?"*:

```jsonl
{"role":"endpoints","path":"endpoints.txt","tool":"katana","input":"raw/katana/<run>/","ts":"<iso>"}
{"role":"subs","path":"subs.txt","tool":"subfinder","input":"meta.json:hosts","ts":"<iso>"}
```

- *"run a tool on the right file"* → query the manifest by role (`jq`), don't eyeball the directory.
- *"run a tool across many files"* → iterate every workspace's manifest filtering by role, instead of
  globbing guessed names. No more wrong-file mistakes.

## 4. Thin adapters around tools

The pipeline never calls a tool naked. Each tool gets a wrapper that: takes **logical** inputs, runs
the tool into `raw/<tool>/<run>/`, normalizes the output to its canonical path, and appends a manifest
row. The adapter is the seam that absorbs tool changes — when a tool's format/flags change, you edit a
~5-line adapter, nothing else.

## 5. Stable `app_id`, not a mutable name

Don't key a workspace on a volatile string. `<host>_<title>` embeds the title, which changes
(redirects, A/B, edits) → duplicate/orphaned workspaces. Use a **stable `app_id`** (e.g. a hash of
host+port, or of the cluster identity) as the directory key, and keep host/title/etc. inside
`meta.json` as metadata. Logical identity must not depend on a value a tool can change.

---

## Checklist for a new worker

- [ ] Reads/writes **only** via `lib/paths.sh` helpers (or Taskfile vars) — zero hardcoded paths.
- [ ] Raw output goes to `raw/<tool>/<run>/`; nothing downstream reads `raw/`.
- [ ] Promotes its result to the **canonical** name and appends a `manifest.jsonl` row.
- [ ] Keys the workspace on `app_id`, not on host/title.
- [ ] Still honors the dual interface (positional arg **or** stdin) and `output-dir-is-last-arg`
      conventions from `CLAUDE.md`.

## Current state

A contract-compliant foundation now exists under `utils/recon/lib/` (path/app_id/manifest
single sources of truth) and `utils/recon/adapters/` (one thin adapter per worker that
splits `run_`/`normalize_`, promotes raw output to canonical names, and appends a manifest
row). See `utils/recon/adapters/README.md`.

The legacy workers themselves are unchanged and still write tool-named files; the adapters
are the seam that makes the contract real. The live orchestration (`recon-orchestrator.sh`)
has NOT yet been re-wired onto the adapters — that lands with the Taskfile-only and
Dagu-only reproductions, each of which sources `lib/paths.sh` for paths. Until then, drive
the contract layer through the adapters directly.
