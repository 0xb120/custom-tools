#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
app_id="$1"
[ -f "$(endpoints "$app_id")" ] && [ -f "$(subs "$app_id")" ] || {
  echo "stub takeover-discovered: requires endpoints+subs for $app_id" >&2; exit 1; }
mkdir -p "$(app_dir "$app_id")/findings"
printf '[Not Vulnerable] https://%s\n' "$app_id" > "$(takeover "$app_id")"
manifest_append "$app_id" takeover findings/takeover.txt stub-takeover-discovered stub
