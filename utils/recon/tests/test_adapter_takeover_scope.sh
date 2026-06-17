#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/takeover-scope.sh"

run="20260617T000000Z"
raw="$(surface_raw takeover-scope "$run")"
mkdir -p "$raw"
printf '{"template-id":"takeover"}\n' > "$raw/takeovers.jsonl"

normalize_takeover_scope "$run"
assert_file_exists "$(scope_findings)" "scope findings promoted"
assert_contains "$(manifest_path _surface)" '"role":"takeovers_scope"' "takeovers_scope manifest row"

# absent findings -> canonical still created (empty)
run2="20260617T000001Z"
mkdir -p "$(surface_raw takeover-scope "$run2")"   # no takeovers.jsonl produced
normalize_takeover_scope "$run2"
assert_file_exists "$(scope_findings)" "scope findings exists even when worker produced none"
rm -rf "$BASE"
assert_summary
