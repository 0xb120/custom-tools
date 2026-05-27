# Per-App Screenshot Triage — Design

**Date:** 2026-05-05
**Status:** Approved, ready for implementation plan
**Scope:** Add a single screenshot per clustered web application to the recon pipeline, before per-app deep recon begins, to enable visual triage during long-running scans.

---

## Background

The current pipeline (`scope2surface.sh` → `surfagr.sh` → `pipeline-recon.sh`) discovers web surface and clusters vhosts by `Title + Content-Length + Webserver` into per-application directories under `<surface_dir>/targets/<host>_<title>/`. Each app directory contains `hosts.txt` and `info.txt`.

The pipeline produces no visual artifact for the operator. With dozens of clustered apps per engagement, triaging the output means reading text files and opening URLs by hand — slow and easy to miss interesting targets (login pages, default installs, exposed dev dashboards).

This change adds **one screenshot per app**, captured immediately after clustering, as the first piece of human-reviewable output the engagement produces.

## Goals

- Operator can visually scan all apps in an engagement at a glance.
- Screenshots become available before the long per-app pipeline (`pipeline-recon.sh`) begins, so triage can start in parallel with deep recon.
- Zero new external dependencies.
- Implementation isolated to one new script + a small edit, so a future swap to a richer tool (gowitness) is a single-file change.

## Non-Goals

- Multi-screenshot-per-app, full-page captures, or per-vhost differentials. One first-viewport PNG per app cluster is enough for triage.
- Authenticated screenshotting. Out of scope for this change.
- A web-based grid report. Recorded as future work; gating reason below.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Granularity | Per app (one shot per cluster) | Aligns with the work unit `surfagr.sh` already produces. Per-host duplicates the same view N times when vhosts share an app. |
| Tool | `httpx -screenshot` | Already in PATH; same Project Discovery toolchain; chromedp under the hood; outputs PNG + JSONL with `screenshot_path`. |
| Placement | New script `recon/run-screenshotter.sh`, invoked once from `surfagr.sh` after clustering, before parallel `pipeline-recon.sh` dispatch | One httpx invocation amortises chromedp startup; screenshots land before deep recon starts so operator can triage in parallel; matches the codebase's per-phase-script convention; isolated for a future swap. |
| Host selection | Same logic as `pipeline-recon.sh:40-43` (prefer non-IP host, else `head -n 1`) | Consistent with existing BEST_HOST selection elsewhere; vhosts inside one cluster are by definition rendering the same app. |
| Failure mode | Non-fatal at the engagement level; per-app `screenshot.failed` marker on capture failure | An engagement should never abort because one host is dead; absence of PNG should be explicit, not silent. |
| Future migration | TODO comment in `run-screenshotter.sh` pointing at gowitness v3.x | gowitness adds a `report serve` web UI that becomes meaningfully better at engagement scale (>20 apps); for current scale, dependency-free path wins. |

## Components

### `recon/run-screenshotter.sh` (new)

**Interface:**
```
run-screenshotter.sh <surface_dir>
```
Where `<surface_dir>` is the directory containing the per-app subdirectories produced by `surfagr.sh` (i.e. `<dest_dir>/targets/`).

**Behaviour:**
1. Validate `<surface_dir>` exists and contains at least one app subdirectory; exit non-zero on missing dir, exit zero on empty (nothing to do).
2. For each app subdirectory containing `hosts.txt`:
   - Pick BEST_HOST: first non-IP URL from `hosts.txt`, else first line.
   - Append BEST_HOST to a tempfile, keyed in a sidecar map (`url -> app_dir`) so PNGs can be distributed back after httpx exits.
3. Run **one** `httpx` invocation against the BEST_HOSTs tempfile with screenshot mode enabled. Output JSONL written to a temp file; PNGs written to a temp screenshot directory.
4. After httpx exits, parse the JSONL: for each entry with a successful `screenshot_path`, copy the PNG into the matching `app_dir` as `screenshot.png`.
5. For any app whose BEST_HOST does not appear in the JSONL, or whose entry has no `screenshot_path` field, write a one-line `screenshot.failed` marker into the app dir containing the reason. Possible reasons (httpx writes a screenshot whenever Chromium rendered a page, so non-200 responses still produce PNGs and are *not* failures):
   - `host not present in httpx output` — connection refused, DNS failure, TLS handshake failure, or other pre-render error
   - `screenshot capture timeout` — Chromium loaded but did not finish within `-screenshot-timeout`
   - `screenshot path missing in entry` — httpx returned an entry but no `screenshot_path` field (defensive case)
6. Clean up tempfiles and temp screenshot dir on exit (trap-based).

**httpx flags:**
```
httpx \
  -l <tempfile_with_best_hosts> \
  -screenshot \
  -system-chrome \
  -screenshot-timeout 15 \
  -no-screenshot-bytes \
  -no-screenshot-full-page \
  -silent \
  -j \
  -o <tmp>/httpx_screenshots.jsonl \
  -srd <tmp>/screenshots
```

