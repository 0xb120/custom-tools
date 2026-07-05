#!/bin/bash
# ==============================================================================================
# Script Name: run-passive-probe.sh
# Description: Parallel OSINT URL Discovery Worker.
#              Takes a list of hosts/domains and queries passive open-source intelligence 
#              endpoints (Wayback Machine, AlienVault, Common Crawl, etc.) to rapidly 
#              discover historical, hidden, and exposed URLs without directly probing 
#              the target infrastructure heavily.
#
# Key Features:
#   - Unix-Compliant Input: Seamlessly accepts a target list via stdin (pipe) or a file argument.
#   - Parallel Execution: Runs `gau` and `urlfinder` simultaneously as background jobs 
#     to drastically reduce total scan time.
#   - Clean Output Handling: Routes standard errors to /dev/null to prevent terminal pollution, 
#     and outputs a perfectly deduplicated list either to stdout or a designated directory.
#   - Auto-Cleanup: Securely manages and deletes temporary buffers (mktemp) after execution.
#
# Usage:
#   [File]: ./run-passive-probe.sh <hosts.txt> [output_directory]
#   [Pipe]: cat hosts.txt | ./run-passive-probe.sh [output_directory]
# ==============================================================================================

show_help() {
    echo "Usage:" >&2
    echo "  Method 1 (File):  $0 <scope_file.txt> [output_dir]" >&2
    echo "  Method 2 (Pipe):  cat hosts.txt | $0 [output_dir]" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 app_001/hosts.txt /tmp/results/" >&2
    echo "  cat hosts.txt | $0 > final_urls.txt" >&2
    exit 1
}

# Check for help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

SCOPE_FILE=""
OUTPUT_DIR=""
CLEANUP_INPUT=false

# Determine input method (Pipe vs Positional Argument)
if [ "$#" -ge 1 ] && [ -f "$1" ]; then
    # Method 1: A valid file was explicitly passed as the first argument
    SCOPE_FILE="$1"
    OUTPUT_DIR="$2"
elif [ ! -t 0 ]; then
    # Method 2: No file argument, check if data is piped via stdin
    OUTPUT_DIR="$1"
    
    # Buffer stdin to a secure temporary file
    SCOPE_FILE=$(mktemp)
    cat > "$SCOPE_FILE"
    CLEANUP_INPUT=true
    
    # Check if the piped stream was actually empty
    if [ ! -s "$SCOPE_FILE" ]; then
        echo "[-] Error: Piped input was empty." >&2
        rm -f "$SCOPE_FILE"
        exit 1
    fi
else
    # Neither a file nor a piped input was found
    echo "[-] Error: No valid input provided." >&2
    show_help
fi

# Setup output directory if provided
if [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    FINAL_OUTPUT="$OUTPUT_DIR/osint.txt"
    echo "[+] [INFO] Output will be saved to $FINAL_OUTPUT" >&2
fi

# Create temp files for the tools
TMP_GAU=$(mktemp)
TMP_URLFINDER=$(mktemp)
timestamp="$(date +%s)"

echo "[+] [INFO] Running URL discovery tools in parallel..." >&2

# Run the tools simultaneously (using & and wait)
# We send standard error to /dev/null so tool logs don't pollute the terminal
cat "$SCOPE_FILE" | gau --threads 5 > "$TMP_GAU" 2>/dev/null &
PID1=$!

urlfinder -list "$SCOPE_FILE" -t 5 -silent -all > "$TMP_URLFINDER" 2>/dev/null &
PID2=$!

# Wait for all three background jobs to finish
wait $PID1 $PID2

# Merge, deduplicate, and route the output
if [ -n "$OUTPUT_DIR" ]; then
    # Save to directory
    cat "$TMP_GAU" "$TMP_URLFINDER" | sort -u > "$FINAL_OUTPUT"
    echo "[+] [INFO] URL discovery complete! Results saved in $FINAL_OUTPUT" >&2
else
    # Print directly to stdout (can be piped to anew, httpx, etc.)
    cat "$TMP_GAU" "$TMP_URLFINDER" | sort -u
fi

# Cleanup all temporary files
rm -f "$TMP_GAU" "$TMP_URLFINDER"

# Delete the temp file we created for stdin, if applicable
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