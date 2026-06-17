#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_pipeline_recon() {   # app_id -> echoes run id
  local app_id run raw; app_id="$1"; run="$(new_run)"; raw="$(raw_dir "$app_id" pipeline-recon "$run")"
  mkdir -p "$raw"
  jq -r '.cluster_hosts[]' "$(meta_json "$app_id")" > "$raw/hosts.txt"
  "$WORKER/pipeline-recon.sh" "$raw" >&2
  echo "$run"
}

normalize_pipeline_recon() {   # app_id run
  local app_id run raw; app_id="$1"; run="$2"; raw="$(raw_dir "$app_id" pipeline-recon "$run")"
  cp "$raw/all_endpoints_clean.txt" "$(endpoints "$app_id")"
  manifest_append "$app_id" endpoints endpoints.txt "katana+gau+urlfinder" "raw/pipeline-recon/$run/all_endpoints_clean.txt"
  # rm -rf before cp -r: canonical dir must reflect the latest run exactly (like the
  # file `cp` overwrites endpoints.txt). Plain `cp -r src dst` would nest as dst/js/js
  # when dst already exists from a prior run.
  if [ -d "$raw/js" ]; then
    rm -rf "$(app_dir "$app_id")/js"; cp -r "$raw/js" "$(app_dir "$app_id")/js"
    manifest_append "$app_id" js_assets js run-downloader "raw/pipeline-recon/$run/js/"
  fi
  if [ -d "$raw/html" ]; then
    rm -rf "$(app_dir "$app_id")/html"; cp -r "$raw/html" "$(app_dir "$app_id")/html"
    manifest_append "$app_id" html_assets html run-downloader "raw/pipeline-recon/$run/html/"
  fi
}

main() { local run; run="$(run_pipeline_recon "$1")"; normalize_pipeline_recon "$1" "$run"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
