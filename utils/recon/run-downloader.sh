#!/bin/bash
# ==============================================================================================
# Script Name: run-downloader.sh
# Description: Mass-Prober and Downloader.
#              Takes a list of URLs, intelligently separates JavaScript files from standard 
#              endpoints (HTML/JSON/API), probes them with httpx, and physically downloads 
#              the responses into separate structured directories.
#
# Usage:
#   [File]: ./run-downloader.sh <urls.txt> <output_directory>
#   [Pipe]: cat urls.txt | ./run-downloader.sh <output_directory>
# ==============================================================================================

show_help() {
    echo "Usage:" >&2
    echo "  Method 1 (File):  $0 <urls.txt> <output_directory>" >&2
    echo "  Method 2 (Pipe):  cat urls.txt | $0 <output_directory>" >&2
    exit 1
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

SCOPE_FILE=""
TECH_DIR=""
CLEANUP_INPUT=false

# Input Handling (Pipe vs File)
if [ "$#" -ge 2 ] && [ -f "$1" ]; then
    SCOPE_FILE="$1"
    TECH_DIR="$2"
elif [ ! -t 0 ] && [ "$#" -ge 1 ]; then
    TECH_DIR="$1"
    SCOPE_FILE=$(mktemp)
    cat > "$SCOPE_FILE"
    CLEANUP_INPUT=true
    
    if [ ! -s "$SCOPE_FILE" ]; then
        echo "[-] Error: Piped input was empty." >&2
        rm -f "$SCOPE_FILE"
        exit 1
    fi
else
    echo "[-] Error: Missing input file or output directory." >&2
    show_help
fi

TIMESTAMP=$(date +%s)

# Setup Directories
mkdir -p "$TECH_DIR"
mkdir -p "$TECH_DIR/html"
mkdir -p "$TECH_DIR/js"

echo "[+] [INFO] Starting mass-download into $TECH_DIR..." >&2

# Standard Endpoints (HTML, JSON, APIs)
echo "    -> [1/2] Probing and downloading standard endpoints..." >&2
grep -ivE '\.js($|\?)' "$SCOPE_FILE" | \
    httpx -silent -srd "$TECH_DIR/html" -sc -cl -ct -location -title -server -td -lc -wc -o "$TECH_DIR/httpx.txt" > /dev/null

# JavaScript Files
echo "    -> [2/2] Probing and downloading JavaScript files..." >&2
mkdir -p "$TECH_DIR/js"

grep -iE '\.js($|\?)' "$SCOPE_FILE" | xargs -I % -P 10 wget -q -x -nH --cut-dirs=0 -P "$TECH_DIR/js" "%"

echo "[+] [INFO] Downloading complete! Results saved in $TECH_DIR" >&2

# Cleanup
if [ "$CLEANUP_INPUT" = true ]; then
    rm -f "$SCOPE_FILE"
fi

# Time diff
end_time="$(date +%s)"
seconds="$(expr $end_time - $TIMESTAMP)"
time=""

if [[ "$seconds" -gt 59 ]]
then
    minutes=$(expr $seconds / 60)
    time="$minutes minutes"
else
    time="$seconds seconds"
fi
echo "$0 took $time to complete." >&2