# Recon Contract Foundation — Design

**Date:** 2026-06-17
**Status:** Approved (brainstorming) → ready for implementation plan
**Scope:** Sub-project 1 of 3. This spec covers ONLY the shared contract foundation. The
two pipeline reproductions (a Taskfile-only orchestration and a Dagu-only orchestration)
are separate sub-projects with their own specs, built *on top of* this foundation.

---

## 1. Goal

Make the workspace/output contract described in [`CONVENTIONS.md`](../../../CONVENTIONS.md)
real, as a **tool-agnostic shared substrate** that both future reproductions
(Taskfile-only, Dagu-only) will sit on. Solve the two failure modes the contract targets:

- *"which file was the right one?"* → a per-workspace `manifest.jsonl` mapping role → real path.
- *"a tool renamed its output / changed its path and a later step broke"* → raw output is
  isolated under `raw/<tool>/<run>/`; a thin per-tool adapter promotes it to a canonical name.
  Only that adapter breaks on a tool change, never a downstream consumer.

This is the prerequisite the user sequenced first ("prima risolviamo il contract").

## 2. Decisions locked during brainstorming

1. **Two independent reproductions later** (Taskfile-only AND Dagu-only), not a combined
   stack. Consequence: the path single-source-of-truth must live in a *shared* layer
   (`lib/paths.sh`) that both orchestrators source — never re-declared as Taskfile `vars`
   and Dagu env separately, or we recreate the two-sources-of-truth anti-pattern.
2. **Thin adapter wrapping** (CONVENTIONS §4). The proven leaf/worker scripts are NOT
   rewritten — they run against live customer infra with carefully tuned rate limits.
   Each adapter wraps a worker: materialize the inputs the worker expects, run it into
   `raw/<tool>/<run>/`, normalize the output to a canonical name, append a manifest row.
3. **This spec = contract foundation only.** The two reproductions are deferred to their
   own specs.
4. **Approach A** (lib/ + per-worker adapters) over B (manifest-only, normalization
   duplicated in each orchestrator → rejected, two sources of truth) and C (generic
   data-driven normalizer → rejected, over-engineered for ~7 tools).

## 3. Workspace schema (canonical)

The contract applies to BOTH the scope-level surface area and per-app workspaces, so the
golden rule "no step reads from `raw/`" holds everywhere.

```
$BASE/                                  # engagement root — env var, never hardcoded
  att_surface/                          # SCOPE-LEVEL (produced by adapters/scope2surface)
    raw/<tool>/<run>/...                # naabu, httpx, tlsx, dnsx, subfinder … append-only
    subdomains.txt                      # CANONICAL
    httpx_full_metadata.jsonl           # CANONICAL  (input consumed by surfagr)
    findings/takeovers_scope.jsonl      # CANONICAL  (stage-1 takeover)
    manifest.jsonl
  targets/<app_id>/                     # PER-APP — keyed on stable app_id (§5)
    meta.json                           # identity: app_id, host (representative), port,
                                        #   base_url, title, tech[], status, cluster_hosts[]
    raw/<tool>/<run>/...                # katana, gau, urlfinder, subfinder, subjack … append-only
    endpoints.txt                       # CANONICAL  (from pipeline-recon)
    subs.txt                            # CANONICAL  (from pipeline-subenum)
    screenshot.png | screenshot.failed
    js/  html/                          # downloaded assets (canonical dirs)
    findings/takeover.txt               # CANONICAL  (stage-2 takeover)
    manifest.jsonl
```

Today's tool-named files (`all_endpoints_clean.txt`, `discovered_subs.txt`, `takeover.txt`,
`hosts.txt`, …) disappear from the public surface: they survive only inside `raw/`; the
adapter promotes them to the canonical names above.

`<run>` is a UTC timestamp (`date -u +%Y%m%dT%H%M%SZ`). Each invocation creates a new
append-only run dir; the canonical file always reflects the latest `normalize`.

## 4. New code layout

The existing worker scripts stay exactly where they are, untouched.

```
utils/recon/
  lib/
    paths.sh        # single source of truth for paths
    manifest.sh     # manifest_append helper
    appid.sh        # stable app_id computation
  adapters/
    scope2surface.sh
    surfagr.sh            # the app_id promoter (special)
    screenshotter.sh
    pipeline-recon.sh
    pipeline-subenum.sh
    takeover-scope.sh
    takeover-discovered.sh
  tests/
    fixtures/...          # sample raw outputs, sample httpx_full_metadata.jsonl
    run.sh                # runs all test_*.sh
    test_*.sh
  (existing workers: scope2surface.sh, surfagr.sh, … — unchanged)
```

