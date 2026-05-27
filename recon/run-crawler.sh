#!/bin/bash
# ==============================================================================================
# Script Name: run-crawler.sh
# Description: Smart Active Crawler (Batch Processing).
#              Analyzes the tech stack of EVERY target in the provided list. It splits the targets
#              into two batches: SPAs (React, Angular, etc.) and Standard sites. It then runs 
#              Katana in standard mode for static sites, and headless mode for SPAs.
#              If an output name is specified, the script will store both jsonl and txt results.
#
# Usage:
#   [File]: ./run-crawler.sh <targets.txt> [output_name]
#   [Pipe]: cat targets.txt | ./run-crawler.sh
# ==============================================================================================

show_help() {
    echo "Usage:" >&2
    echo "  Method 1 (File):  $0 <targets.txt> [output_name]" >&2
    echo "  Method 2 (Pipe):  cat targets.txt | $0 > output_file.txt" >&2
    exit 1
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

SCOPE_FILE=""
FINAL_OUTPUT=""
CLEANUP_INPUT=false

# Input Handling (Pipe vs File)
if [ "$#" -ge 1 ] && [ -f "$1" ]; then
    SCOPE_FILE="$1"
    FINAL_OUTPUT="$2"
elif [ ! -t 0 ]; then
    FINAL_OUTPUT="$1"
    SCOPE_FILE=$(mktemp)
    cat > "$SCOPE_FILE"
    CLEANUP_INPUT=true
    
    if [ ! -s "$SCOPE_FILE" ]; then
        echo "[-] Error: Piped input was empty." >&2
        rm -f "$SCOPE_FILE"
        exit 1
    fi
else
    echo "[-] Error: No valid input provided." >&2
    show_help
fi

# Smart Tech Detect (Per-URL Classification)
echo "[+] [INFO] Analyzing tech stack for all targets to optimize crawler batches..." >&2

HTTPX_OUT=$(mktemp)
SPA_TARGETS=$(mktemp)
STD_TARGETS=$(mktemp)
SCOPE_SORTED=$(mktemp)
CRAWL_OUT=$(mktemp)
timestamp="$(date +%s)"

# Sort the original scope file (required for the comm command later)
sort -u "$SCOPE_FILE" > "$SCOPE_SORTED"

# Run httpx on all targets to get the JSON metadata
httpx -l "$SCOPE_SORTED" -silent -td -j > "$HTTPX_OUT"

# Extract the ORIGINAL inputs that use SPA frameworks. 
# We use .input instead of .url so it perfectly matches the original text file.
jq -r 'select(.tech != null) | select(any(.tech[]; test("react|vue|angular|svelte|next\\.js|nuxt|gatsby"; "i"))) | .input' "$HTTPX_OUT" | sort -u > "$SPA_TARGETS"

# The standard targets are whatever is left in the scope file minus the SPA targets.
# (comm -23 prints lines unique to the first file)
comm -23 "$SCOPE_SORTED" "$SPA_TARGETS" > "$STD_TARGETS"

SPA_COUNT=$(wc -l < "$SPA_TARGETS")
STD_COUNT=$(wc -l < "$STD_TARGETS")

echo "[+] [INFO] Batching complete: $SPA_COUNT SPA targets (Headless) | $STD_COUNT Standard targets (Fast Static)." >&2

# Execution (Running the Batches)

if [ "$STD_COUNT" -gt 0 ]; then
    echo "    -> Running FAST Static Crawl on $STD_COUNT standard targets..." >&2
    katana -silent -s breadth-first -list "$STD_TARGETS" -d 3 -ct 2 -jc -kf all -j >> "$CRAWL_OUT" 

fi

if [ "$SPA_COUNT" -gt 0 ]; then
    echo "    -> Running HEADLESS Crawl on $SPA_COUNT SPA targets..." >&2
    katana -silent -s breadth-first -list "$SPA_TARGETS" -headless -d 3 -ct 2 -jc -kf all -j >> "$CRAWL_OUT"
fi

# Output & Cleanup
if [ -n "$FINAL_OUTPUT" ]; then
    cat "$CRAWL_OUT" | jq '.request.endpoint' | cut -d '"' -f2 > "$FINAL_OUTPUT.txt"
    cat "$CRAWL_OUT" > "$FINAL_OUTPUT.jsonl"
    echo "[+] [INFO] Crawling complete. Saved to $FINAL_OUTPUT.txt and $FINAL_OUTPUT.jsonl" >&2
else
    # Output directly to stdout for piping
    cat "$CRAWL_OUT" | jq '.request.endpoint' | cut -d '"' -f2
fi

# Cleanup all temporary buffer files
rm -f "$HTTPX_OUT" "$SPA_TARGETS" "$STD_TARGETS" "$SCOPE_SORTED" "$CRAWL_OUT"
if [ "$CLEANUP_INPUT" = true ]; then
    rm -f "$SCOPE_FILE"
fi

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
echo "$0 took $time to complete." >&2