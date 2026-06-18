# Recon Dagu Reproduction — Design

**Date:** 2026-06-18
**Status:** Approved (brainstorming) → ready for implementation plan
**Scope:** Sub-project 2 of 3. Reproduces the recon pipeline orchestration as a **Dagu**
DAG, on top of the already-built contract foundation (`utils/recon/lib/` + `adapters/`,
branch `feat/recon-contract-foundation`). The Taskfile-only reproduction is the separate,
remaining sub-project.

---

## 1. Goal

Replace the legacy `recon-orchestrator.sh` end-to-end driver with a Dagu DAG that invokes
the contract adapters — producing the canonical `app_id`-keyed workspace — while preserving
the legacy ordering, parallelism, and conservative concurrency. Dagu provides the DAG
visibility, per-app parallelism, and dynamic fan-out the contract phase deferred.

The legacy pipeline shape being reproduced (from `recon-orchestrator.sh`):
scope2surface → { takeover-scope (stage-1, background) ∥ surfagr → screenshotter → per-app
fan-out: (pipeline-recon ∥ pipeline-subenum) → takeover-discovered } → wait stage-1.

## 2. Decisions locked during brainstorming

1. **Approach A** — parent DAG + child per-app DAG with dynamic `parallel` fan-out. (B: a
   flat static DAG can't enumerate the runtime-discovered apps without pushing a bash `for`
   loop back inside a single step — rejected. C: monolithic child step — rejected, loses
   recon∥subenum→takeover visibility.)
2. **Verification = install Dagu + offline smoke test with stubbed adapters.** Not author-only,
   not lint-only. The smoke test runs the real DAG with the leaves swapped for stubs that
   write canonical fixtures — validating orchestration wiring without live customer traffic.
3. **Build on the contract foundation**, do not modify the adapters or workers. The only
   foundation change is a small additive helper in `lib/paths.sh` (`app_ids`).
4. **Dagu never writes an artifact path literal.** It knows only `BASE` and `ADAPTER_DIR`;
   all artifact paths resolve inside the adapters via `lib/paths.sh`. This keeps the single
   source of truth for paths intact across both orchestrators (the premise of the
   two-independent-reproductions decision).

## 3. DAG topology

### 3.1 Parent — `recon.yaml`

Params: `BASE` (engagement root), `SCOPE` (scope file path). DAG-level `env`: `BASE`,
`ADAPTER_DIR` (default `utils/recon/adapters`). Steps:

| step | invokes | depends | notes |
|---|---|---|---|
| `scope2surface` | `${ADAPTER_DIR}/scope2surface.sh ${SCOPE}` | — | produces `att_surface/{subdomains.txt,httpx_full_metadata.jsonl}` |
| `takeover-scope` | `${ADAPTER_DIR}/takeover-scope.sh` | `scope2surface` | stage-1; no step depends on it except `done` → runs concurrently. `continueOn: failure` |
| `surfagr` | `${ADAPTER_DIR}/surfagr.sh` | `scope2surface` | app_id promoter → `targets/<app_id>/meta.json` |
| `screenshotter` | `${ADAPTER_DIR}/screenshotter.sh` | `surfagr` | one batch pass; runs ∥ the per-app fan-out |
| `enumerate` | `app_ids_json` (via lib) | `surfagr` | `output: APP_IDS` — JSON array of app_ids |
| `per-app` | child `app.yaml` | `enumerate` | `parallel: { items: ${APP_IDS}, max_concurrent: 3 }`, `params: APP_ID=${ITEM}` (+ BASE, ADAPTER_DIR) |
| `done` | no-op (`true`) | `[per-app, takeover-scope, screenshotter]` | the join / `wait` |

`screenshotter` runs in parallel with `per-app` (both gated on `surfagr`/`enumerate`), so
visual triage can begin while the long per-app scans run — the stated intent of the legacy
"screenshot before deep recon" stage, improved from serial to parallel.

### 3.2 Child — `app.yaml`

Params: `BASE`, `APP_ID`, `ADAPTER_DIR`. Steps:

| step | invokes | depends |
|---|---|---|
| `recon` | `${ADAPTER_DIR}/pipeline-recon.sh ${APP_ID}` | — |
| `subenum` | `${ADAPTER_DIR}/pipeline-subenum.sh ${APP_ID}` | — |
| `takeover` | `${ADAPTER_DIR}/takeover-discovered.sh ${APP_ID}` | `[recon, subenum]` |

`recon` and `subenum` have no dependency between them → run concurrently, matching the
legacy two-concurrent-`xargs` fan-out.

### 3.3 Concurrency & resilience (conservative — runs against live infra)

- `max_concurrent: 3` on the per-app fan-out = the legacy `xargs -P 3`.
- `takeover-scope`: `continueOn: failure` (stage-1 errors never abort the engagement; the
  adapter already wraps the worker in `|| true`).
- A single app's child-DAG failure does not kill the others (Dagu parallel continues
  remaining items); the failure is reported in the run status.
- **Retries disabled by default** — do not hammer live customer infra.

## 4. Contract integration

- `BASE` and `ADAPTER_DIR` are DAG-level `env` (sourced from params), inherited by every
  step. The adapters already require `BASE` and self-source `lib/`.