## 5. `lib/paths.sh` — single source of truth

Everything derives from `$BASE`. No other file writes a literal path. The future Taskfile
and Dagu reproductions **source this file**; they do not re-declare paths.

```bash
# scope-level
surface_dir()   { echo "$BASE/att_surface"; }
subdomains()    { echo "$(surface_dir)/subdomains.txt"; }
httpx_meta()    { echo "$(surface_dir)/httpx_full_metadata.jsonl"; }
scope_findings(){ echo "$(surface_dir)/findings/takeovers_scope.jsonl"; }
surface_raw()   { echo "$(surface_dir)/raw/$1/$2"; }    # tool, run

# per-app  ($1 = app_id)
app_dir()       { echo "$BASE/targets/$1"; }
meta_json()     { echo "$(app_dir "$1")/meta.json"; }
endpoints()     { echo "$(app_dir "$1")/endpoints.txt"; }
subs()          { echo "$(app_dir "$1")/subs.txt"; }
screenshot()    { echo "$(app_dir "$1")/screenshot.png"; }
takeover()      { echo "$(app_dir "$1")/findings/takeover.txt"; }
raw_dir()       { echo "$(app_dir "$1")/raw/$2/$3"; }   # app_id, tool, run
manifest_path() { echo "$(app_dir "$1")/manifest.jsonl"; }

# common
new_run()       { date -u +%Y%m%dT%H%M%SZ; }
```

Scope-level raw uses the dedicated `surface_raw <tool> <run>` (not the per-app `raw_dir`).

## 6. `lib/appid.sh` — stable key (§5)

```bash
app_id_for() {   # $1 = host (DNS name), $2 = port
  printf '%s:%s' "$1" "$2" | sha1sum | cut -c1-12
}
```

- Hash on the **DNS hostname** of the cluster's representative/best host — NOT the IP
  (DHCP churn) and NOT the title (redirects / A-B / edits). Consistent with the repo's
  host-identity model that prefers names over IPs.
- 12 hex chars: collision risk negligible at engagement scale.
- Volatile host/title/etc. live inside `meta.json`, never in the key (§5).

## 7. `manifest.jsonl` — role → real path + provenance (§3)

One JSONL row per canonical artifact. `path` is **relative** to the workspace (portable if
the engagement directory is moved).

```jsonl
{"role":"endpoints","path":"endpoints.txt","tool":"katana+gau","input":"raw/pipeline-recon/<run>/","ts":"<iso>"}
{"role":"subs","path":"subs.txt","tool":"subfinder","input":"meta.json:cluster_hosts","ts":"<iso>"}
{"role":"takeover","path":"findings/takeover.txt","tool":"subjack","input":"endpoints.txt+subs.txt","ts":"<iso>"}
```

Helper:

```bash
manifest_append <app_id|_surface> <role> <rel_path> <tool> <input>   # ts via new_run/date -u
```

The first arg selects the manifest file: a real `app_id` → `targets/<app_id>/manifest.jsonl`;
the sentinel `_surface` → `att_surface/manifest.jsonl`. (Note this is independent of the raw-path
helpers: scope-level raw still uses `surface_raw`, per-app raw still uses `raw_dir`.)

This is what answers CONVENTIONS §3's two questions: *"which file for role X?"* → `jq` the
manifest; *"run a tool across all workspaces for role X"* → filter every manifest by role
instead of globbing guessed names.

## 8. Adapter pattern

Each adapter has two halves. The contract-relevant half (`normalize_`) is pure file
manipulation and is unit-testable offline; the network half (`run_`) is not unit-tested here.

```bash
source lib/paths.sh; source lib/manifest.sh; source lib/appid.sh

run_<tool>() {        # run = new_run; raw = raw_dir / surface_raw
  # materialize into the raw-dir the inputs the OLD worker expects
  # (e.g. write hosts.txt from meta.json:cluster_hosts), then invoke the worker UNCHANGED
}
normalize_<tool>() {  # promote raw tool-named output to canonical name + manifest row
  cp "$raw/<tool-named-file>" "$(endpoints "$app")"
  manifest_append "$app" endpoints endpoints.txt <tool> "raw/<tool>/$run/"
}
# main: resolve app_id (or _surface); run=$(new_run); run_<tool>; normalize_<tool>
```

The **input-staging** is the translation seam: the worker keeps reading `hosts.txt` /
`all_endpoints_clean.txt` as it does today, but the adapter materializes those files from
canonical sources first — so proven bash is never touched.

Where the underlying worker supported the dual interface (positional arg OR stdin) and the
output-dir-is-last-arg convention from `CLAUDE.md`, the adapter preserves it.

