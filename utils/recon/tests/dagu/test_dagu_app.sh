#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../../lib/paths.sh"; source "$DIR/../../lib/appid.sh"
STUBS="$(cd "$DIR/stubs" && pwd)"
DAG="$(cd "$DIR/../../orchestration/dagu" && pwd)/app.yaml"

# Pre-create a workspace the child DAG operates on (surfagr's job, done here directly).
app_id="$(app_id_for app.example.com 443)"
mkdir -p "$(app_dir "$app_id")"
printf '{"app_id":"%s","cluster_hosts":["https://app.example.com"]}\n' "$app_id" > "$(meta_json "$app_id")"

# Run the child DAG with stub adapters. (Use START_CMD param syntax from SYNTAX.md.)
dagu start "$DAG" -- BASE="$BASE" APP_ID="$app_id" ADAPTER_DIR="$STUBS"

assert_file_exists "$(endpoints "$app_id")" "child DAG produced endpoints (recon ran)"
assert_file_exists "$(subs "$app_id")"      "child DAG produced subs (subenum ran)"
assert_file_exists "$(takeover "$app_id")"  "child DAG produced takeover (after recon+subenum)"
rm -rf "$BASE"
assert_summary
