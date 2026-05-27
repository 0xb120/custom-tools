# Subdomain Takeover Detection — Design (Branch 1)

**Date:** 2026-05-06
**Status:** Approved, ready for implementation plan
**Scope:** Add subdomain-takeover detection in two stages, against the original scope (early) and against per-app crawled/OSINT-discovered hosts (late). Branch 1 implements takeover only — per-app subenum + orchestrator/surfagr restructure follow as Branch 2.

---

## Background

Subdomain takeover is a high-signal vulnerability class (often P1 in bug bounty): a DNS record (typically a CNAME) points to a service that no longer claims the name, so an attacker can register the missing claim and serve content from a name the target's brand still owns. Detection is signature-based: query the host, match the response against known fingerprints (GitHub Pages "There isn't a GitHub Pages site here", S3 "NoSuchBucket", Heroku "no-such-app", etc.).

The current pipeline produces all the data needed for both targeted detection passes — the scope-side resolved subdomain list (`scope2surface.sh:127` → `scans/subdomains.txt`) and the per-app discovered URL set (`pipeline-recon.sh` → `app_*/all_endpoints_clean.txt`) — but never feeds them to a takeover detector.

This change wires up two takeover passes: an early engagement-level pass over the resolved scope, and a per-app pass over discovered hosts.

## Goals

- Operator gets a P1-tier finding within minutes of starting an engagement, not at the end.
- Coverage of both the original scope (Stage 1) and crawl-discovered hosts (Stage 2).
- Stage 1 runs in parallel with the rest of the pipeline so it adds no wall-time.
- Two separate tools (nuclei / subjack) so signature coverage doesn't bottleneck on one project's update cadence.
- Implementation isolated to two new scripts + small orchestrator edit. No changes to `surfagr.sh` or `pipeline-recon.sh` — those land in Branch 2.

## Non-Goals

