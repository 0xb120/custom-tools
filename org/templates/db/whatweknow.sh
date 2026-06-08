#!/bin/bash
# What do we know about a single machine? One host-centric view folded from
# every source the engagement keeps, because each holds something the others
# don't:
#
#   1. db/engagement.db  — structured truth: ports, access, creds, findings
#   2. journal.md        — chronological analysis tagged @<host> (the "why")
#   3. scans/            — raw tool output mentioning the host
#
# The argument may be the machine's stable name, its dns, OR any IP it has ever
# held. We resolve it to the machine's full token set — name + dns + every IP in
# the host_ip ledger (current and retired) — and search journal.md and scans/
# for ALL of them. That is what defeats DHCP churn: a scan captured under a now-
# retired IP still surfaces when you ask by the machine's stable name.
#
# Run from anywhere — paths resolve relative to this script's location.
#
# Usage: bash db/whatweknow.sh <name-or-ip>     e.g. bash db/whatweknow.sh DC01

set -euo pipefail

# Hostnames, dns names and IPs only ever use this charset; rejecting the rest
# closes the quote-injection hole (the value reaches SQLite's .param dot-command
# single-quoted inline, and grep) without needing to escape. Applied to the CLI
# arg AND to every token read back from the DB before it reaches grep.
valid_token() { case "$1" in *[!A-Za-z0-9.:_-]*) return 1 ;; *) return 0 ;; esac; }

host="${1:-}"
[ -n "$host" ] || { echo "Usage: $0 <name-or-ip>   (e.g. $0 DC01)" >&2; exit 1; }
valid_token "$host" || { echo "ERROR: invalid host '$host' (allowed: letters, digits, . : _ -)" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
activity_root="$(cd "$script_dir/.." && pwd)"
db="$script_dir/engagement.db"
query="$script_dir/queries/host-dossier.sql"

echo "############################################################"
echo "# Dossier: $host"
echo "############################################################"

# --- 1. DB-side view: identity / ip history / assets / segments / creds / findings
echo
echo "=== DATABASE ==="
if [ -f "$db" ] && [ -f "$query" ]; then
    sqlite3 "$db" ".param set :host '$host'" ".read $query"
else
    echo "(missing $db or $query — skipping)"
fi

# --- Build the token set: name + dns + every IP this machine has held. --------
# Resolve $host (name, dns, or any ip) to its host id(s), then collect all the
# strings that identify the same machine. Always include the literal arg so an
# unknown host still searches for what the operator typed.
tokens="$host"
if [ -f "$db" ]; then
    db_tokens="$(sqlite3 "$db" "
        WITH ids AS (
            SELECT id      FROM host    WHERE name = '$host' OR dns = '$host'
            UNION
            SELECT host_id FROM host_ip WHERE ip = '$host'
        )
        SELECT name FROM host    WHERE id      IN (SELECT id FROM ids)
        UNION
        SELECT dns  FROM host    WHERE id      IN (SELECT id FROM ids) AND dns IS NOT NULL AND dns <> ''
        UNION
        SELECT ip   FROM host_ip WHERE host_id IN (SELECT id FROM ids);
    " 2>/dev/null || true)"
    tokens="$tokens"$'\n'"$db_tokens"
fi
# Dedupe + drop blanks + drop anything failing the charset guard.
search_tokens="$(printf '%s\n' "$tokens" | sort -u | while IFS= read -r t; do
    [ -n "$t" ] || continue
    if valid_token "$t"; then printf '%s\n' "$t"; else echo "  (skipping invalid token '$t')" >&2; fi
done)"

# --- 2. Journal history: entries tagged @<token> for every token --------------
echo
echo "=== JOURNAL (@$host and aliases) ==="
if [ -f "$activity_root/journal.md" ]; then
    found=0
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        hits="$(grep -n -F -- "@$t" "$activity_root/journal.md" || true)"
        if [ -n "$hits" ]; then echo "--- @$t"; printf '%s\n' "$hits"; found=1; fi
    done <<< "$search_tokens"
    [ "$found" = 1 ] || echo "(no journal entries for $host or its aliases)"
else
    echo "(no journal.md)"
fi

# --- 3. Raw scan artifacts mentioning ANY token -------------------------------
# List which files name a token, then a bounded preview of the matching lines
# (capped per file so a huge dump can't bury the rest of the dossier).
echo
echo "=== RAW SCANS (scans/ mentioning $host or its IPs) ==="
if [ -d "$activity_root/scans" ]; then
    # Collect matching files across all tokens, dedupe.
    matches=""
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        m="$(grep -rIlF -- "$t" "$activity_root/scans" 2>/dev/null || true)"
        [ -n "$m" ] && matches="$matches"$'\n'"$m"
    done <<< "$search_tokens"
    matches="$(printf '%s\n' "$matches" | sed '/^$/d' | sort -u)"
    if [ -n "$matches" ]; then
        printf '%s\n' "$matches" | while IFS= read -r f; do
            echo "--- ${f#"$activity_root"/}"
            # show lines matching any token in this file
            grep -nE -- "$(printf '%s\n' "$search_tokens" | sed '/^$/d' | paste -sd'|' -)" "$f" | head -n 20 || true
        done
    else
        echo "(no scans/ files mention $host or its IPs)"
    fi
else
    echo "(no scans/ dir)"
fi
