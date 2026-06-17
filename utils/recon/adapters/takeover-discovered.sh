#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_takeover_discovered() {   # app_id -> echoes run id
  local app_id run raw; app_id="$1"; run="$(new_run)"; raw="$(raw_dir "$app_id" takeover-discovered "$run")"
  mkdir -p "$raw"
  cp "$(endpoints "$app_id")" "$raw/all_endpoints_clean.txt"
  if [ -f "$(subs "$app_id")" ]; then cp "$(subs "$app_id")" "$raw/discovered_subs.txt"; else : > "$raw/discovered_subs.txt"; fi
  "$WORKER/run-takeover-discovered.sh" "$raw" >&2
  echo "$run"
}

normalize_takeover_discovered() {   # app_id run
  local app_id run raw; app_id="$1"; run="$2"; raw="$(raw_dir "$app_id" takeover-discovered "$run")"
  mkdir -p "$(app_dir "$app_id")/findings"
  cp "$raw/takeover.txt" "$(takeover "$app_id")"
  manifest_append "$app_id" takeover findings/takeover.txt subjack "raw/takeover-discovered/$run/takeover.txt"
}

main() { local run; run="$(run_takeover_discovered "$1")"; normalize_takeover_discovered "$1" "$run"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
