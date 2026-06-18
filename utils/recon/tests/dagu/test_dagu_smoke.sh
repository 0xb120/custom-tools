#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../../lib/paths.sh"
STUBS="$(cd "$DIR/stubs" && pwd)"
LIBD="$(cd "$DIR/../../lib" && pwd)"
DAG="$(cd "$DIR/../../orchestration/dagu" && pwd)/recon.yaml"
SCOPE="$DIR/fixtures/scope.txt"

dagu start "$DAG" -- BASE="$BASE" SCOPE="$SCOPE" ADAPTER_DIR="$STUBS" LIB_DIR="$LIBD" APP_DAG="$(dirname "$DAG")/app.yaml"

# scope-level artifacts
assert_file_exists "$(subdomains)"      "smoke: subdomains promoted"
assert_file_exists "$(httpx_meta)"      "smoke: httpx_meta promoted"
assert_file_exists "$(scope_findings)"  "smoke: stage-1 takeover findings present"
# fan-out happened for both discovered app_ids
assert_eq "2" "$(app_ids | wc -l | tr -d ' ')" "smoke: 2 app workspaces created"
for id in $(app_ids); do
  assert_file_exists "$(endpoints "$id")"  "smoke: endpoints for $id (recon ran)"
  assert_file_exists "$(subs "$id")"       "smoke: subs for $id (subenum ran)"
  assert_file_exists "$(screenshot "$id")" "smoke: screenshot for $id"
  assert_file_exists "$(takeover "$id")"   "smoke: takeover for $id (after recon+subenum)"
done
rm -rf "$BASE"
assert_summary
