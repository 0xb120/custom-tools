#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
found=0
for m in "$BASE"/targets/*/meta.json; do
  [ -e "$m" ] || continue
  found=1; app_id="$(jq -r .app_id "$m")"
  printf 'PNG' > "$(screenshot "$app_id")"
  manifest_append "$app_id" screenshot screenshot.png stub-screenshotter stub
done
[ "$found" = 1 ] || { echo "stub screenshotter: no meta.json inputs" >&2; exit 1; }
