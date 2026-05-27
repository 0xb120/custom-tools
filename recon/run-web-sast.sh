#!/bin/bash
# ==============================================================================================
# Script Name: run-web-sast.sh
# Description: Client-Side SAST and Secret Hunter.
#              Analyzes downloaded JavaScript files for hardcoded secrets, API keys, JWTs, 
#              and hidden endpoints using high-fidelity regex patterns.
#
# Usage: ./run-web-sast.sh <application_directory>
# ==============================================================================================

show_help() {
    echo "Usage: $0 <application_directory>" >&2
    echo "Example: $0 targets/app_001" >&2
    exit 1
}

if [[ "$1" == "-h" || "$1" == "--help" || -z "$1" ]]; then
    show_help
fi

APP_DIR="${1%/}"
JS_DIR="$APP_DIR/js"

# Safety check
if [ ! -d "$JS_DIR" ]; then
    echo "[-] Error: JS directory not found at $JS_DIR. Did the downloader run?" >&2
    exit 1
fi

# Check if there are actually JS files to scan
JS_COUNT=$(find "$JS_DIR" -type f -name "*.txt" | wc -l)
if [ "$JS_COUNT" -eq 0 ]; then
    echo "[-] [INFO] No downloaded JS files found in $JS_DIR. Skipping SAST." >&2
    exit 0
fi

echo "    -> [START] Running Client-Side SAST on $JS_COUNT JavaScript files..." >&2

SAST_OUT="$APP_DIR/sast_secrets.txt"
ENDPOINTS_OUT="$APP_DIR/sast_hidden_endpoints.txt"

# Clear old results if they exist
> "$SAST_OUT"
> "$ENDPOINTS_OUT"

# =========================================================================
# 1. SECRET HUNTING (Regex Patterns)
# =========================================================================
echo "       [*] Hunting for hardcoded secrets and tokens..." >&2

# We use grep -HnEor to search recursively, print the filename (-H), line number (-n),
# use extended regex (-E), print only the match (-o), and search directories (-r).

# AWS Access Keys
grep -HnEor 'AKIA[0-9A-Z]{16}' "$JS_DIR" | sed 's/^/[AWS Key] /' >> "$SAST_OUT"

# Stripe Standard API Keys
grep -HnEor 'sk_live_[0-9a-zA-Z]{24}' "$JS_DIR" | sed 's/^/[Stripe Key] /' >> "$SAST_OUT"

# Google Cloud API Keys
grep -HnEor 'AIza[0-9A-Za-z-_]{35}' "$JS_DIR" | sed 's/^/[Google API] /' >> "$SAST_OUT"

# JSON Web Tokens (JWTs)
grep -HnEor 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' "$JS_DIR" | sed 's/^/[JWT Token] /' >> "$SAST_OUT"

# Slack Webhooks/Tokens
grep -HnEor 'xox[baprs]-[0-9]{12}-[0-9]{12}-[a-zA-Z0-9]{24}' "$JS_DIR" | sed 's/^/[Slack Token] /' >> "$SAST_OUT"
grep -HnEor 'https://hooks\.slack\.com/services/T[a-zA-Z0-9_]{8}/B[a-zA-Z0-9_]{8}/[a-zA-Z0-9_]{24}' "$JS_DIR" | sed 's/^/[Slack Webhook] /' >> "$SAST_OUT"

# =========================================================================
# 2. HIDDEN ENDPOINT EXTRACTION
# =========================================================================
echo "       [*] Extracting hidden API paths from JS source code..." >&2

# This regex looks for relative paths wrapped in quotes (e.g., "/api/v1/users" or '/config/env')
# It ignores common noise like HTML tags or standard JS syntax.
grep -Eor '(["'\''])(/[a-zA-Z0-9_.-]+)+(/)?(["'\''])' "$JS_DIR" | \
    cut -d ':' -f 2- | tr -d '"' | tr -d "'" | sort -u > "$ENDPOINTS_OUT"

# =========================================================================
# 3. SUMMARY AND CLEANUP
# =========================================================================
SECRET_COUNT=$(wc -l < "$SAST_OUT")
PATH_COUNT=$(wc -l < "$ENDPOINTS_OUT")

if [ "$SECRET_COUNT" -gt 0 ]; then
    echo "       [!] ALARM: Found $SECRET_COUNT potential secrets! Check $SAST_OUT" >&2
else
    # If no secrets found, delete the empty file to keep the workspace clean
    rm -f "$SAST_OUT"
fi

if [ "$PATH_COUNT" -gt 0 ]; then
    echo "       [+] Extracted $PATH_COUNT hidden relative paths. Check $ENDPOINTS_OUT" >&2
else
    rm -f "$ENDPOINTS_OUT"
fi

echo "    <- [DONE] SAST Analysis complete." >&2