#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/scope2surface.sh"     # sourced: main guard prevents auto-run

# Build a fixture raw output exactly as the worker would have produced it.
run="20260617T000000Z"
raw="$(surface_raw scope2surface "$run")"
mkdir -p "$raw/scans" "$raw/scope"
printf 'a.example.com\nb.example.com\n' > "$raw/scans/subdomains.txt"
printf '{"url":"https://a.example.com"}\n'  > "$raw/scans/httpx_full_metadata.jsonl"
printf 'example.com\n'                       > "$raw/scope/scope_init.txt"
printf 'a.example.com\nb.example.com\n'      > "$raw/scope/scope_dns.txt"

normalize_scope2surface "$run"

assert_file_exists "$(subdomains)" "subdomains promoted to canonical"
assert_file_exists "$(httpx_meta)" "httpx_meta promoted to canonical"
assert_file_exists "$(scope_file scope_init)" "scope_init promoted to scope/"
assert_file_exists "$(scope_file scope_dns)"  "scope_dns promoted to scope/"
assert_contains "$(subdomains)" "a.example.com" "canonical subdomains has content"
assert_contains "$(manifest_path _surface)" '"role":"subdomains"' "subdomains manifest row"
assert_contains "$(manifest_path _surface)" '"role":"httpx_meta"' "httpx_meta manifest row"
rm -rf "$BASE"
assert_summary