### 8.1 Adapter → canonical-promotion map

| adapter | worker (unchanged) | staged raw input | worker output → **canonical** | manifest role(s) |
|---|---|---|---|---|
| `scope2surface` | scope2surface.sh | scope.txt | `scans/subdomains.txt`→`att_surface/subdomains.txt`; `scans/httpx_full_metadata.jsonl`→idem | subdomains, httpx_meta |
| `surfagr` ⭐ | surfagr.sh | httpx_meta (canonical) | **fan-out**: each `<host>_<title>/` → `targets/<app_id>/meta.json` | meta |
| `screenshotter` | run-screenshotter.sh | staging dir: one subdir/app_id holding hosts.txt | `screenshot.png`/`.failed`→`targets/<app_id>/` | screenshot |
| `pipeline-recon` | pipeline-recon.sh | hosts.txt (from meta.json) | `all_endpoints_clean.txt`→`endpoints.txt`; `js/`,`html/`→idem | endpoints, js_assets, html_assets |
| `pipeline-subenum` | pipeline-subenum.sh | hosts.txt (from meta.json) | `discovered_subs.txt`→`subs.txt` | subs |
| `takeover-scope` | run-takeover-scope.sh | `subdomains.txt` (canonical) | jsonl→`att_surface/findings/takeovers_scope.jsonl` | takeovers_scope |
| `takeover-discovered` | run-takeover-discovered.sh | `endpoints.txt`+`subs.txt` (canonical) | `takeover.txt`→`findings/takeover.txt` | takeover |

### 8.2 `surfagr` — the app_id promoter ⭐

This is where §5 is enforced. surfagr still produces `raw/surfagr/<run>/targets/<host>_<title>/`
with `hosts.txt` + `info.txt`. The adapter's normalize half then, for each such dir:

1. reads the representative host + port (from `hosts.txt` first line / `info.txt`),
2. computes `app_id = app_id_for "$host" "$port"`,
3. creates `$BASE/targets/<app_id>/`,
4. writes `meta.json` = `{app_id, host, port, base_url, title, tech[], status, cluster_hosts[]}`
   (`cluster_hosts` from `hosts.txt`),
5. appends a manifest row, role `meta`.

surfagr itself is not modified — the adapter does all the keying.

### 8.3 subjack noise

The `[Not Vulnerable]` line subjack emits per host stays in `raw/`. `findings/takeover.txt`
keeps today's behavior (full output; operator filters at triage with `grep -v 'Not Vulnerable'`)
so the adapter does not change semantics.

## 9. Testing (offline — no live customer traffic)

- **`normalize_<tool>`** — pure file manipulation. Feed a fixture raw-output dir; assert the
  canonical file exists at the path `paths.sh` dictates, and the manifest row has the
  expected role + relative path. No network.
- **`app_id_for`** — pure function. Same `host:port` ⇒ same id; different host ⇒ different id.
- **`surfagr` promoter** — fixture raw with two `<host>_<title>/` dirs ⇒ assert two
  `targets/<app_id>/` created with correct `meta.json` + manifest rows.
- **`run_<tool>`** (the network half) — NOT unit-tested here; covered by an integration smoke
  run in the Taskfile/Dagu reproduction phase.
- **Framework** — plain bash with a tiny assert helper; `tests/run.sh` runs all `test_*.sh`.
  Zero dependencies. bats optional if already installed.

## 10. Backward compatibility & validation

- `recon-orchestrator.sh` is left as-is (legacy; it already points at the pre-move
  `/opt/custom-tools/recon/` path and is broken). This phase does NOT rewire any
  orchestrator — adapters are invoked by the future Taskfile/Dagu reproductions.
- Phase-1 validation is the per-adapter fixture tests in §9, not a full live run.

## 11. Out of scope (explicit)

- The Taskfile-only reproduction (own spec).
- The Dagu-only reproduction (own spec).
- Re-decomposing `pipeline-recon` into finer per-tool steps — its sub-tools (gau, urlfinder,
  katana, downloader) stay wrapped as one composite adapter for now; finer decomposition, if
  wanted, belongs to a reproduction spec.
- Rewriting any worker, or changing rate limits / tool flags.

## 12. Open knobs (defaults chosen; flag here if you want to revisit)

- app_id hash length: **12 hex chars**.
- manifest `path`: **relative** to workspace.
- scope-level raw: dedicated **`surface_raw`** helper (vs an `app_id=_surface` overload).
- scope-level findings location: **`att_surface/findings/`** (vs `$BASE/findings/`).
- area name **`att_surface/`** (matches the legacy orchestrator's dir name).
