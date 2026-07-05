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
  local raw f; raw="$(surface_raw scope2surface "$1")"
  # The worker creates these even with zero live results (httpx writes an empty -o file).
  # A *missing* file therefore means the worker's httpx stage never ran, not an empty surface.
  for f in subdomains.txt httpx_full_metadata.jsonl; do
    if [ ! -f "$raw/scans/$f" ]; then
      echo "scope2surface adapter: worker produced no scans/$f" >&2
      echo "  ($raw/scans/$f is missing — the legacy worker did not finish its httpx stage)." >&2
      echo "  Most common cause: a ProjectDiscovery tool is shadowed in PATH by a same-named" >&2
      echo "  binary — e.g. the Python 'httpx' CLI in ~/.local/bin overriding pd httpx in ~/go/bin." >&2
      echo "  Check: 'command -v httpx' must point at the ProjectDiscovery binary." >&2
      return 1
    fi
  done
  mkdir -p "$(surface_dir)"
  cp "$raw/scans/subdomains.txt" "$(subdomains)"
  cp "$raw/scans/httpx_full_metadata.jsonl" "$(httpx_meta)"
  manifest_append _surface subdomains          subdomains.txt            scope2surface "raw/scope2surface/$1/scans/subdomains.txt"
  manifest_append _surface httpx_meta          httpx_full_metadata.jsonl scope2surface "raw/scope2surface/$1/scans/httpx_full_metadata.jsonl"
  # Promote the scope-expansion files to the canonical scope/ dir (operator-facing,
  # not role-keyed pipeline inputs, so no manifest rows). Each is optional.
  mkdir -p "$(scope_dir)"
  for f in scope_init scope_urls scope_dns scope_ip; do
    if [ -f "$raw/scope/$f.txt" ]; then cp "$raw/scope/$f.txt" "$(scope_file "$f")"; fi
  done
}

main() { local run; run="$(run_scope2surface "$1")"; normalize_scope2surface "$run"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
