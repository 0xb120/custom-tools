#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../lib/paths.sh"
source "$DIR/../lib/manifest.sh"

manifest_append abc endpoints endpoints.txt katana "raw/pipeline-recon/R1/"
manifest_append _surface subdomains subdomains.txt subfinder "scope.txt"

app_mf="$(manifest_path abc)"
srf_mf="$(manifest_path _surface)"

assert_file_exists "$app_mf" "per-app manifest created"
assert_file_exists "$srf_mf" "surface manifest created"
assert_contains "$app_mf" '"role":"endpoints"' "endpoints role recorded"
assert_contains "$app_mf" '"path":"endpoints.txt"' "endpoints path recorded"
assert_contains "$srf_mf" '"role":"subdomains"' "subdomains role recorded"
# every line must be valid JSON
if jq -e . "$app_mf" >/dev/null && jq -e . "$srf_mf" >/dev/null; then
  echo "ok: manifest rows are valid JSON"
else
  echo "FAIL: manifest rows are not valid JSON"; ASSERT_FAILED=1
fi
rm -rf "$BASE"
assert_summary
