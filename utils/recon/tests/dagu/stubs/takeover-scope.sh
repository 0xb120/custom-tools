#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
[ -f "$(subdomains)" ] || { echo "stub takeover-scope: missing subdomains input" >&2; exit 1; }
mkdir -p "$(surface_dir)/findings"
: > "$(scope_findings)"   # no findings (stub)
manifest_append _surface takeovers_scope findings/takeovers_scope.jsonl stub-takeover-scope stub
