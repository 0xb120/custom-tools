#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/screenshotter.sh"

app_id="abc123def456"
mkdir -p "$(app_dir "$app_id")"
run="20260617T000000Z"
staging="$(surface_raw screenshotter "$run")"
mkdir -p "$staging/$app_id"
printf 'PNGDATA' > "$staging/$app_id/screenshot.png"

normalize_screenshotter "$run"

assert_file_exists "$(screenshot "$app_id")" "screenshot promoted to app workspace"
assert_contains "$(manifest_path "$app_id")" '"role":"screenshot"' "screenshot manifest row"
rm -rf "$BASE"
assert_summary
