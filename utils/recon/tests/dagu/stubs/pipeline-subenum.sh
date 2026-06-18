#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
app_id="$1"
[ -f "$(meta_json "$app_id")" ] || { echo "stub subenum: missing meta.json for $app_id" >&2; exit 1; }
printf 'dev.%s\n' "$app_id" > "$(subs "$app_id")"
manifest_append "$app_id" subs subs.txt stub-subenum stub
