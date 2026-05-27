#!/bin/bash
# ==============================================================================================
# Script Name: run-takeover-scope.sh
# Description: Stage 1 subdomain takeover detection — engagement-level pass.
#              Runs `nuclei -tags takeover` against the resolved subdomain list
#              from scope2surface.sh and writes JSONL findings to <output_jsonl>.
#              Empty output is success (no takeovers found); finding-related errors
#              do not abort the engagement.
#
# Usage:
#   ./run-takeover-scope.sh <subs_file> <output_jsonl>
# ==============================================================================================

set -u

show_help() {
    echo "Usage: $0 <subs_file> <output_jsonl>" >&2
    echo "  <subs_file>      Path to the resolved subdomain list (e.g. att_surface/scans/subdomains.txt)" >&2
    echo "  <output_jsonl>   Path where nuclei JSONL findings are written" >&2
    exit 1
}

if [[ "$#" -ne 2 || "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

SUBS_FILE="$1"
OUTPUT_JSONL="$2"

if [ ! -f "$SUBS_FILE" ]; then
    echo "[-] Error: subs_file '$SUBS_FILE' does not exist." >&2
    exit 1
fi

if [ ! -s "$SUBS_FILE" ]; then
    echo "[INFO] subs_file '$SUBS_FILE' is empty. Nothing to scan." >&2
    : > "$OUTPUT_JSONL"
    exit 0
fi

if ! command -v nuclei >/dev/null 2>&1; then
    echo "[-] Error: nuclei not found in PATH." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_JSONL")"

echo "[INFO] Stage 1 takeover scan starting against $(wc -l < "$SUBS_FILE") subs..." >&2

nuclei \
    -l "$SUBS_FILE" \
    -tags takeover \
    -j \
    -o "$OUTPUT_JSONL" \
    -silent \
    -duc \
    || echo "[WARN] nuclei exited non-zero; output JSONL may be partial." >&2

# Findings count — non-fatal info line
if [ -s "$OUTPUT_JSONL" ]; then
    findings=$(wc -l < "$OUTPUT_JSONL")
else
    findings=0
fi
echo "[INFO] Stage 1 takeover: $findings findings → $OUTPUT_JSONL" >&2
