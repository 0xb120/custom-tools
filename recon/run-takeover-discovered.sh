#!/bin/bash
# ==============================================================================================
# Script Name: run-takeover-discovered.sh
# Description: Stage 2 subdomain takeover detection — per-app pass.
#              Extracts unique hosts from <app_dir>/all_endpoints_clean.txt and runs
#              `subjack` against them, dropping subjack's text output into
#              <app_dir>/takeover.txt.
#              Re-checks scope hosts that appeared in the crawl (per design decision)
#              so subjack signatures complement Stage 1's nuclei signatures.
#
# Usage:
#   ./run-takeover-discovered.sh <app_dir>
# ==============================================================================================

set -u

show_help() {
    echo "Usage: $0 <app_dir>" >&2
    echo "  <app_dir>   Per-app directory containing all_endpoints_clean.txt (output of pipeline-recon.sh)" >&2
    exit 1
}

if [[ "$#" -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

# Strip any trailing slash so log lines and child paths don't end up with
# double slashes (the orchestrator passes app dirs via `*/` globs which
# preserve the trailing /).
APP_DIR="${1%/}"

if [ ! -d "$APP_DIR" ]; then
    echo "[-] Error: app_dir '$APP_DIR' does not exist." >&2
    exit 1
fi

ENDPOINTS_FILE="$APP_DIR/all_endpoints_clean.txt"
if [ ! -f "$ENDPOINTS_FILE" ]; then
    echo "[INFO] '$ENDPOINTS_FILE' not found. Skipping Stage 2 takeover for $APP_DIR." >&2
    exit 0
fi

if ! command -v subjack >/dev/null 2>&1; then
    echo "[-] Error: subjack not found in PATH (install via org/install-offsec-tools.sh)." >&2
    exit 1
fi

if ! command -v unfurl >/dev/null 2>&1; then
    echo "[-] Error: unfurl not found in PATH." >&2
    exit 1
fi

# Tempdir for the extracted host list; cleaned on exit
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT
HOSTS_FILE="$TMPDIR_WORK/hosts.txt"

{
    unfurl format %d < "$ENDPOINTS_FILE"
    # Also include subenum-discovered subs (from pipeline-subenum.sh) when present.
    [ -f "$APP_DIR/discovered_subs.txt" ] && cat "$APP_DIR/discovered_subs.txt"
} | sort -u > "$HOSTS_FILE"

if [ ! -s "$HOSTS_FILE" ]; then
    echo "[INFO] No unique hosts extractable from $ENDPOINTS_FILE. Skipping." >&2
    exit 0
fi

host_count=$(wc -l < "$HOSTS_FILE")
echo "[INFO] Stage 2 takeover scan starting against $host_count hosts in $APP_DIR..." >&2

subjack \
    -w "$HOSTS_FILE" \
    -t 100 \
    -ssl \
    -timeout 30 \
    -o "$APP_DIR/takeover.txt" \
    || echo "[WARN] subjack exited non-zero for $APP_DIR (non-fatal); output may be partial." >&2

echo "[INFO] Stage 2 takeover: $APP_DIR/takeover.txt written." >&2
