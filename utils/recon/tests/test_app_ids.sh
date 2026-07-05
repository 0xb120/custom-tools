#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../lib/paths.sh"

# no targets yet
assert_eq "[]" "$(app_ids_json)" "app_ids_json is [] when no workspaces"

# per-target dirs are keyed by a 12-char hex app_id
mkdir -p "$BASE/scans/aaaaaaaaaaaa" "$BASE/scans/bbbbbbbbbbbb"
# surface-level siblings under scans/ must NOT be mistaken for app_ids
mkdir -p "$BASE/scans/raw/scope2surface/R1" "$BASE/scans/findings"
# a stray file (not a dir) must be ignored too
: > "$BASE/scans/subdomains.txt"

assert_eq "2" "$(app_ids | wc -l | tr -d ' ')" "app_ids lists one per target dir (raw/, findings/ excluded)"
app_ids | grep -q '^aaaaaaaaaaaa$' && echo "ok: app_ids includes aaaaaaaaaaaa" || { echo "FAIL: aaaaaaaaaaaa missing"; ASSERT_FAILED=1; }
app_ids | grep -q '^raw$'      && { echo "FAIL: raw leaked into app_ids"; ASSERT_FAILED=1; } || echo "ok: raw/ excluded"
app_ids | grep -q '^findings$' && { echo "FAIL: findings leaked into app_ids"; ASSERT_FAILED=1; } || echo "ok: findings/ excluded"
# app_ids_json is a valid JSON array of length 2
assert_eq "2" "$(app_ids_json | jq 'length')" "app_ids_json has length 2"
assert_eq "aaaaaaaaaaaa" "$(app_ids_json | jq -r '.[0]')" "app_ids_json sorted/first element"
rm -rf "$BASE"
assert_summary
