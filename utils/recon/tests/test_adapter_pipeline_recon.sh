#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/pipeline-recon.sh"

app_id="abc123def456"
mkdir -p "$(app_dir "$app_id")"
run="20260617T000000Z"
raw="$(raw_dir "$app_id" pipeline-recon "$run")"
mkdir -p "$raw/js" "$raw/html"
printf 'https://login.example.com/dashboard\n' > "$raw/all_endpoints_clean.txt"
printf 'console.log(1)\n' > "$raw/js/app.js"
printf '<html></html>\n'  > "$raw/html/index.html"

normalize_pipeline_recon "$app_id" "$run"

assert_file_exists "$(endpoints "$app_id")" "endpoints promoted"
assert_contains "$(endpoints "$app_id")" "dashboard" "endpoints content present"
assert_file_exists "$(app_dir "$app_id")/js/app.js" "js dir promoted"
assert_file_exists "$(app_dir "$app_id")/html/index.html" "html dir promoted"
assert_contains "$(manifest_path "$app_id")" '"role":"endpoints"' "endpoints manifest row"
assert_contains "$(manifest_path "$app_id")" '"role":"js_assets"' "js manifest row"
assert_contains "$(manifest_path "$app_id")" '"role":"html_assets"' "html manifest row"
rm -rf "$BASE"
assert_summary
