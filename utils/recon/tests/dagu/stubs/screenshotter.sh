#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
found=0
for app_id in $(app_ids); do
  [ -f "$(meta_json "$app_id")" ] || continue
  found=1
  printf 'PNG' > "$(screenshot "$app_id")"
  manifest_append "$app_id" screenshot screenshot.png stub-screenshotter stub
done
[ "$found" = 1 ] || { echo "stub screenshotter: no meta.json inputs" >&2; exit 1; }
