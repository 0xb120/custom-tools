#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/takeover-discovered.sh"

app_id="abc123def456"
mkdir -p "$(app_dir "$app_id")"
run="20260617T000000Z"
raw="$(raw_dir "$app_id" takeover-discovered "$run")"
mkdir -p "$raw"
printf '[Not Vulnerable] https://login.example.com\n' > "$raw/takeover.txt"

normalize_takeover_discovered "$app_id" "$run"

assert_file_exists "$(takeover "$app_id")" "takeover promoted to findings/"
assert_contains "$(takeover "$app_id")" "Not Vulnerable" "output kept unfiltered"
assert_contains "$(manifest_path "$app_id")" '"role":"takeover"' "takeover manifest row"
rm -rf "$BASE"
assert_summary
