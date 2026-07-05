#!/bin/bash
echo "$0: expand a scope into a broader attack surface"

# ==============================================================================================
# Script Name: scope2surface.sh
# Description: Automated Attack Surface Discovery & Enumeration Engine.
#              Takes a foundational scope (IPs, domains, wildcards), expands it via DNS 
#              resolution and TLS certificate parsing, and performs a tiered port scan. 
#              It intelligently filters out honeypots/tarpits before executing deep 
#              service fingerprinting across multiple engines.
#
# Key Features:
#   - Dynamic Input: Accepts scope via CLI argument or stdin (Unix Pipe).
#   - Deep Asset Discovery: Uses a massive toolkit (mapcidr, tlsx, dnsx, subfinder, 
#     shuffledns) to extract every possible subdomain and IP related to the scope.
#   - Tiered Port Scanning: Runs a fast 1,000-port scan first, isolates noisy honeypots 
#     (>= 15 open ports), and then runs a full 65,535-port scan ONLY on safe IPs.
#   - Multi-Engine Fingerprinting: Profiles exposed services using httpx, fingerprintx, 
#     and nerva to ensure no technology stack is missed.
#   - Deduplication: Uses jq to extract a clean, deduplicated list of unique web 
#     applications to avoid wasting time on duplicate vhosts.
#
# Usage:
#   [File]: ./scope2surface.sh <scope_file.txt> [destination_workspace]
#   [Pipe]: cat scope.txt | ./scope2surface.sh [destination_workspace]
# ==============================================================================================

show_help() {
    echo "Usage:"
    echo "  Method 1 (File): $0 <scope_file.txt> [destination_folder]"
    echo "  Method 2 (Pipe): cat scope.txt | $0 [destination_folder]"
    echo ""
    echo "Arguments:"
    echo "  scope_file.txt       Path to the file containing your scope (IPs, URLs, wildcards)"
    echo "  destination_folder   Directory for results (Optional. Defaults to ./recon_<random_hash>)"
    echo ""
    echo "Examples:"
    echo "  $0 in-scope.txt /dev/shm/target_recon"
    echo "  cat in-scope.txt | $0 /dev/shm/target_recon"
    exit 1
}

# Check for help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

#env="~/ws/"
#env="/dev/shm"
#ws="$2"
scope_file="$1"
timestamp="$(date +%s)"
rand_hash=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 8)
dest_dir="${2:-$PWD/recon_$rand_hash}"
is_piped=false

# 1. Determine input method (Pipe vs Positional Argument)
if [ "$#" -ge 1 ] && [ -f "$1" ]; then
    # Method 1: Explicit file provided as first argument
    is_piped=false
    scope_file="$1"
    dest_dir="${2:-$PWD/recon_$rand_hash}"
elif [ ! -t 0 ]; then
    # Method 2: Piped input via stdin
    is_piped=true
    # If piped, the first argument is actually the destination directory (optional)
    dest_dir="${1:-$PWD/recon_$rand_hash}"
    
    # Buffer stdin to a temporary file
    scope_file=$(mktemp)
    cat > "$scope_file"
    
    # Ensure the piped stream wasn't empty
    if [ ! -s "$scope_file" ]; then
        echo "[-] Error: Piped input was empty." >&2
        rm -f "$scope_file"
        exit 1
    fi
else
    # Neither a valid file nor pipe was provided
    echo "[-] Error: Invalid number of arguments or missing file." >&2
    echo "" >&2
    show_help
fi

echo "Setting up the workspace at $dest_dir..."
rm -rf "$dest_dir"/{scope,scans,targets,poc,wl,tmp}
mkdir -p "$dest_dir"/{scope,scans,targets,poc,wl,tmp}

# Place the scope file in the workspace
if [ "$is_piped" = true ]; then
    # Move the temporary file we created from stdin
    mv "$scope_file" "$dest_dir/scope/scope_init.txt"
else
    # Copy the existing file provided via CLI
    cp "$scope_file" "$dest_dir/scope/scope_init.txt"
fi

# ===============
# ASSET DISCOVERY
# ===============

# Extract URLs from scope and translate them to subdomain
echo "[DISCOVERY] Expanding scope from scoped URLs..."
grep -E '^https?://' $dest_dir/scope/scope_init.txt | anew $dest_dir/scope/scope_urls.txt | unfurl domain | anew $dest_dir/scope/scope_dns.txt

# Extract IPs from scope
echo "[DISCOVERY] Expanding scope from scoped IPs..."
cat $dest_dir/scope/scope_init.txt | grep -E "\b([0-9]{1,3}\.){3}[0-9]{1,3}"/"*[0-9]{1,2}\b" | mapcidr -silent | anew $dest_dir/scope/scope_ip.txt
# Search subdomains from tls certificates and add them to subdomain list
cat  $dest_dir/scope/scope_ip.txt | naabu -silent -top-ports 1000 -exclude-cdn -c 50 -rate 1000 | \
    tlsx -san -cn -silent -resp-only | anew $dest_dir/scans/tlsx_raw.txt | dnsx -silent | anew $dest_dir/scope/scope_dns.txt
