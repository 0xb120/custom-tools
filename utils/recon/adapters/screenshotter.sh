#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_screenshotter() {   # echoes run id
  local run staging m app_id; run="$(new_run)"; staging="$(surface_raw screenshotter "$run")"
  mkdir -p "$staging"
  for m in "$BASE"/targets/*/meta.json; do
    [ -e "$m" ] || continue
    app_id="$(jq -r .app_id "$m")"
    mkdir -p "$staging/$app_id"
    jq -r '.cluster_hosts[]' "$m" > "$staging/$app_id/hosts.txt"
  done
  "$WORKER/run-screenshotter.sh" "$staging" >&2 || true   # ONE batch httpx -screenshot pass
  echo "$run"
}

normalize_screenshotter() {   # run id
  local run staging d app_id; run="$1"; staging="$(surface_raw screenshotter "$run")"
  for d in "$staging"/*/; do
    [ -d "$d" ] || continue
    app_id="$(basename "${d%/}")"
    [ -d "$(app_dir "$app_id")" ] || continue
    if [ -f "${d%/}/screenshot.png" ]; then
      cp "${d%/}/screenshot.png" "$(screenshot "$app_id")"
      manifest_append "$app_id" screenshot screenshot.png run-screenshotter "att_surface/raw/screenshotter/$run/$app_id/"
    elif [ -f "${d%/}/screenshot.failed" ]; then
      cp "${d%/}/screenshot.failed" "$(app_dir "$app_id")/screenshot.failed"
      manifest_append "$app_id" screenshot screenshot.failed run-screenshotter "att_surface/raw/screenshotter/$run/$app_id/"
    fi
  done
}

main() { local run; run="$(run_screenshotter)"; normalize_screenshotter "$run"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
