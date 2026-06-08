#!/usr/bin/env bash
# Tests for the host-identity DB model (org/templates/db/). Each section builds
# a throwaway DB or scaffolds a throwaway engagement under mktemp -d so the
# working tree stays clean. Style mirrors tests/test-newPT.sh.
set -eo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SCHEMA="$ROOT/org/templates/db/schema.sql"
NEWPT="$ROOT/org/newPT.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ===========================================================================
# Section A — schema (Task 1)
# ===========================================================================
db="$TMP/a.db"
sqlite3 "$db" < "$SCHEMA" || fail "schema.sql failed to apply"

have_table() { sqlite3 "$db" ".tables" | tr ' ' '\n' | grep -qx "$1"; }
have_table host         || fail "table 'host' missing"
have_table host_ip      || fail "table 'host_ip' missing"
have_table host_segment || fail "table 'host_segment' missing"
sqlite3 "$db" ".tables" | tr ' ' '\n' | grep -qx asset_segment && \
    fail "table 'asset_segment' should be gone"
pass "host / host_ip / host_segment exist; asset_segment removed"

# asset has host_id and no longer has a host column
cols="$(sqlite3 "$db" "SELECT name FROM pragma_table_info('asset');")"
echo "$cols" | grep -qx host_id || fail "asset.host_id missing"
echo "$cols" | grep -qx host    && fail "asset.host should be removed"
pass "asset reworked to host_id"

# A host can be inserted, renamed in place, and keeps its id (stable identity)
sqlite3 "$db" "INSERT INTO host (name) VALUES ('10.0.0.5');"
hid="$(sqlite3 "$db" "SELECT id FROM host WHERE name='10.0.0.5';")"
sqlite3 "$db" "UPDATE host SET name='DC01' WHERE id=$hid;"
[ "$(sqlite3 "$db" "SELECT id FROM host WHERE name='DC01';")" = "$hid" ] || \
    fail "host id changed on rename — identity not stable"
pass "host renamed in place, identity preserved"

# host_ip ledger: one current IP per host (partial unique index)
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid, '10.0.0.5');"
if sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid, '10.0.0.9');" 2>/dev/null; then
    fail "two current IPs for one host should violate idx_host_ip_one_current"
fi
pass "at most one current IP per host enforced"

# Retiring the old lease lets a new current IP land
sqlite3 "$db" "UPDATE host_ip SET current=0 WHERE host_id=$hid AND ip='10.0.0.5';"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid, '10.0.0.9');" || \
    fail "could not record new current IP after retiring old lease"
pass "lease rotation works"

# one current owner per IP across hosts
sqlite3 "$db" "INSERT INTO host (name) VALUES ('PC02');"
hid2="$(sqlite3 "$db" "SELECT id FROM host WHERE name='PC02';")"
if sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid2, '10.0.0.9');" 2>/dev/null; then
    fail "two hosts currently owning 10.0.0.9 should violate idx_host_ip_one_owner"
fi
pass "at most one current owner per IP enforced"

echo "Section A passed."
echo "All tests passed."
