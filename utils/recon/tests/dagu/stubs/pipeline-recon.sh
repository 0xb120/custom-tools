#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
app_id="$1"
[ -f "$(meta_json "$app_id")" ] || { echo "stub recon: missing meta.json for $app_id" >&2; exit 1; }
printf 'https://%s/dashboard\n' "$app_id" > "$(endpoints "$app_id")"
mkdir -p "$(app_dir "$app_id")/js" "$(app_dir "$app_id")/html"
printf '//js' > "$(app_dir "$app_id")/js/app.js"
printf '<html></html>' > "$(app_dir "$app_id")/html/index.html"
manifest_append "$app_id" endpoints endpoints.txt stub-recon stub
