#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_scope2surface() {   # scope_file -> echoes run id
  local run raw; run="$(new_run)"; raw="$(surface_raw scope2surface "$run")"
  mkdir -p "$raw"
  "$WORKER/scope2surface.sh" "$1" "$raw" >&2
  echo "$run"
}

normalize_scope2surface() {   # run id
  local raw; raw="$(surface_raw scope2surface "$1")"
  mkdir -p "$(surface_dir)"
  cp "$raw/scans/subdomains.txt" "$(subdomains)"
  cp "$raw/scans/httpx_full_metadata.jsonl" "$(httpx_meta)"
  manifest_append _surface subdomains          subdomains.txt            scope2surface "raw/scope2surface/$1/scans/subdomains.txt"
  manifest_append _surface httpx_meta          httpx_full_metadata.jsonl scope2surface "raw/scope2surface/$1/scans/httpx_full_metadata.jsonl"
}

main() { local run; run="$(run_scope2surface "$1")"; normalize_scope2surface "$run"; }
set +u; [ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"; set -u
