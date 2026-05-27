#!/bin/bash
# ==============================================================================================
# Script Name: pipeline-subenum.sh
# Description: Per-application passive subdomain enumeration.
#              Reads <app_dir>/hosts.txt, extracts unique domains, runs subfinder
#              against them (passive sources only — no brute-force), resolves with
#              dnsx, and writes live discovered subs to <app_dir>/discovered_subs.txt.
#              Sibling to pipeline-recon.sh; both run in parallel across apps when
#              dispatched by recon-orchestrator.sh.
#
# Usage:
#   ./pipeline-subenum.sh <app_dir>
# ==============================================================================================

set -u

show_help() {
    echo "Usage: $0 <app_dir>" >&2
    echo "  <app_dir>   Per-app directory containing hosts.txt (output of surfagr.sh)" >&2
    exit 1
}

if [[ "$#" -ne 1 || "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

APP_DIR="${1%/}"

if [ ! -d "$APP_DIR" ]; then
    echo "[-] Error: app_dir '$APP_DIR' does not exist." >&2
    exit 1
fi

HOSTS_FILE="$APP_DIR/hosts.txt"
if [ ! -f "$HOSTS_FILE" ]; then
    echo "[INFO] No hosts.txt in $APP_DIR; skipping subenum." >&2
    exit 0
fi

if ! command -v subfinder >/dev/null 2>&1; then
    echo "[-] Error: subfinder not found in PATH." >&2
    exit 1
fi

if ! command -v dnsx >/dev/null 2>&1; then
    echo "[-] Error: dnsx not found in PATH." >&2
    exit 1
fi

if ! command -v unfurl >/dev/null 2>&1; then
    echo "[-] Error: unfurl not found in PATH." >&2
    exit 1
fi

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

DOMAINS_FILE="$TMPDIR_WORK/domains.txt"
unfurl format %d < "$HOSTS_FILE" | sort -u > "$DOMAINS_FILE"

if [ ! -s "$DOMAINS_FILE" ]; then
    echo "[INFO] No domains extractable from $HOSTS_FILE; skipping." >&2
    exit 0
fi

domain_count=$(wc -l < "$DOMAINS_FILE")
echo "[INFO] subenum starting against $domain_count host(s) in $APP_DIR..." >&2

# Passive subfinder, then dnsx for live filtering. -silent on both to keep the orchestrator log clean.
subfinder -dL "$DOMAINS_FILE" -silent | dnsx -silent | sort -u > "$APP_DIR/discovered_subs.txt"

new_count=$(wc -l < "$APP_DIR/discovered_subs.txt")
echo "[INFO] subenum: $new_count live subdomains discovered → $APP_DIR/discovered_subs.txt" >&2
