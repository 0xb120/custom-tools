# Contract adapter layer

Thin adapters that wrap the unchanged worker scripts in `../` and make them honor the
workspace/output contract in [`CONVENTIONS.md`](../../../CONVENTIONS.md). The path single
source of truth lives in [`../lib/paths.sh`](../lib/paths.sh); `app_id` in
[`../lib/appid.sh`](../lib/appid.sh); manifest provenance in
[`../lib/manifest.sh`](../lib/manifest.sh).

The two future reproductions (Taskfile-only, Dagu-only) MUST source `lib/paths.sh` for
every path rather than re-declaring literals — that is what keeps a single source of truth
across both orchestrators.

## Each adapter has two halves

- `run_<tool>`      — materializes the inputs the legacy worker expects, runs it into
                      `raw/<tool>/<run>/`, echoes the run id. (Hits live infra.)
- `normalize_<tool>` — promotes the raw output to its canonical name and appends a
                      `manifest.jsonl` row. (Pure file manipulation; unit-tested offline.)

Adapters are sourceable: they only run `main` when executed directly, so tests source them
and call `normalize_` against fixtures.

## Invocation order (what the reproductions will wire up)

```
scope2surface        -> att_surface/{subdomains.txt, httpx_full_metadata.jsonl}
surfagr   (promoter) -> targets/<app_id>/meta.json            # enforces stable app_id
screenshotter        -> targets/<app_id>/screenshot.png
takeover-scope       -> att_surface/findings/takeovers_scope.jsonl   # stage 1 (parallel)
per app_id:
  pipeline-recon     -> targets/<app_id>/{endpoints.txt, js/, html/}
  pipeline-subenum   -> targets/<app_id>/subs.txt
  takeover-discovered-> targets/<app_id>/findings/takeover.txt        # stage 2
```

## Required env

- `BASE` — engagement root (e.g. `/scans/<scan_id>`). All paths derive from it.

## Known coupling

`../surfagr.sh` invokes `../run-screenshotter.sh` internally, so `run_surfagr` triggers a
screenshot pass as a side effect. The `screenshotter` adapter is the canonical screenshot
producer; the reproduction phase decides how to handle the redundancy.

## Tests

```bash
bash ../tests/run.sh
```
Offline only — no network, no live customer traffic.