Rationale for each non-default flag:
- `-system-chrome`: avoids httpx's bundled chromium download path on first run; uses an installed Chrome/Chromium.
- `-screenshot-timeout 15`: per-host budget. Default is 10s; 15s covers slower SPAs without making engagement-wide stage too slow.
- `-no-screenshot-bytes`: do not embed screenshot bytes inline in JSONL; we read the PNG from disk via `screenshot_path` instead. Keeps JSONL small.
- `-no-screenshot-full-page`: viewport-only capture. ~5x faster than full-page and sufficient for triage (login pages, banner pages, dashboards are above-the-fold).
- `-silent`, `-j`: silent mode, JSON output. Already the convention in this codebase.

**TODO comment (header of file):**
```bash
# TODO(gowitness): migrate to gowitness v3.x for the report-serve UI
# when engagement size warrants a grid-view triage workflow.
# Current httpx -screenshot path is dependency-free and good for ≤20 apps;
# above that, `gowitness report serve` is meaningfully better.
# Reference: https://github.com/sensepost/gowitness
```

### `recon/surfagr.sh` (edit)

Insert a new section between the clustering `while read -r group ... done` loop (currently ending at line 113) and the parallel pipeline dispatch comment block at line 115:

```bash
# ===================
# VISUAL TRIAGE SHOTS
# ===================
echo "[INFO] Capturing per-app screenshots..." >&2
"$SCRIPT_DIR/run-screenshotter.sh" "$dest_dir/targets" || \
    echo "[WARN] Screenshot stage had errors (non-fatal); continuing." >&2
```

`$SCRIPT_DIR` is already defined at line 122 in the existing code; the new section runs before that definition, so either move the `SCRIPT_DIR` assignment up to the top of the file (preferred — single source of truth) or repeat the same one-liner. Move it up.

## Output Layout

After this change, each app dir contains:
```
<dest_dir>/targets/<host>_<title>/
├── hosts.txt          (existing)
├── info.txt           (existing)
└── screenshot.png     (NEW — first-viewport PNG)
    OR
└── screenshot.failed  (NEW — single-line reason, no PNG)
```

Exactly one of `screenshot.png` / `screenshot.failed` is present per app dir. The fixed filenames let any future per-engagement Markdown report reference them by relative path without scanning.

## Error Handling

| Case | Behaviour |
|---|---|
| `<surface_dir>` missing | Exit 1, message to stderr |
| `<surface_dir>` empty (no `app_*` subdirs) | Exit 0 with info message; nothing to do |
| `httpx` not in PATH | Exit 1 (matches the implicit assumption of all other scripts in this repo) |
| Single app's screenshot times out | `screenshot.failed` marker for that app; other apps still succeed |
| `httpx` exits non-zero overall | Still attempt to distribute any PNGs that landed; do not delete the screenshot tempdir until distribution is complete |
| Surfagr's call to screenshotter fails | `surfagr.sh` logs `[WARN]` and continues with `pipeline-recon.sh` dispatch; engagement is not aborted |

## Performance Notes

- Single httpx invocation amortises chromedp/Chromium startup cost across all apps in the engagement (significant — chromedp cold start is ~1s per process).
- httpx default screenshot concurrency is reasonable; do not override unless engagements show contention.
- Viewport-only capture is ~5x faster than full-page and produces ~50-200KB PNGs vs ~500KB-2MB for full-page.

## Testing

Manual smoke test, no automated tests (consistent with the rest of the codebase).

Steps:
1. Take a recent engagement's `<surface_dir>/targets/` directory.
2. Run `recon/run-screenshotter.sh <surface_dir>/targets`.
3. Verify each `app_*/` either contains `screenshot.png` (and that the PNG opens and looks right) or `screenshot.failed` (and the reason is plausible).
4. Run `recon/surfagr.sh` end-to-end against `httpx_full_metadata.jsonl` from the same engagement; verify the screenshot stage runs between clustering and `pipeline-recon.sh` dispatch, and that `pipeline-recon.sh` still completes successfully.

Edge cases to exercise during smoke test:
- App cluster whose only host is a dead IP (expect `screenshot.failed`).
- App cluster where BEST_HOST returns non-200 (e.g., 401 login redirect) — expect a successful PNG of whatever Chromium rendered, since 401 still returns a body.
- App cluster on a non-standard port (`:8443`, etc.) — verify URL passes through correctly.

## Future Work

- **gowitness migration**: when engagement-scale visual triage becomes a routine pain (estimated >20 apps per engagement on a recurring basis), swap `run-screenshotter.sh`'s implementation to gowitness v3.x. The interface contract (`run-screenshotter.sh <surface_dir>` producing `screenshot.png` per app) stays unchanged; only the script body changes. `surfagr.sh` is untouched. gowitness adds a `report serve` web UI for grid-view triage and a SQLite DB of metadata for cross-engagement queries.
- **Per-engagement HTML index**: a top-level script that walks `<dest_dir>/targets/` and emits an `index.html` with embedded screenshot thumbnails, app titles, and tech-stack tags. Independent of this change.
