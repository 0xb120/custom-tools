#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../../lib/paths.sh"
STUBS="$(cd "$DIR/stubs" && pwd)"
DAG="$(cd "$DIR/../../orchestration/dagu" && pwd)/recon.yaml"
SCOPE="$DIR/fixtures/scope.txt"
# Only BASE/SCOPE/ADAPTER_DIR passed; LIB_DIR and APP_DAG must resolve from recon.yaml's absolute defaults.
dagu start "$DAG" -- BASE="$BASE" SCOPE="$SCOPE" ADAPTER_DIR="$STUBS"
assert_eq "2" "$(app_ids | wc -l | tr -d ' ')" "defaults: fan-out ran for 2 app_ids (LIB_DIR default resolved)"
for id in $(app_ids); do
  assert_file_exists "$(endpoints "$id")" "defaults: endpoints for $id (APP_DAG default resolved → child ran)"
  assert_file_exists "$(takeover "$id")"  "defaults: takeover for $id"
done
rm -rf "$BASE"
assert_summary