# Search subdomains from reverse DNS pointers, add them to subdomain list, search for other subdomains from certificates and add also them to sub-list
cat $dest_dir/scope/scope_ip.txt | dnsx -ptr -resp-only -silent | anew $dest_dir/scope/scope_dns.txt | \
    tlsx -san -cn -silent -resp-only | anew $dest_dir/scans/tlsx_raw.txt | dnsx -silent | anew $dest_dir/scope/scope_dns.txt

# Extract DNS from scope
echo "[DISCOVERY] Expanding scope from scoped DNS..."
cat $dest_dir/scope/scope_init.txt | dnsx -silent -o $dest_dir/scope/scope_dns.txt

# Extract wildcards dns and expand them
wildcard=$(cat $dest_dir/scope/scope_init.txt | grep -E "^\*\." | sed 's/^\*\.//g')
echo $wildcard | assetfinder -subs-only | anew $dest_dir/scope/scope_dns.txt
echo $wildcard | subfinder -silent | anew $dest_dir/scope/scope_dns.txt

# Resolve DNS and filter out wildcards
cat $dest_dir/scope/scope_dns.txt | shuffledns -mode resolve -sw -silent -r /opt/resolvers/resolvers-trusted.txt | anew $dest_dir/scans/subdomains.txt

# Consolidate unique IPs
cat $dest_dir/scans/subdomains.txt $dest_dir/scans/tlsx_raw.txt | dnsx -a -resp-only -silent | anew $dest_dir/scans/unique_ips.txt;
cat $dest_dir/scope/scope_ip.txt | anew $dest_dir/scans/unique_ips.txt

# Create a mapping of Domain:IP
cat $dest_dir/scans/subdomains.txt $dest_dir/scans/tlsx_raw.txt | dnsx -a -resp -nc -silent -o $dest_dir/scans/domain_ip_map.txt

# ===========
# ENUMERATION
# ===========

# Scan open ports for IPs
echo "[SCAN] Starting port scan on discovered IPs..."
cat "$dest_dir/scans/unique_ips.txt" | naabu -exclude-cdn -tp 1000 -silent -cdn -o "$dest_dir/scans/naabu_1k_results.txt"

echo "[INFO] Filtering out honeypots and tarpits..."
# Count the number of open ports per IP
cat "$dest_dir/scans/naabu_1k_results.txt" | cut -d ':' -f 1 | sort | uniq -c > "$dest_dir/tmp/naabu_port_counts.txt"
# Extract IPs with LESS than 50 open ports (Valid targets for automation)
awk '$1 < 15 {print $2}' "$dest_dir/tmp/naabu_port_counts.txt" > "$dest_dir/tmp/valid_ips.txt"
# Extract IPs with 50 or MORE open ports (Honeypots/Tarpits for manual review)
awk '$1 >= 15 {print $2}' "$dest_dir/tmp/naabu_port_counts.txt" > "$dest_dir/targets/high_port_number_manual_review.txt"
honeypot_count=$(wc -l < "$dest_dir/targets/high_port_number_manual_review.txt")
echo "[INFO] Isolated $honeypot_count potential honeypots. Saved to targets/high_port_number_manual_review.txt"

# Perform a FULL port scan ONLY on the safe IPs
if [ -s "$dest_dir/tmp/valid_ips.txt" ]; then
    echo "[SCAN] Performing FULL (65535) port scan on validated safe IPs..."
    cat "$dest_dir/tmp/valid_ips.txt" | naabu -exclude-cdn -tp full -silent -cdn -o "$dest_dir/scans/naabu_full_results.txt"
else
    # If no valid IPs were found, create an empty file so the script doesn't break
    echo "[INFO] No safe IPs found to scan."
    touch "$dest_dir/scans/naabu_full_results.txt"
fi

# Scan every asset and store its metadata
echo "[SCAN] Started fingerprinting services with httpx..."
cat $dest_dir/scans/tlsx_raw.txt \
    $dest_dir/scans/subdomains.txt \
    $dest_dir/scans/naabu_full_results.txt \
    "$dest_dir/targets/high_port_number_manual_review.txt" | cut -d " " -f1 | \
    httpx -silent -sc -cl -td -title -ip -hash sha256 -location -fr -j -o $dest_dir/scans/httpx_full_metadata.jsonl 
#PID1=$!

echo "[SCAN] Started fingerprinting services with fingerprintx and nerva..."
cat $dest_dir/scans/naabu_full_results.txt | cut -d " " -f1 | \
    fingerprintx --json | anew $dest_dir/scans/fingerprintx_full_metadata.jsonl

cat $dest_dir/scans/naabu_full_results.txt | cut -d " " -f1 | \
    nerva --json | anew $dest_dir/scans/nerva_full_metadata.jsonl

#wait $PID1 $PID2

# Extract unique web applications
echo "[INFO] Creating unique HTTP targets..."
cat $dest_dir/scans/httpx_full_metadata.jsonl | jq -s 'unique_by(.title + (.content_length|tostring) + .webserver) | .[] | .url' | cut -d '"' -f2 | anew $dest_dir/targets/unique_webapps.txt

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

echo "Scan took $time"