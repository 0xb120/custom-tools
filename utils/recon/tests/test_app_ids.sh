#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../lib/paths.sh"

# no targets yet
assert_eq "[]" "$(app_ids_json)" "app_ids_json is [] when no workspaces"

mkdir -p "$BASE/targets/aaa111" "$BASE/targets/bbb222"
# a stray file (not a dir) must be ignored
: > "$BASE/targets/not_a_dir"

assert_eq "2" "$(app_ids | wc -l | tr -d ' ')" "app_ids lists one per workspace dir"
app_ids | grep -q '^aaa111$' && echo "ok: app_ids includes aaa111" || { echo "FAIL: aaa111 missing"; ASSERT_FAILED=1; }
# app_ids_json is a valid JSON array of length 2
assert_eq "2" "$(app_ids_json | jq 'length')" "app_ids_json has length 2"
assert_eq "aaa111" "$(app_ids_json | jq -r '.[0]')" "app_ids_json sorted/first element"
rm -rf "$BASE"
assert_summary
