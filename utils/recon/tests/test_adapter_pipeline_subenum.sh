#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/pipeline-subenum.sh"

app_id="abc123def456"
mkdir -p "$(app_dir "$app_id")"
run="20260617T000000Z"
raw="$(raw_dir "$app_id" pipeline-subenum "$run")"
mkdir -p "$raw"
printf 'dev.example.com\nstaging.example.com\n' > "$raw/discovered_subs.txt"

normalize_pipeline_subenum "$app_id" "$run"

assert_file_exists "$(subs "$app_id")" "subs promoted to canonical"
assert_contains "$(subs "$app_id")" "dev.example.com" "subs content present"
assert_contains "$(manifest_path "$app_id")" '"role":"subs"' "subs manifest row"
rm -rf "$BASE"
assert_summary
