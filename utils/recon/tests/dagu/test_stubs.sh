#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../../lib/paths.sh"
S="$DIR/stubs"

# Run the stubs in dependency order (mimicking the DAG) — every precondition met.
bash "$S/scope2surface.sh" "$DIR/fixtures/scope.txt"
bash "$S/surfagr.sh"
bash "$S/screenshotter.sh"
bash "$S/takeover-scope.sh"
for id in $(app_ids); do
  bash "$S/pipeline-recon.sh" "$id"
  bash "$S/pipeline-subenum.sh" "$id"
  bash "$S/takeover-discovered.sh" "$id"
done

assert_file_exists "$(subdomains)" "scope2surface stub wrote subdomains"
assert_file_exists "$(httpx_meta)" "scope2surface stub wrote httpx_meta"
assert_file_exists "$(scope_findings)" "takeover-scope stub wrote scope findings"
assert_eq "2" "$(app_ids | wc -l | tr -d ' ')" "surfagr stub produced 2 app_id workspaces"
for id in $(app_ids); do
  assert_file_exists "$(meta_json "$id")"      "meta.json for $id"
  assert_file_exists "$(endpoints "$id")"      "endpoints for $id"
  assert_file_exists "$(subs "$id")"           "subs for $id"
  assert_file_exists "$(screenshot "$id")"     "screenshot for $id"
  assert_file_exists "$(takeover "$id")"       "takeover for $id"
  assert_contains "$(manifest_path "$id")" '"role":"meta"' "manifest meta row for $id"
done

# Ordering guard: takeover-discovered stub must refuse to run before recon+subenum.
fresh="$(mktemp -d)"; export BASE="$fresh"
bash "$S/scope2surface.sh" "$DIR/fixtures/scope.txt"; bash "$S/surfagr.sh"
one="$(app_ids | head -n1)"
if bash "$S/takeover-discovered.sh" "$one" 2>/dev/null; then
  echo "FAIL: takeover-discovered stub ran without endpoints/subs"; ASSERT_FAILED=1
else
  echo "ok: takeover-discovered stub enforces its preconditions"
fi
rm -rf "$BASE" "$fresh"
assert_summary
