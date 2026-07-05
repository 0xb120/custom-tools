#!/bin/bash
# ==============================================================================================
# Script Name: surfagr.sh
# Description: Post-Reconnaissance Application Grouper.
#              Parses raw JSONL output from httpx, intelligently clusters vhosts
#              that point to the same underlying web application, organizes them
#              into sanitized, isolated target directories, and triggers a
#              per-app screenshot pass for visual triage. Per-app deep recon
#              dispatch is handled by recon-orchestrator.sh.
#
# Key Features:
#   - Smart Clustering: Groups applications by Title, Content-Length, and Webserver.
#   - Safe Sanitization: Strips special characters and spaces to create Unix-safe folder names.
#   - Context Generation: Automatically builds `hosts.txt` and a human-readable `info.txt`
#     (containing IP, Tech Stack, Status Code) for each unique application.
#   - Visual Triage: Invokes run-screenshotter.sh once across all clustered apps.
#
# Usage:
#   ./surfagr.sh <httpx_full_metadata.jsonl> [destination_workspace]
# ==============================================================================================

show_help() {
    echo "Usage: $0 <httpx_full_metadata.jsonl> [destination_folder]" >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  httpx_full_metadata.jsonl   Path to the httpx jsonl file (hint: httpx -silent -sc -cl -td -title -ip -hash sha256 -location -fr -j -o httpx.jsonl)" >&2
    echo "  destination_folder          Directory for results (Optional. Defaults to ./surface_<random_hash>)" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 httpx_full_metadata.jsonl /dev/shm/target_recon" >&2
    echo "  $0 httpx_full_metadata.jsonl      <-- Saves to current directory in a 'surface_a1b2c3d4' folder" >&2
    exit 1
}

# Check for help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

# Enforce 1 or 2 arguments
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Error: Invalid number of arguments." >&2
    echo "" >&2
    show_help
fi

httpx_scope="$1"
timestamp="$(date +%s)"
rand_hash=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 8)
dest_dir="${2:-$PWD/surface_$rand_hash}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

# Validate that the scope file actually exists
if [ ! -f "$httpx_scope" ]; then
    echo "Error: httpx jsonl file '$httpx_scope' not found!" >&2
    exit 1
fi

echo "Setting up the workspace at $dest_dir..." >&2
mkdir -p "$dest_dir/tmp"
mkdir -p "$dest_dir/targets"

# =================
# TARGET GROUPING
# =================
echo "[INFO] Grouping of unique applications and creation of target folders..." >&2

# Grouping application by .title + (.content_length|tostring) + .webserver
cat "$httpx_scope" | \
    jq -s -c 'group_by(.title + (.content_length|tostring) + .webserver) | .[]' > "$dest_dir/tmp/app_groups.jsonl"

app_count=$(wc -l < "$dest_dir/tmp/app_groups.jsonl")
echo "[INFO] Detected $app_count unique applications. Folder creation in progress..." >&2

while read -r group; do
    
    # 1. Extract the first host from the group (replacing any ‘:’ in the port numbers with ‘_’)
    rep_host=$(echo "$group" | jq -r '.[0].host' | sed 's/:/_/g')
    
    # 2. Extract the original title
    raw_title=$(echo "$group" | jq -r '.[0].title')
    
    # 3. Title cleaning
    if [ "$raw_title" == "null" ] || [ -z "$raw_title" ]; then
        # If there is no title, we use the name of the web server or a fallback
        fallback_ws=$(echo "$group" | jq -r '.[0].webserver')
        if [ "$fallback_ws" != "null" ] && [ -n "$fallback_ws" ]; then
            safe_title=$(echo "$fallback_ws" | tr -dc 'a-zA-Z0-9_' | tr '[:upper:]' '[:lower:]')
        else
            safe_title="no_title"
        fi
    else
        # Replaces spaces with underscores, removes non-alphanumeric characters, 
        # converts to lower case and truncates to a maximum of 30 characters to avoid excessively long paths
        safe_title=$(echo "$raw_title" | sed 's/ /_/g' | tr -dc 'a-zA-Z0-9_' | tr '[:upper:]' '[:lower:]' | cut -c 1-30)
    fi
    
    folder_name="${rep_host}_${safe_title}"
    app_dir="$dest_dir/targets/$folder_name"
    
    # Create a folder for this specific application
    mkdir -p "$app_dir"
    
    # Extract all the URLs/vhosts from this group and save them to hosts.txt
    echo "$group" | jq -r '.[].url' | sort -u > "$app_dir/hosts.txt"
    
    # Extract the metadata to create a human-readable ‘info.txt’ file
    echo "$group" | jq -r '.[0] | "Title: \(.title)\nIP: \(.host_ip)\nWebserver: \(.webserver)\nTech Stack: \(if .tech then (.tech | join(", ")) else "None detected" end)\nContent-Length: \(.content_length)\nStatus-Code: \(.status_code)"' > "$app_dir/info.txt" 
    
    hosts_in_app=$(wc -l < "$app_dir/hosts.txt")
    
    echo "  -> Created: $folder_name [$hosts_in_app vhosts]" >&2

done < "$dest_dir/tmp/app_groups.jsonl"

# ===================
# VISUAL TRIAGE SHOTS
# ===================
echo "[INFO] Capturing per-app screenshots..." >&2
"$SCRIPT_DIR/run-screenshotter.sh" "$dest_dir/targets" || \
    echo "[WARN] Screenshot stage had errors (non-fatal); continuing." >&2

# Per-app pipeline dispatch is now handled by recon-orchestrator.sh
# (which runs pipeline-recon.sh AND pipeline-subenum.sh in parallel
# via concurrent xargs invocations across apps).

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

echo "$0 took $time to complete. Data have been isolated in $dest_dir/targets/" >&2