- Per-app subenum (Branch 2).
- Orchestrator/surfagr dispatch restructure (Branch 2).
- HTML/Markdown report rollup. JSONL/text output is enough for now.
- Authenticated takeover variants (CDN-fronted, geo-restricted).

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Stage 1 input | `<dest>/scans/subdomains.txt` (resolved subs from shuffledns) | Canonical post-enumeration list `scope2surface.sh` already produces. |
| Stage 1 tool | `nuclei -tags takeover` | Already in PATH (Project Discovery suite); ~80 maintained signatures; JSONL output. |
| Stage 1 placement | Background in `recon-orchestrator.sh`, immediately after `scope2surface.sh`. | No data dependency on clustering / per-app recon; running it concurrently with the rest of the pipeline is essentially free. |
| Stage 1 output | `<scan_base>/takeovers_scope.jsonl` | Engagement-level, single file. Easy to grep at the end. |
| Stage 2 input | Unique hosts extracted from `<app_dir>/all_endpoints_clean.txt`, no scope-subtraction (re-checks in case the second tool catches what the first missed). | User explicitly chose re-check; aligns with using two different signature engines. |
| Stage 2 tool | `subjack` | User-requested complement to nuclei; different fingerprint set; fast over a per-app URL list. New dependency added to `install-offsec-tools.sh`. |
| Stage 2 placement | New per-app for-loop in `recon-orchestrator.sh`, runs **after** the existing per-app `pipeline-recon.sh` loop completes. | `pipeline-recon.sh` stays untouched; no Phase-4 patching; no double-runs from the orchestrator's pre-existing duplication. |
| Stage 2 output | `<app_dir>/takeover.txt` (subjack default text output) | Per-app sprinkling — operator triages per-app, not by scanning a global file. |
| Failure mode | Both stages non-fatal at the engagement level; Stage 1 failure logs `[WARN]`, Stage 2 failure leaves no marker (subjack's exit code is unreliable). | Engagement should never abort because a takeover scan errored. |

## Components

### `recon/run-takeover-scope.sh` (new)

**Interface:**
```
run-takeover-scope.sh <subs_file> <output_jsonl>
```

**Behaviour:**
1. Validate `<subs_file>` exists and is non-empty; if empty, log info and exit 0 (nothing to scan).
2. Verify `nuclei` is in PATH; exit 1 with a clear error otherwise.
3. Run a single nuclei invocation:
   ```
   nuclei -l <subs_file> -tags takeover -j -o <output_jsonl> -silent -duc
   ```
   - `-tags takeover` selects all takeover templates (~80).
   - `-j` JSONL output.
   - `-silent` suppresses banner/progress.
   - `-duc` "disable update check" — keeps the scan deterministic and offline-friendly.
4. After nuclei exits, print a one-line summary: `[INFO] Stage 1 takeover: N findings → <output_jsonl>` (line count of output).
5. Always exit 0 unless the dependency or input file checks failed. nuclei finding nothing is success, not failure.

### `recon/run-takeover-discovered.sh` (new)

**Interface:**
```
run-takeover-discovered.sh <app_dir>
```

**Behaviour:**
1. Validate `<app_dir>` exists and contains `all_endpoints_clean.txt`; if not, log info and exit 0.
2. Verify `subjack` and `unfurl` are in PATH; exit 1 with a clear error otherwise.
3. Extract unique hosts from `all_endpoints_clean.txt` to a tempfile:
   ```
   unfurl format %d < all_endpoints_clean.txt | sort -u > <tmp>/hosts.txt
   ```
4. If the resulting host list is empty, log info and exit 0.
5. Run subjack:
   ```
   subjack -w <tmp>/hosts.txt -t 100 -ssl -timeout 30 -o <app_dir>/takeover.txt
   ```
   - `-w` input wordlist.
   - `-t 100` thread count (subjack is light HTTP probing; high concurrency is fine).
   - `-ssl` test https as well as http.
   - `-timeout 30` per-request timeout.
6. Trap-cleanup the tempfile on exit.
7. Always exit 0 unless dependency/input checks failed.

### `recon/recon-orchestrator.sh` (modified)

Three changes:

**Change 1 — fix the pre-existing path mismatch.** Currently line 12 writes to `$BASE/att_surface` but line 15 reads from `$BASE/surface/...`. Update line 15 to `att_surface`.

**Change 2 — kick off Stage 1 in background after scope2surface, before surfagr.** Capture its PID for the final wait.

**Change 3 — add Stage 2 per-app loop after the existing pipeline-recon for-loop, with a final wait for both Stage 1 and the Stage 2 per-app jobs.**

Resulting orchestrator (annotated):

```bash
#!/usr/bin/env bash
set -euo pipefail

SCAN_ID="$1"
SCOPE="$2"
BASE="/scans/${SCAN_ID}"
mkdir -p "$BASE"
cp "$SCOPE" "$BASE/scope.txt"

# 1. Attack surface
./recon/scope2surface.sh "$BASE/scope.txt" "$BASE/att_surface"

# 1b. Stage 1 takeover (background, parallel with everything below)
./recon/run-takeover-scope.sh \
    "$BASE/att_surface/scans/subdomains.txt" \
    "$BASE/takeovers_scope.jsonl" &
TAKEOVER_SCOPE_PID=$!

# 2. Cluster vhosts per app  
./recon/surfagr.sh "$BASE/att_surface/scans/httpx_full_metadata.jsonl" "$BASE/apps"

# 3. Per-app recon
for app_dir in "$BASE/apps"/app_*; do
    ./recon/pipeline-recon.sh "$app_dir"
done

# 4. Stage 2 takeover per-app (after pipeline-recon has produced all_endpoints_clean.txt)
for app_dir in "$BASE/apps"/app_*; do
    ./recon/run-takeover-discovered.sh "$app_dir" &
done
wait

# 5. Wait for Stage 1 takeover (likely already finished)
wait "$TAKEOVER_SCOPE_PID"
```

Note: the orchestrator's existing per-app for-loop is unchanged. The pre-existing duplication with `surfagr.sh`'s xargs dispatch persists in this branch and will be cleaned up in Branch 2.

### `org/install-offsec-tools.sh` (modified)

Add a new function `install_takeover` reserving a section for takeover-specific tools, currently containing only `subjack`:

```bash
install_takeover() {
    echo "[+] Installing Subdomain Takeover Tools..."
    go install -v github.com/haccer/subjack@latest
}
```

And add `install_takeover` to whichever installer-orchestrator block invokes the other groups (`install_projectdiscovery`, `install_tomnomnom`, etc.). This keeps takeover tooling in its own module so future additions (`subzy`, `tko-subs`) land in one place.

## Output Layout

```
<scan_base>/
├── scope.txt
├── att_surface/
│   └── scans/
│       ├── subdomains.txt              (input to Stage 1)
│       └── httpx_full_metadata.jsonl   (input to surfagr)
├── takeovers_scope.jsonl               NEW — Stage 1 (nuclei)
└── apps/
    └── app_*/
        ├── hosts.txt
        ├── screenshot.png
        ├── all_endpoints_clean.txt     (input to Stage 2)
        └── takeover.txt                NEW — Stage 2 (subjack)
```

## Error Handling

| Case | Behaviour |
|---|---|
| `subs_file` (Stage 1) missing or empty | `[INFO]` and exit 0. No findings file written. |
| `nuclei` not in PATH | Exit 1 with clear error. |
| `subjack` or `unfurl` not in PATH | Exit 1 with clear error from `run-takeover-discovered.sh`. |
| Stage 1 nuclei exits non-zero | Worker exits 0; orchestrator's final `wait` does not abort. The empty/partial JSONL is left on disk. |
| Stage 2 subjack exits non-zero per-app | Worker exits 0; orchestrator's `wait` does not abort. Other apps' Stage 2 jobs continue. |
| `<app_dir>/all_endpoints_clean.txt` missing | `[INFO]` and exit 0. |

## Performance Notes

- Stage 1 runs in parallel with the entire foreground pipeline; net wall-time cost is approximately zero (the foreground takes longer than nuclei's takeover pass on a typical scope of ~100-500 subs).
- Stage 2 dispatches subjack per-app via `&` + `wait`. Up to N concurrent subjack workers (one per app). Each is light HTTP probing. For very large engagements (>50 apps) this could starve the network — acceptable for current scale.
- subjack `-t 100` parallelises within a single invocation; combined with N-concurrent invocations the practical concurrency is moderate but not extreme (subjack rate-limits per host internally).

## Testing

Manual smoke test, no automated tests (consistent with the rest of the codebase).

Steps:
1. Recreate or reuse a small `<scan_base>` from a recent engagement, OR build a synthetic fixture: a `subdomains.txt` containing one known-good and one obviously-NXDOMAIN host, plus an `apps/app_test/` with an `all_endpoints_clean.txt` containing a couple of real URLs.
2. Run `recon/run-takeover-scope.sh subdomains.txt /tmp/takeovers.jsonl`. Verify:
   - Empty JSONL when nothing matches (most engagements).
   - JSONL is parseable (`jq -s . < /tmp/takeovers.jsonl`).
   - Exit code 0.
3. Run `recon/run-takeover-discovered.sh apps/app_test/`. Verify:
   - `apps/app_test/takeover.txt` exists.
   - File is plain text (subjack's default format).
4. Run `recon/recon-orchestrator.sh <scan_id> <scope_file>` end-to-end. Verify ordering in the log:
   - Stage 1 starts after scope2surface.
   - Stage 2 starts after the per-app for-loop completes.
   - Final `wait` returns cleanly.
5. Verify the path-mismatch fix: orchestrator runs to completion without the previous `surface/httpx_full_metadata.jsonl: No such file or directory` error.

Edge cases to exercise:
- `subdomains.txt` empty → Stage 1 exits 0 cleanly.
- One app dir has no `all_endpoints_clean.txt` (e.g., crawler failed) → Stage 2 worker for that app exits 0; others continue.
- Network outage during nuclei → worker exits 0 (with an empty/partial JSONL), engagement continues.

## Future Work (Branch 2)

- New script `recon/pipeline-subenum.sh`: per-app subdomain enumeration via `subfinder` (passive only, per user choice).
- Restructure `surfagr.sh` to stop dispatching `pipeline-recon.sh`; centralise the per-app dispatch in `recon-orchestrator.sh`, running both `pipeline-recon.sh` and `pipeline-subenum.sh` concurrently across apps via `xargs -P 3`.
- Stage 2 takeover input expanded to include `discovered_subs.txt` (output of subenum pipeline) alongside `all_endpoints_clean.txt`.
- Final report rollup (Markdown summary across all engagement findings).
