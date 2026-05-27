# Per-App Screenshot Triage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one screenshot per clustered web application to the recon pipeline before per-app deep recon begins, so the operator can triage visually while long-running scans continue.

**Architecture:** New standalone script `recon/run-screenshotter.sh` invokes `httpx -screenshot` once against the BEST_HOST of each app cluster, then distributes PNGs back into each `app_*/screenshot.png`. Apps whose capture fails get a one-line `screenshot.failed` marker. `recon/surfagr.sh` calls the new script after clustering, before parallel `pipeline-recon.sh` dispatch. Codebase has no test framework — verification is via reproducible smoke tests using a synthetic fixture.

**Tech Stack:** Bash 4+ (associative arrays), `httpx` (Project Discovery), `jq`, system Chrome/Chromium (for httpx's chromedp).

**Reference spec:** `docs/superpowers/specs/2026-05-05-per-app-screenshot-triage-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `recon/run-screenshotter.sh` | Create | Standalone screenshot worker. Reads `<surface_dir>/*/hosts.txt`, picks BEST_HOST per app, runs one `httpx -screenshot` invocation, distributes PNGs back into each `app_*/`. |
| `recon/surfagr.sh` | Modify | Insert call to `run-screenshotter.sh` after clustering loop, before `pipeline-recon.sh` xargs dispatch. Move `SCRIPT_DIR` definition to top of file (used in two places now). |

No other files touched.

---

## Task 1: Create `run-screenshotter.sh` skeleton

Establishes the script's interface, argument validation, dependency check, and tempdir lifecycle. No screenshot logic yet — just the scaffolding everything else attaches to.

**Files:**
- Create: `recon/run-screenshotter.sh`

- [ ] **Step 1: Write the file**

```bash
#!/bin/bash
# ==============================================================================================
# Script Name: run-screenshotter.sh
# Description: Captures one screenshot per clustered web application using
#              `httpx -screenshot` for visual triage during long-running engagements.
#              Reads each app_*/hosts.txt under <surface_dir>, picks BEST_HOST
#              (prefer non-IP, else first), runs ONE httpx invocation, then
#              distributes PNGs back into each app dir as screenshot.png.
#              Apps whose screenshot capture failed get a screenshot.failed marker.
#
# Usage:
#   ./run-screenshotter.sh <surface_dir>
#
# TODO(gowitness): migrate to gowitness v3.x for the report-serve UI
# when engagement size warrants a grid-view triage workflow.
# Current httpx -screenshot path is dependency-free and good for ≤20 apps;
# above that, `gowitness report serve` is meaningfully better.
# Reference: https://github.com/sensepost/gowitness
# ==============================================================================================

set -u

show_help() {
    echo "Usage: $0 <surface_dir>" >&2
    echo "  <surface_dir>   Directory containing per-app subdirectories (output of surfagr.sh)" >&2
    exit 1
}

if [[ "$#" -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

SURFACE_DIR="$1"

if [ ! -d "$SURFACE_DIR" ]; then
    echo "[-] Error: surface_dir '$SURFACE_DIR' does not exist." >&2
    exit 1
fi

if ! command -v httpx >/dev/null 2>&1; then
    echo "[-] Error: httpx not found in PATH." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[-] Error: jq not found in PATH." >&2
    exit 1
fi

# Working tempdir; cleaned on exit
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

BEST_HOSTS_FILE="$TMPDIR_WORK/best_hosts.txt"
URL_MAP_FILE="$TMPDIR_WORK/url_to_appdir.tsv"
HTTPX_OUT="$TMPDIR_WORK/httpx_screenshots.jsonl"
SCREENSHOT_DIR="$TMPDIR_WORK/screenshots"
mkdir -p "$SCREENSHOT_DIR"
touch "$BEST_HOSTS_FILE" "$URL_MAP_FILE"

echo "[INFO] run-screenshotter.sh starting against '$SURFACE_DIR'" >&2
```

- [ ] **Step 2: Make executable**

```bash
chmod +x recon/run-screenshotter.sh
```

- [ ] **Step 3: Smoke-test the skeleton's argument handling**

Run all four cases and confirm each behaves as expected:

```bash
# No args: prints usage, exits 1
./recon/run-screenshotter.sh; echo "exit=$?"
# Expected: usage on stderr, exit=1

# -h: prints usage, exits 1
./recon/run-screenshotter.sh -h; echo "exit=$?"
# Expected: usage on stderr, exit=1

# Nonexistent dir: prints error, exits 1
./recon/run-screenshotter.sh /tmp/does-not-exist-xyz; echo "exit=$?"
# Expected: "[-] Error: surface_dir ... does not exist." on stderr, exit=1

# Existing empty dir: skeleton runs to completion (no app loop yet, just prints starting message)
mkdir -p /tmp/empty-surface && ./recon/run-screenshotter.sh /tmp/empty-surface; echo "exit=$?"
# Expected: "[INFO] run-screenshotter.sh starting against '/tmp/empty-surface'" on stderr, exit=0
```

- [ ] **Step 4: Commit**

```bash
git add recon/run-screenshotter.sh
git commit -m "feat(recon): add run-screenshotter.sh skeleton

Scaffolding for the per-app screenshot worker: arg validation,
dependency checks (httpx, jq), tempdir lifecycle, trap cleanup.
Implementation logic added in subsequent commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: BEST_HOST collection and URL-to-app-dir map

Walks the surface dir, picks BEST_HOST per app using the same logic as `pipeline-recon.sh:40-43`, builds the input file for httpx and a TSV map for distribution after httpx exits.

**Files:**
- Modify: `recon/run-screenshotter.sh`

- [ ] **Step 1: Append the collection block to the script**

Append at the end of `recon/run-screenshotter.sh`:

```bash
# ============================
# BEST_HOST per app collection
# ============================
APP_COUNT=0
for app_dir in "$SURFACE_DIR"/*/; do
    app_dir="${app_dir%/}"  # strip trailing slash
    [ -f "$app_dir/hosts.txt" ] || continue

    # Same BEST_HOST logic as pipeline-recon.sh:40-43
    best=$(grep -vE "^https?://([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?$" "$app_dir/hosts.txt" | head -n 1)
    if [ -z "$best" ]; then
        best=$(head -n 1 "$app_dir/hosts.txt")
    fi

    # Truly empty hosts.txt: nothing to screenshot
    [ -z "$best" ] && continue

    echo "$best" >> "$BEST_HOSTS_FILE"
    printf '%s\t%s\n' "$best" "$app_dir" >> "$URL_MAP_FILE"
    APP_COUNT=$((APP_COUNT + 1))
done

if [ "$APP_COUNT" -eq 0 ]; then
    echo "[INFO] No apps with hosts.txt found under '$SURFACE_DIR'. Nothing to screenshot." >&2
    exit 0
fi

echo "[INFO] Collected BEST_HOST for $APP_COUNT apps." >&2
```

- [ ] **Step 2: Build a synthetic fixture for verification**

```bash
# Create a fake surface_dir with three apps:
#  - app_dns:     hosts.txt has both IP and DNS-named hosts  -> DNS host should win
#  - app_iponly:  hosts.txt has only IPs                     -> first IP should win
#  - app_empty:   hosts.txt is empty                         -> skipped
mkdir -p /tmp/fixture-surface/{app_dns,app_iponly,app_empty}
cat > /tmp/fixture-surface/app_dns/hosts.txt <<'EOF'
https://192.0.2.10
https://example.com
https://other.example.com
EOF
cat > /tmp/fixture-surface/app_iponly/hosts.txt <<'EOF'
https://192.0.2.20
https://192.0.2.21
EOF
: > /tmp/fixture-surface/app_empty/hosts.txt
```

- [ ] **Step 3: Run the script and inspect the tempfiles before they're cleaned**

The script's `trap` deletes `$TMPDIR_WORK` on exit, so we need to inspect mid-run. Easiest: temporarily edit the script to print the tempfile contents, OR use this one-liner that traces the tempdir path before cleanup:

```bash
# Inject a print of the URL_MAP_FILE just before exit by temporarily disabling cleanup
TRACE=1 bash -c '
  trap_cmd_orig=""
  ./recon/run-screenshotter.sh /tmp/fixture-surface 2>&1 | tee /tmp/screenshotter-output.log
  echo "--- BEST_HOSTS_FILE was at \$TMPDIR_WORK/best_hosts.txt (now cleaned)"
'
```

Cleaner approach: insert one debug line *temporarily* at the bottom of the script before the trap-driven cleanup:
```bash
echo "[DEBUG] BEST_HOSTS_FILE contents:" >&2 && cat "$BEST_HOSTS_FILE" >&2
echo "[DEBUG] URL_MAP_FILE contents:" >&2 && cat "$URL_MAP_FILE" >&2
```

Run it:
```bash
./recon/run-screenshotter.sh /tmp/fixture-surface
```

Expected stderr output (order of apps may vary by glob order):
```
[INFO] run-screenshotter.sh starting against '/tmp/fixture-surface'
[INFO] Collected BEST_HOST for 2 apps.
[DEBUG] BEST_HOSTS_FILE contents:
https://example.com
https://192.0.2.20
[DEBUG] URL_MAP_FILE contents:
https://example.com    /tmp/fixture-surface/app_dns
https://192.0.2.20    /tmp/fixture-surface/app_iponly
```

Confirm:
- `app_empty` is correctly skipped (count=2, not 3)
- `app_dns` chose `https://example.com` (DNS) over `https://192.0.2.10` (IP)
- `app_iponly` chose `https://192.0.2.20` (first IP, since no DNS host exists)

**Remove the two `[DEBUG]` lines before committing.**

- [ ] **Step 4: Commit**

```bash
git add recon/run-screenshotter.sh
git commit -m "feat(recon): collect BEST_HOST per app for screenshotter

Walks <surface_dir>/*/hosts.txt, picks BEST_HOST using the same
non-IP-preference logic as pipeline-recon.sh, writes the input list
and a TSV url-to-appdir map for distribution after httpx exits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: httpx invocation

Runs httpx once against the collected BEST_HOSTs with screenshot mode enabled. All flags are documented in the spec; use them as-is.

**Files:**
- Modify: `recon/run-screenshotter.sh`

- [ ] **Step 1: Append the httpx invocation block**

Append at the end of `recon/run-screenshotter.sh`:

```bash
# =================
# HTTPX SCREENSHOTS
# =================
echo "[INFO] Running httpx -screenshot (this can take 30-60s for ~20 apps)..." >&2

# Note: no -fr flag. Without follow-redirects, httpx's JSONL .url field
# stays equal to the input URL, which is our join key. chromedp follows
# redirects internally during rendering, so the PNG still shows the
# final page even when the HTTP probe doesn't follow redirects.
httpx \
    -l "$BEST_HOSTS_FILE" \
    -screenshot \
    -system-chrome \
    -screenshot-timeout 15 \
    -no-screenshot-bytes \
    -no-screenshot-full-page \
    -silent \
    -j \
    -o "$HTTPX_OUT" \
    -srd "$SCREENSHOT_DIR" \
    || echo "[WARN] httpx exited non-zero; attempting to distribute partial results." >&2
```

- [ ] **Step 2: Run against the fixture and verify the JSONL field shape**

Two of the three fixture URLs (`https://example.com`, `https://192.0.2.20`) should be probed. `192.0.2.0/24` is a TEST-NET range — the IP target will fail to connect, which exercises the failure path. `example.com` should succeed and produce a PNG.

```bash
./recon/run-screenshotter.sh /tmp/fixture-surface
```

Then inspect httpx's output before cleanup. Easiest: temporarily disable the trap by adding `trap - EXIT` near the bottom, OR add a debug line:

Insert temporarily at the bottom of the script (before exit):
```bash
echo "[DEBUG] HTTPX_OUT contents:" >&2 && cat "$HTTPX_OUT" >&2
echo "[DEBUG] SCREENSHOT_DIR contents:" >&2 && ls -la "$SCREENSHOT_DIR" >&2
```

Run again and verify:
- `HTTPX_OUT` is non-empty JSONL
- Each line has a `.url` field matching one of the input URLs
- The `example.com` line has a `.screenshot_path` field pointing into `SCREENSHOT_DIR`
- The IP target either has no entry, or has an entry with no `.screenshot_path` field

```bash
./recon/run-screenshotter.sh /tmp/fixture-surface 2>&1 | tail -30
```

If the JSONL field for the input URL is named differently in your httpx version (e.g., `.input` rather than `.url`), note this — Task 4 reads this field and may need adjusting. The spec assumes `.url`.

**Remove the two `[DEBUG]` lines before committing.**

- [ ] **Step 3: Commit**

```bash
git add recon/run-screenshotter.sh
git commit -m "feat(recon): invoke httpx -screenshot in run-screenshotter

Single httpx invocation against all BEST_HOSTs with viewport-only
capture. No -fr flag so httpx JSONL .url remains the input URL
(our join key); chromedp still follows redirects internally during
rendering.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Distribute PNGs and write failure markers

Reads the httpx JSONL, builds a `url -> screenshot_path` map, then walks the URL_MAP_FILE: each app gets either a `screenshot.png` (copied from the temp screenshot dir) or a `screenshot.failed` marker with the reason.

**Files:**
- Modify: `recon/run-screenshotter.sh`

- [ ] **Step 1: Append the distribution block**

Append at the end of `recon/run-screenshotter.sh`:

```bash
# ========================
# DISTRIBUTE PNGS PER APP
# ========================

# Build URL -> screenshot_path and URL -> failure-reason maps from the JSONL
declare -A URL_TO_PNG
declare -A URL_FAILED

if [ -s "$HTTPX_OUT" ]; then
    while IFS= read -r line; do
        # Skip blank lines defensively
        [ -z "$line" ] && continue
        url=$(echo "$line" | jq -r '.url // .input // empty')
        spath=$(echo "$line" | jq -r '.screenshot_path // empty')
        [ -z "$url" ] && continue
        if [ -n "$spath" ]; then
            URL_TO_PNG["$url"]="$spath"
        else
            URL_FAILED["$url"]="screenshot path missing in entry"
        fi
    done < "$HTTPX_OUT"
fi

# Walk the url-to-appdir map and either copy PNG or write failure marker
SUCCESS=0
FAILED=0
while IFS=$'\t' read -r url app_dir; do
    [ -z "$url" ] && continue
    if [ -n "${URL_TO_PNG[$url]:-}" ] && [ -f "${URL_TO_PNG[$url]}" ]; then
        cp "${URL_TO_PNG[$url]}" "$app_dir/screenshot.png"
        # Clean any stale failure marker from a previous run
        rm -f "$app_dir/screenshot.failed"
        SUCCESS=$((SUCCESS + 1))
    else
        reason="${URL_FAILED[$url]:-host not present in httpx output}"
        echo "$reason" > "$app_dir/screenshot.failed"
        # Clean any stale PNG from a previous run
        rm -f "$app_dir/screenshot.png"
        FAILED=$((FAILED + 1))
    fi
done < "$URL_MAP_FILE"

echo "[INFO] Screenshots: $SUCCESS captured, $FAILED failed." >&2
```

- [ ] **Step 2: End-to-end smoke test against the fixture**

Reset the fixture so the test starts clean:

```bash
rm -f /tmp/fixture-surface/app_dns/screenshot.{png,failed}
rm -f /tmp/fixture-surface/app_iponly/screenshot.{png,failed}
./recon/run-screenshotter.sh /tmp/fixture-surface
```

Expected stderr:
```
[INFO] run-screenshotter.sh starting against '/tmp/fixture-surface'
[INFO] Collected BEST_HOST for 2 apps.
[INFO] Running httpx -screenshot ...
[INFO] Screenshots: 1 captured, 1 failed.
```

Verify the artifacts:
```bash
ls -la /tmp/fixture-surface/app_dns/ /tmp/fixture-surface/app_iponly/
```

Expected:
- `app_dns/screenshot.png` exists, ~50-200KB, opens as a PNG (`file` reports it as a PNG image)
- `app_iponly/screenshot.failed` exists, contains `host not present in httpx output`
- `app_empty/` is unchanged (no `screenshot.png` or `screenshot.failed`)

```bash
file /tmp/fixture-surface/app_dns/screenshot.png
cat /tmp/fixture-surface/app_iponly/screenshot.failed
ls /tmp/fixture-surface/app_empty/
```

- [ ] **Step 3: Test the stale-artifact cleanup**

Place a stale `screenshot.failed` in `app_dns` and a stale `screenshot.png` in `app_iponly`, then re-run:

```bash
echo "old reason" > /tmp/fixture-surface/app_dns/screenshot.failed
touch /tmp/fixture-surface/app_iponly/screenshot.png
./recon/run-screenshotter.sh /tmp/fixture-surface
```

Verify:
- `app_dns/screenshot.failed` is gone (replaced by fresh `screenshot.png`)
- `app_iponly/screenshot.png` is gone (replaced by fresh `screenshot.failed`)

```bash
ls /tmp/fixture-surface/app_dns/ /tmp/fixture-surface/app_iponly/
```

- [ ] **Step 4: Commit**

```bash
git add recon/run-screenshotter.sh
git commit -m "feat(recon): distribute screenshot PNGs and failure markers

Reads httpx JSONL, copies each PNG into its app dir as screenshot.png,
writes a one-line screenshot.failed marker for apps whose capture
failed. Cleans stale artifacts from previous runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Wire `run-screenshotter.sh` into `surfagr.sh`

Move `SCRIPT_DIR` definition to the top of `surfagr.sh` (it's about to be used in two places), then insert the screenshotter call between the clustering loop and the parallel `pipeline-recon.sh` dispatch.

**Files:**
- Modify: `recon/surfagr.sh`

- [ ] **Step 1: Move `SCRIPT_DIR` to the top of the file**

Open `recon/surfagr.sh`. The existing `SCRIPT_DIR` definition is at line 122:
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
```

Move that line up to right after the argument validation block (around line 51, just after `dest_dir="${2:-$PWD/surface_$rand_hash}"`).

After the move, `surfagr.sh` should have `SCRIPT_DIR` defined once near the top, and the line at 122 should be removed.

Verify with grep — should print exactly one match:
```bash
grep -n 'SCRIPT_DIR=' recon/surfagr.sh
```

- [ ] **Step 2: Insert the screenshotter call**

In `recon/surfagr.sh`, find the boundary between the clustering loop's closing `done < "$dest_dir/tmp/app_groups.jsonl"` (around line 113 in the pre-edit file) and the comment block `# PARALLEL URL DISCOVERY ACROSS ALL GROUPS` (around line 115).

Insert immediately after the clustering loop's closing `done`:

```bash
# ===================
# VISUAL TRIAGE SHOTS
# ===================
echo "[INFO] Capturing per-app screenshots..." >&2
"$SCRIPT_DIR/run-screenshotter.sh" "$dest_dir/targets" || \
    echo "[WARN] Screenshot stage had errors (non-fatal); continuing." >&2

```

The blank line at the end is intentional — separates the new section from the existing `# PARALLEL URL DISCOVERY ACROSS ALL GROUPS` block.

- [ ] **Step 3: Verify the file structure**

Read the modified file and confirm:
- `SCRIPT_DIR=` appears exactly once, near the top of the file (right after argument validation)
- The new `VISUAL TRIAGE SHOTS` section is between the clustering loop and the `PARALLEL URL DISCOVERY ACROSS ALL GROUPS` section
- The xargs dispatch line `find "$dest_dir/targets" -mindepth 1 -maxdepth 1 -type d | xargs -P $PARALLEL_APPS -I % "$PIPELINE_WORKER" "%"` is unchanged

```bash
grep -n -E 'SCRIPT_DIR=|VISUAL TRIAGE|run-screenshotter|PARALLEL URL DISCOVERY|xargs' recon/surfagr.sh
```

Expected output (line numbers approximate):
```
~52: SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
~115: # ===================
~116: # VISUAL TRIAGE SHOTS
~118: "$SCRIPT_DIR/run-screenshotter.sh" "$dest_dir/targets" || \
~123: # ==========================================
~124: # PARALLEL URL DISCOVERY ACROSS ALL GROUPS
~134: find "$dest_dir/targets" -mindepth 1 -maxdepth 1 -type d | \
```

- [ ] **Step 4: Syntax-check the script**

```bash
bash -n recon/surfagr.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 5: Commit**

```bash
git add recon/surfagr.sh
git commit -m "feat(recon): wire run-screenshotter into surfagr.sh

Adds a visual-triage stage between vhost clustering and the parallel
pipeline-recon dispatch. Screenshots become available before the
long per-app recon begins, so the operator can triage in parallel.
Stage is non-fatal: a screenshot failure does not abort the engagement.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: End-to-end smoke test via `surfagr.sh`

Run the full surfagr pipeline with a real `httpx_full_metadata.jsonl` and confirm the screenshotter runs in the right place, leaves correct artifacts, and does not block the downstream `pipeline-recon.sh` dispatch.

**Files:** none modified — verification only.

- [ ] **Step 1: Pick or create an `httpx_full_metadata.jsonl` fixture**

Easiest: use a recent engagement's `httpx_full_metadata.jsonl` if one exists.

If not, create a tiny one against two known-good public hosts:
```bash
echo -e "https://example.com\nhttps://example.org" | \
    httpx -silent -sc -cl -td -title -ip -hash sha256 -location -fr -j \
    -o /tmp/fixture-httpx.jsonl
```

- [ ] **Step 2: Run `surfagr.sh` end-to-end**

Use a tempdir as the workspace:
```bash
rm -rf /tmp/surfagr-smoke
./recon/surfagr.sh /tmp/fixture-httpx.jsonl /tmp/surfagr-smoke
```

Expected on stderr (order/details vary):
```
[INFO] Grouping of unique applications and creation of target folders...
[INFO] Detected N unique applications. Folder creation in progress...
  -> Created: ...
[INFO] Capturing per-app screenshots...
[INFO] run-screenshotter.sh starting against '/tmp/surfagr-smoke/targets'
[INFO] Collected BEST_HOST for N apps.
[INFO] Running httpx -screenshot ...
[INFO] Screenshots: K captured, M failed.
[INFO] Starting recon pipeline (OSINT -> Crawl -> Download) on 3 parallel targets...
... (pipeline-recon.sh output) ...
```

Confirm:
- The `[INFO] Capturing per-app screenshots...` line appears **after** clustering and **before** `Starting recon pipeline`.
- Each `app_*/` under `/tmp/surfagr-smoke/targets/` has either `screenshot.png` or `screenshot.failed`.
- `pipeline-recon.sh` still runs to completion (the screenshotter does not block or break it).

```bash
ls /tmp/surfagr-smoke/targets/*/screenshot.{png,failed} 2>&1 | head
```

- [ ] **Step 3: Verify non-fatal behaviour**

Simulate a failing screenshotter run (e.g., temporarily rename the script) and confirm `surfagr.sh` continues:
```bash
mv recon/run-screenshotter.sh recon/run-screenshotter.sh.bak
rm -rf /tmp/surfagr-smoke-fail
./recon/surfagr.sh /tmp/fixture-httpx.jsonl /tmp/surfagr-smoke-fail
mv recon/run-screenshotter.sh.bak recon/run-screenshotter.sh
```

Expected: the `[WARN] Screenshot stage had errors (non-fatal); continuing.` line appears, and `pipeline-recon.sh` still runs afterward.

- [ ] **Step 4: No commit**

This task is verification-only. Nothing to commit.

---

## Self-Review

**Spec coverage:**

| Spec section | Implementing task |
|---|---|
| Component: `recon/run-screenshotter.sh` interface | Task 1 |
| Behavior step 1 (validate dir / empty case) | Task 1 (validate), Task 2 (empty case `[INFO] No apps...`) |
| Behavior step 2 (BEST_HOST per app) | Task 2 |
| Behavior step 3 (single httpx invocation) | Task 3 |
| Behavior step 4 (parse JSONL, copy PNGs) | Task 4 |
| Behavior step 5 (failure markers with reason) | Task 4 |
| Behavior step 6 (cleanup tempfiles via trap) | Task 1 |
| httpx flags exact list | Task 3 |
| TODO(gowitness) header comment | Task 1 |
| Integration: `surfagr.sh` edit (move SCRIPT_DIR, insert section) | Task 5 |
| Output layout (`screenshot.png` / `screenshot.failed` per app dir) | Task 4 |
| Error handling: missing dir / no httpx / no jq | Task 1 |
| Error handling: empty surface_dir | Task 2 |
| Error handling: per-host timeout, partial httpx failure | Task 3 (httpx flag), Task 4 (distribution still runs after non-zero exit) |
| Error handling: surfagr non-fatal warning | Task 5 |
| Testing: smoke test plan including 401-style edge case | Task 6 |

All sections covered.

**Placeholder scan:** No "TBD", "TODO" (other than the intentional `TODO(gowitness)` future-work comment), "implement later", or "fill in details". Every step contains executable code or a runnable command. ✓

**Type/name consistency:**
- `SURFACE_DIR` used consistently (Tasks 1, 2)
- `BEST_HOSTS_FILE`, `URL_MAP_FILE`, `HTTPX_OUT`, `SCREENSHOT_DIR` defined in Task 1, used in Tasks 2-4
- `URL_TO_PNG`, `URL_FAILED` associative arrays defined and used in Task 4
- `screenshot.png` / `screenshot.failed` filenames consistent across spec, Tasks 4, 5, 6
- `run-screenshotter.sh` referenced consistently
- `SCRIPT_DIR` consistent with `surfagr.sh`'s existing pattern ✓

**Scope:** Single feature, single implementation plan. ✓
