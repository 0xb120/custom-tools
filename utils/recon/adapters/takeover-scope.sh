#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_takeover_scope() {   # echoes run id
  local run raw; run="$(new_run)"; raw="$(surface_raw takeover-scope "$run")"
  mkdir -p "$raw"
  "$WORKER/run-takeover-scope.sh" "$(subdomains)" "$raw/takeovers.jsonl" >&2 || true
  echo "$run"
}

normalize_takeover_scope() {   # run id
  local raw; raw="$(surface_raw takeover-scope "$1")"
  mkdir -p "$(surface_dir)/findings"
  [ -f "$raw/takeovers.jsonl" ] || : > "$raw/takeovers.jsonl"
  cp "$raw/takeovers.jsonl" "$(scope_findings)"
  manifest_append _surface takeovers_scope findings/takeovers_scope.jsonl nuclei "raw/takeover-scope/$1/takeovers.jsonl"
}

main() { local run; run="$(run_takeover_scope)"; normalize_takeover_scope "$run"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
