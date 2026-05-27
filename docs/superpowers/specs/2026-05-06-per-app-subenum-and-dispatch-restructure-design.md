# Per-App Subdomain Enumeration + Dispatch Restructure — Design (Branch 2)

**Date:** 2026-05-06
**Status:** Approved, ready for implementation
**Scope:** Add a per-app subdomain enumeration pipeline that runs in parallel with the existing `pipeline-recon.sh`, and restructure dispatch responsibility so `recon-orchestrator.sh` becomes the single dispatcher for both pipelines (currently `surfagr.sh` dispatches `pipeline-recon.sh` via `xargs`, leaving the orchestrator's loop redundant). Stage 2 takeover input expands to also consider subenum-discovered hosts.

---

## Background

`pipeline-recon.sh` currently does passive OSINT + crawling + downloading per app. It does **not** do subdomain enumeration — the only subdomain enumeration in the pipeline is at the engagement level inside `scope2surface.sh`. Subdomains discovered later (from per-app crawling and OSINT) get into the system as URLs, not as standalone hosts to enumerate further.

This branch adds a sibling per-app pipeline (`pipeline-subenum.sh`) that takes each app's `hosts.txt` (the vhosts assigned to that cluster), runs `subfinder` against them, resolves with `dnsx`, and writes live discovered subs to `<app_dir>/discovered_subs.txt`.

To make this work cleanly, the dispatch responsibility shifts: `surfagr.sh` stops dispatching `pipeline-recon.sh`, and `recon-orchestrator.sh` dispatches both `pipeline-recon.sh` and `pipeline-subenum.sh` per-app, in parallel via `xargs -P 3` each. This also resolves the pre-existing duplication where `surfagr.sh`'s `xargs` and the orchestrator's for-loop both intended to run `pipeline-recon.sh`.

Stage 2 takeover (`run-takeover-discovered.sh`) gains a second input: it now considers the union of hosts from `all_endpoints_clean.txt` AND `discovered_subs.txt`, so subjack covers subenum-discovered hosts as well.

## Goals

- Each app's vhost set seeds a passive subfinder pass; live results land in a per-app file ready for downstream consumption (Stage 2 takeover, future SAST/dirbust passes).
- Dispatch lives in one place (`recon-orchestrator.sh`); `surfagr.sh` becomes purely a clustering+screenshot step.
- The two per-app pipelines (`pipeline-recon.sh` and `pipeline-subenum.sh`) run truly concurrently across apps, not sequentially.
- No new dependencies — `subfinder`, `dnsx`, `unfurl` are already in PATH (Project Discovery + Tom Nomnom).
- Stage 2 takeover discovers takeovers on subenum-derived hosts without requiring a separate scan.

## Non-Goals

- Active subdomain bruteforce (`shuffledns`-style). Per-user choice: passive `subfinder` only, lower noise, customer-friendly.
- Apex-domain expansion. Per-user choice: feed the host list as-is to `subfinder -dL`, so we find siblings of `app.example.com`, not siblings of `example.com`.
- Refactoring the BEST_HOST selection logic (still duplicated between `pipeline-recon.sh:40-43` and `run-screenshotter.sh`). Out of scope.
- Touching the orphaned scripts (`run-web-sast.sh`, `pipeline-local-discovery.sh`).

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Subenum input | Full host list from `<app_dir>/hosts.txt`, dedup-extracted via `unfurl format %d` | User-chosen: conservative scope, finds siblings of the actual vhosts rather than apex siblings. |
| Subenum tool | `subfinder -dL` (passive sources only) | User-chosen: passive minimises customer-side noise; subfinder is already in PATH. |
| Resolution | Pipe subfinder output through `dnsx -silent` | User-chosen: only live subs land in output; junk is filtered out at the pipeline stage. |
| Subenum output | `<app_dir>/discovered_subs.txt`, sorted + deduplicated | One file per app, host list (no scheme/port). Easy to consume from Stage 2 and future tooling. |
| Concurrency model | Two parallel `xargs -P 3` invocations in the orchestrator (one per pipeline) | True per-pipeline concurrency across apps, with a controlled cap of 3 workers each. |
| `surfagr.sh` change | Remove the `xargs` dispatch of `pipeline-recon.sh` (lines 130-133) and the `PIPELINE_WORKER` existence check (lines 122-128). Keep clustering + screenshotter call. | Single source of truth for dispatch (the orchestrator). Resolves the long-standing duplication. |
| Stage 2 input | Union of `<app_dir>/all_endpoints_clean.txt` (host-extracted via unfurl) AND `<app_dir>/discovered_subs.txt` | Stage 2 should cover subenum-discovered hosts too. Fits user's "re-check" choice for Stage 2 input. |
| Failure mode | Subenum non-fatal at the engagement level. Empty `discovered_subs.txt` is success (subfinder found nothing or all candidates failed dnsx resolution). | Engagement should never abort because passive sources had no hits. |

## Components

### `recon/pipeline-subenum.sh` (new)

**Interface:**
```
pipeline-subenum.sh <app_dir>
```

**Behaviour:**
1. Validate `<app_dir>` exists and contains `hosts.txt`. If not, log info and exit 0.
2. Verify `subfinder`, `dnsx`, `unfurl` are in PATH; exit 1 with a clear error otherwise.
3. Extract domains from `hosts.txt` (URLs → bare domains via `unfurl format %d`), sort+dedup, write to a tempfile.
4. If the domains tempfile is empty, log info and exit 0.
5. Run subfinder on the domains tempfile, pipe through dnsx for resolution, sort+dedup, write to `<app_dir>/discovered_subs.txt`:
   ```
   subfinder -dL <tmp/domains.txt> -silent | dnsx -silent | sort -u > <app_dir>/discovered_subs.txt
   ```
6. Print one summary line on stderr: `[INFO] subenum: N live subdomains discovered → <app_dir>/discovered_subs.txt`.
7. Trap-cleanup the tempfile on exit.
8. Always exit 0 unless dependency / input checks failed.

### `recon/surfagr.sh` (modified)

**Remove** lines 119-133 (the `PARALLEL_APPS` constant, `SCRIPT_DIR` and `PIPELINE_WORKER` definitions used only for that dispatch, the executable check, the `[INFO] Starting recon pipeline...` echo, and the `xargs -P` dispatch).

`SCRIPT_DIR` is still needed earlier in the script (it's used by the screenshotter call near line 116), so keep that one. Only remove the duplicate `SCRIPT_DIR` definition and the dispatch block.

After the change, `surfagr.sh`'s responsibilities are:
1. Validate the input JSONL.
2. Cluster vhosts into `<dest>/targets/<host>_<title>/` directories with `hosts.txt` and `info.txt`.
3. Call `run-screenshotter.sh <dest>/targets/`.
4. Exit.

The "took N seconds" timer at the bottom stays.

### `recon/recon-orchestrator.sh` (modified)

Replace the existing per-app for-loop:

```bash
# 3. Per-app recon
for app_dir in "$BASE/apps"/targets/*/; do
    ./recon/pipeline-recon.sh "$app_dir"
done
```

with two concurrent `xargs -P 3` dispatches:

```bash
# 3. Per-app pipelines (recon + subenum) in parallel across apps
find "$BASE/apps/targets" -mindepth 1 -maxdepth 1 -type d | \
    xargs -P 3 -I {} ./recon/pipeline-recon.sh {} &
PIPELINE_RECON_PID=$!

find "$BASE/apps/targets" -mindepth 1 -maxdepth 1 -type d | \
    xargs -P 3 -I {} ./recon/pipeline-subenum.sh {} &
PIPELINE_SUBENUM_PID=$!

wait $PIPELINE_RECON_PID $PIPELINE_SUBENUM_PID
```

The Stage 2 takeover for-loop (which iterates `"$BASE/apps"/targets/*/` after the per-app pipelines) stays unchanged but now sees both `all_endpoints_clean.txt` AND `discovered_subs.txt` populated.

### `recon/run-takeover-discovered.sh` (modified)

Expand the host-extraction step to read both files. Replace:

```bash
unfurl format %d < "$ENDPOINTS_FILE" | sort -u > "$HOSTS_FILE"
```

with:

```bash
{
    unfurl format %d < "$ENDPOINTS_FILE"
    if [ -f "$APP_DIR/discovered_subs.txt" ]; then
        cat "$APP_DIR/discovered_subs.txt"
    fi
} | sort -u > "$HOSTS_FILE"
```

`discovered_subs.txt` is already a host list (no scheme), so it's appended directly. The combined sort+dedup produces the union.

The pre-existing guard at the top (`if [ ! -f "$ENDPOINTS_FILE" ] then exit 0`) stays as-is, since the `all_endpoints_clean.txt` file is the canonical Stage 2 input — if it's missing, there's nothing to do regardless of whether subenum produced output.

## Output Layout

```
<scan_base>/
└── apps/targets/
    └── <host>_<title>/
        ├── hosts.txt
        ├── info.txt
        ├── screenshot.png
        ├── all_endpoints_clean.txt     (from pipeline-recon)
        ├── discovered_subs.txt         NEW — from pipeline-subenum
        └── takeover.txt                (Stage 2 — input now includes both files above)
```

## Error Handling

| Case | Behaviour |
|---|---|
| `<app_dir>` missing or no `hosts.txt` | Subenum logs `[INFO]` and exits 0. Other apps unaffected. |
| `subfinder` / `dnsx` / `unfurl` not in PATH | Subenum exits 1 with clear error. Other workers continue (xargs doesn't abort sibling jobs by default). |
| Subfinder finds nothing | `discovered_subs.txt` is empty. Stage 2 still runs against `all_endpoints_clean.txt`. |
| Subfinder errors on a single domain | Per-domain failure is internal to subfinder; the pipeline output is whatever subfinder returned. |
| `dnsx` resolves zero subs (none live) | Empty `discovered_subs.txt`. Same as "subfinder found nothing." |
| Stage 2 with no `discovered_subs.txt` | `[ -f ... ]` guard skips the cat; behaviour identical to current Stage 2. |

## Performance Notes

- Two concurrent `xargs -P 3` = up to 6 concurrent workers across both pipelines. They share network/CPU but workloads are mostly waiting on external services (subfinder API queries, dnsx DNS lookups, gau/urlfinder OSINT, katana crawl), so they overlap cleanly.
- Subfinder is fast (passive only, mostly API calls). Per-app, subfinder + dnsx typically completes in 30-60s.
- For very large engagements (>50 apps) with both pipelines running, you'll see ~6 sustained workers. Acceptable for current customer scale; if it becomes an issue, the cap is one number to drop.

## Testing

Manual smoke test (consistent with the rest of the codebase, no automated tests).

Steps:
1. Create a synthetic app dir: `/tmp/subenum-test/app1/hosts.txt` with `https://example.com\nhttps://example.org`.
2. Run `recon/pipeline-subenum.sh /tmp/subenum-test/app1`. Verify:
   - `discovered_subs.txt` exists (probably empty for example.com/.org, but file should be created).
   - Exit code 0.
   - Stderr shows the summary line.
3. Run `recon/surfagr.sh` against a small `httpx_full_metadata.jsonl` fixture and verify:
   - Clustering still works (apps under `<dest>/targets/<host>_<title>/`).
   - Screenshotter still called.
   - **No more `[INFO] Starting recon pipeline ...` line.** `surfagr.sh` no longer dispatches `pipeline-recon.sh`.
4. Run `recon/recon-orchestrator.sh <id> <scope>` end-to-end. Verify in the log:
   - `pipeline-recon.sh` runs in xargs-parallel.
   - `pipeline-subenum.sh` runs in xargs-parallel concurrently.
   - Both finish before Stage 2 starts.
   - Stage 2 takeover for each app reads from both `all_endpoints_clean.txt` and `discovered_subs.txt` (verify by adding a short marker line into one of them and confirming it shows up in the host list subjack scans).

Edge cases to exercise:
- App dir with empty `hosts.txt`: subenum exits 0 quickly, no `discovered_subs.txt` written.
- App dir whose `hosts.txt` contains only IPs (no DNS names): `unfurl format %d` extracts nothing useful, subenum exits with empty output.
- subfinder's API rate-limited mid-run: subfinder returns partial; dnsx filters; final file may be smaller than ideal but pipeline doesn't abort.

## Future Work

- Stage 2 (subjack) noise reduction: post-process `takeover.txt` to keep only `[Vulnerable]` lines, OR switch subjack invocation flags to suppress non-vulnerable output (not currently in subjack's flag set, but the v3 fork or `subzy` may support it).
- Active subenum (shuffledns + wordlist) gated behind an explicit `--active` flag at orchestrator level.
- Engagement-level rollup: walk all `discovered_subs.txt` files, dedup against the original `subdomains.txt`, run a second nuclei takeover pass on the new ones (tighter than the per-app subjack run).
- Per-engagement Markdown report combining screenshot tiles, takeover findings (Stage 1 + Stage 2), and tech-stack tags.