- Dagu writes **no artifact path literal**. The only structural knowledge it needs is the
  list of app_ids, which it obtains from the single source of truth, not a guessed glob.
- **Additive `lib/paths.sh` helpers** (the only foundation change; both reproductions need
  workspace enumeration, so it belongs in `lib/`):

  ```bash
  app_ids()      { for d in "$BASE"/targets/*/; do [ -d "$d" ] && basename "$d"; done; }
  app_ids_json() { app_ids | jq -R . | jq -s -c .; }   # ["<id1>","<id2>"] for items: ${APP_IDS}
  ```

  The `enumerate` step runs `app_ids_json` and captures it via `output: APP_IDS`.

## 5. Smoke test (offline, no live customer traffic)

The DAG is parameterized on `ADAPTER_DIR`, making the DAG itself the unit under test: the
real DAG runs with only the leaves swapped.

- **Stub adapters** under `utils/recon/tests/dagu/stubs/` — one per adapter, with the SAME
  filename, args, and `BASE` env contract. Instead of invoking real tools, each writes its
  canonical artifact(s) directly via the REAL `lib/paths.sh` + `lib/manifest.sh` (and the
  real `lib/appid.sh` for surfagr), then appends the manifest row. So the stubs exercise the
  real path/app_id/manifest contract and the real `enumerate` step — only tool execution is
  faked. Example stub behaviors:
  - `scope2surface`: write `subdomains.txt` + a 2-vhost `httpx_full_metadata.jsonl` fixture + manifest rows.
  - `surfagr`: read `httpx_meta`, compute real app_ids via `lib/appid.sh`, write 2 `targets/<app_id>/meta.json` + manifest.
  - `screenshotter`/`pipeline-recon`/`pipeline-subenum`/`takeover-scope`/`takeover-discovered`: write their canonical outputs (`screenshot.png`, `endpoints.txt`+`js/`+`html/`, `subs.txt`, `findings/takeovers_scope.jsonl`, `findings/takeover.txt`) + manifest rows.
- **`test_dagu_smoke.sh`** runs `dagu start recon.yaml -- BASE=<tmp> SCOPE=<fixture> ADAPTER_DIR=<stubs>`
  (exact param-passing syntax pinned during implementation), then asserts:
  - the full workspace tree exists: `att_surface/{subdomains.txt, httpx_full_metadata.jsonl, findings/takeovers_scope.jsonl, manifest.jsonl}`, and ≥2 `targets/<app_id>/` each with `meta.json`, `endpoints.txt`, `subs.txt`, `screenshot.png`, `findings/takeover.txt`, `manifest.jsonl`;
  - the fan-out ran for the expected number of app_ids;
  - ordering (`takeover` after `recon`+`subenum`) from the Dagu run status/log.
- This validates the orchestration wiring (enumerate → fan-out, concurrency cap, `depends`,
  the stage-1 parallel branch, the `done` join) end-to-end and offline. The real adapters are
  already unit-tested; the live `run_` halves (real tools) are validated only in a real
  engagement — documented, not tested here.

## 6. Install (first implementation task)

Install Dagu (single Go binary, pinned version), verify `dagu version`, and **pin the exact
YAML field syntax against the installed binary's bundled examples / `dagu start --help`**:
the step command field (`run:` vs `command:`), child-DAG invocation form, multi-document
`---` support, and `max_concurrent` spelling. The design's *structure* is fixed; the exact
field spellings are confirmed here before the DAGs are authored. The smoke test then drives
the YAML to correctness empirically.

## 7. File layout

```
utils/recon/orchestration/dagu/
  recon.yaml          # parent DAG
  app.yaml            # child DAG (per app_id)
  README.md           # how to run, params, what it reproduces
utils/recon/tests/dagu/
  stubs/              # stub adapters (same interface, canonical output via lib/)
  fixtures/           # sample scope file (+ any fixture inputs the stubs need)
  test_dagu_smoke.sh  # runs the DAG with stubs, asserts the workspace tree
utils/recon/lib/paths.sh   # + app_ids() / app_ids_json()  (additive)
```

## 8. How to run (entry point replacing the legacy orchestrator)

```bash
dagu start utils/recon/orchestration/dagu/recon.yaml -- BASE=/scans/acme SCOPE=/path/scope.txt
```
(Exact `--` param-passing syntax pinned during implementation against the installed binary.)

## 9. Out of scope (explicit)

- The Taskfile-only reproduction (separate sub-project; will reuse `app_ids()` and the same
  `BASE`/adapter invocation contract).
- Modifying any adapter or worker (the only foundation change is the additive `app_ids` helper).
- Testing the live `run_` halves / real tools (network; validated in real engagements).
- A Dagu scheduler/cron, web UI deployment, distributed workers — just the DAG definition
  and its offline smoke test.

## 10. Open knobs (defaults chosen; flag to revisit)

- `max_concurrent`: **3** (matches legacy `xargs -P 3`).
- `screenshotter` runs **parallel** to the per-app fan-out (vs serial-before, as legacy did).
- Dagu install method/version: pinned single binary; exact method decided at install task.
- DAG/test file location: under `utils/recon/orchestration/dagu/` and `utils/recon/tests/dagu/`.
- `app_ids` added to `lib/paths.sh` (vs a Dagu-local helper) — chosen because the Taskfile
  reproduction needs the same enumeration.
