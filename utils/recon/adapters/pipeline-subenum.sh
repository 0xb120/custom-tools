#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_pipeline_subenum() {   # app_id -> echoes run id
  local app_id run raw; app_id="$1"; run="$(new_run)"; raw="$(raw_dir "$app_id" pipeline-subenum "$run")"
  mkdir -p "$raw"
  jq -r '.cluster_hosts[]' "$(meta_json "$app_id")" > "$raw/hosts.txt"
  "$WORKER/pipeline-subenum.sh" "$raw" >&2
  echo "$run"
}

normalize_pipeline_subenum() {   # app_id run
  local app_id run raw; app_id="$1"; run="$2"; raw="$(raw_dir "$app_id" pipeline-subenum "$run")"
  cp "$raw/discovered_subs.txt" "$(subs "$app_id")"
  manifest_append "$app_id" subs subs.txt subfinder "raw/pipeline-subenum/$run/discovered_subs.txt"
}

main() { local run; run="$(run_pipeline_subenum "$1")"; normalize_pipeline_subenum "$1" "$run"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
