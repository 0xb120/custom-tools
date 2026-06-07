#!/bin/bash
# What do we know about a single host? One host-centric view folded from every
# source the engagement keeps, because each holds something the others don't:
#
#   1. db/engagement.db  — structured truth: ports, access, creds, findings
#   2. journal.md        — chronological analysis tagged @<host> (the "why")
#   3. scans/            — raw tool output mentioning the host
#
# (3) matters because the model doesn't always transcribe every banner, version
# string, or open port it saw during a scan into the DB — those details survive
# only in the raw output. This view recovers them instead of trusting the DB to
# be complete.
#
# Run from anywhere — paths resolve relative to this script's location.
#
# Usage: bash db/whatweknow.sh <host>     e.g. bash db/whatweknow.sh 10.0.0.5

set -euo pipefail

host="${1:-}"
[ -n "$host" ] || { echo "Usage: $0 <host>   (e.g. $0 10.0.0.5)" >&2; exit 1; }

# Guard the value before it reaches the SQLite .param dot-command (single-quoted
# inline) and grep. Hostnames and IPs only ever use this charset; rejecting the
# rest closes the quote-injection hole without needing to escape.
case "$host" in
    *[!A-Za-z0-9.:_-]*) echo "ERROR: invalid host '$host' (allowed: letters, digits, . : _ -)" >&2; exit 1 ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
activity_root="$(cd "$script_dir/.." && pwd)"
db="$script_dir/engagement.db"
query="$script_dir/queries/host-dossier.sql"

echo "############################################################"
echo "# Dossier: $host"
echo "############################################################"

# --- 1. DB-side view: assets / segments / credentials / findings ------------
echo
echo "=== DATABASE ==="
if [ -f "$db" ] && [ -f "$query" ]; then
    sqlite3 "$db" ".param set :host '$host'" ".read $query"
else
    echo "(missing $db or $query — skipping)"
fi

# --- 2. Journal history: entries tagged @<host> -----------------------------
echo
echo "=== JOURNAL (@$host) ==="
if [ -f "$activity_root/journal.md" ]; then
    grep -n -F "@$host" "$activity_root/journal.md" || echo "(no @$host entries)"
else
    echo "(no journal.md)"
fi

# --- 3. Raw scan artifacts mentioning the host ------------------------------
# List which files name the host, then a bounded preview of the matching lines
# (capped per file so a huge dump can't bury the rest of the dossier).
echo
echo "=== RAW SCANS (scans/ mentioning $host) ==="
if [ -d "$activity_root/scans" ]; then
    matches="$(grep -rIlF "$host" "$activity_root/scans" 2>/dev/null || true)"
    if [ -n "$matches" ]; then
        printf '%s\n' "$matches" | while IFS= read -r f; do
            echo "--- ${f#"$activity_root"/}"
            grep -n -F "$host" "$f" | head -n 20
        done
    else
        echo "(no scans/ files mention $host)"
    fi
else
    echo "(no scans/ dir)"
fi
