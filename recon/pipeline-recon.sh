#!/bin/bash
# ==============================================================================================
# Script Name: pipeline-recon.sh
# Description: Full Recon Pipeline Worker for a Single Target Application.
#              Executes Passive OSINT -> Active Crawl (Smart Host) -> Mass Download sequentially.
#
# Usage:
#   ./pipeline-recon.sh [target_workspace]
# ==============================================================================================

if [ "$#" -lt 1 ] || [ ! -d "$1" ]; then
    echo "[-] Error: Invalid application directory passed to pipeline." >&2
    exit 1
fi

APP_DIR="${1%/}"
APP_NAME=$(basename "$APP_DIR")
HOSTS_FILE="$APP_DIR/hosts.txt"
timestamp="$(date +%s)"

# Get the full path to the scripts folder to load the modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

echo "---------------------------------------------------" >&2
echo " [▶] STARTING PIPELINE FOR: $APP_NAME" >&2
echo "---------------------------------------------------" >&2

# -------------------------------------------------------------------------
# FASE 1: PASSIVE OSINT (Subdomain Enumeration, URL Extraction)
# -------------------------------------------------------------------------
echo "  [1/3] Running Passive OSINT..." >&2
cat "$HOSTS_FILE" | "$SCRIPT_DIR/run-passive-probe.sh" > "$APP_DIR/osint_urls.txt"

# -------------------------------------------------------------------------
# FASE 2: ACTIVE CRAWLING (Smart Host Selection)
# -------------------------------------------------------------------------
echo "  [2/3] Running Active Crawler..." >&2

# Smart target selection (Domain > IP)
BEST_HOST=$(grep -vE "^https?://([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?$" "$HOSTS_FILE" | head -n 1)
if [ -z "$BEST_HOST" ]; then
    BEST_HOST=$(head -n 1 "$HOSTS_FILE")
fi

echo "        -> Target selected for crawling: $BEST_HOST" >&2
echo "$BEST_HOST" | "$SCRIPT_DIR/run-crawler.sh" "$APP_DIR/crawled_urls"

# -------------------------------------------------------------------------
# FASE 3: Merging Results and Mass-Downloading
# -------------------------------------------------------------------------
echo "  [3/3] Merging results and mass-downloading with httpx..." >&2

# We merge and deduplicate OSINT and crawl data
cat "$APP_DIR/osint_urls.txt" "$APP_DIR/crawled_urls.txt" 2>/dev/null | sort -u > "$APP_DIR/all_endpoints_raw.txt"

NOISE_REGEX='\.(jpg|jpeg|png|gif|svg|bmp|webp|ico|woff|woff2|ttf|eot|otf|css|mp3|mp4|wav|avi|mov|webm)($|\?)'
grep -viE "$NOISE_REGEX" "$APP_DIR/all_endpoints_raw.txt" > "$APP_DIR/all_endpoints_clean.txt"

CLEAN_COUNT=$(wc -l < "$APP_DIR/all_endpoints_clean.txt")
RAW_COUNT=$(wc -l < "$APP_DIR/all_endpoints_raw.txt")
echo "        -> Filtered out $(expr $RAW_COUNT - $CLEAN_COUNT) noisy static assets." >&2

# Let’s feed the cleaned-up list to the downloader
cat "$APP_DIR/all_endpoints_clean.txt" | "$SCRIPT_DIR/run-downloader.sh" "$APP_DIR"

echo " [✔] PIPELINE COMPLETE FOR: $APP_NAME" >&2
echo "---------------------------------------------------" >&2

# Time diff
end_time="$(date +%s)"
seconds="$(expr $end_time - $timestamp)"
time=""

if [[ "$seconds" -gt 59 ]]
then
    minutes=$(expr $seconds / 60)
    time="$minutes minutes"
else
    time="$seconds seconds"
fi

echo " [✔] PIPELINE COMPLETD in $time FOR $APP_NAME" >&2
echo "---------------------------------------------------" >&2