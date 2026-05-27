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

if ! command -v google-chrome >/dev/null 2>&1 && \
   ! command -v chromium >/dev/null 2>&1 && \
   ! command -v chromium-browser >/dev/null 2>&1; then
    echo "[-] Error: no system Chrome/Chromium found in PATH (required for httpx -system-chrome)." >&2
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

# =================
# HTTPX SCREENSHOTS
# =================
echo "[INFO] Running httpx -screenshot (this can take 30-60s for ~20 apps)..." >&2

# Note: no -fr flag. Without follow-redirects, httpx's JSONL .url field
# stays equal to the input URL, which is our join key. chromedp follows
# redirects internally during rendering, so the PNG still shows the
# final page even when the HTTP probe doesn't follow redirects.
cd "$TMPDIR_WORK" || exit 1
httpx \
    -l "$BEST_HOSTS_FILE" \
    -screenshot \
    -system-chrome \
    -screenshot-timeout 15 \
    -exclude-screenshot-bytes \
    -no-screenshot-full-page \
    -silent \
    -j \
    -o "$HTTPX_OUT" \
    || echo "[WARN] httpx exited non-zero; attempting to distribute partial results." >&2

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
    if [ -n "${URL_TO_PNG[$url]:-}" ]; then
        if [ -f "${URL_TO_PNG[$url]}" ]; then
            cp "${URL_TO_PNG[$url]}" "$app_dir/screenshot.png"
            # Clean any stale failure marker from a previous run
            rm -f "$app_dir/screenshot.failed"
            SUCCESS=$((SUCCESS + 1))
        else
            echo "screenshot file missing from disk: ${URL_TO_PNG[$url]}" > "$app_dir/screenshot.failed"
            rm -f "$app_dir/screenshot.png"
            FAILED=$((FAILED + 1))
        fi
    else
        reason="${URL_FAILED[$url]:-host not present in httpx output}"
        echo "$reason" > "$app_dir/screenshot.failed"
        # Clean any stale PNG from a previous run
        rm -f "$app_dir/screenshot.png"
        FAILED=$((FAILED + 1))
    fi
done < "$URL_MAP_FILE"

echo "[INFO] Screenshots: $SUCCESS captured, $FAILED failed." >&2
