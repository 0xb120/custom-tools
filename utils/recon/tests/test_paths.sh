#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="/tmp/eng"
source "$DIR/../lib/paths.sh"

assert_eq "/tmp/eng/scope"                            "$(scope_dir)"               "scope_dir"
assert_eq "/tmp/eng/scope/scope_init.txt"             "$(scope_file scope_init)"   "scope_file"
assert_eq "/tmp/eng/scans"                            "$(surface_dir)"             "surface_dir"
assert_eq "/tmp/eng/scans/subdomains.txt"             "$(subdomains)"              "subdomains"
assert_eq "/tmp/eng/scans/httpx_full_metadata.jsonl"  "$(httpx_meta)"             "httpx_meta"
assert_eq "/tmp/eng/scans/findings/takeovers_scope.jsonl" "$(scope_findings)"     "scope_findings"
assert_eq "/tmp/eng/scans/raw/surfagr/R1"             "$(surface_raw surfagr R1)"  "surface_raw"
assert_eq "/tmp/eng/scans/abc"                        "$(app_dir abc)"             "app_dir"
assert_eq "/tmp/eng/scans/abc/meta.json"              "$(meta_json abc)"           "meta_json"
assert_eq "/tmp/eng/scans/abc/endpoints.txt"          "$(endpoints abc)"           "endpoints"
assert_eq "/tmp/eng/scans/abc/subs.txt"               "$(subs abc)"                "subs"
assert_eq "/tmp/eng/scans/abc/screenshot.png"         "$(screenshot abc)"          "screenshot"
assert_eq "/tmp/eng/scans/abc/findings/takeover.txt"  "$(takeover abc)"            "takeover"
assert_eq "/tmp/eng/scans/abc/raw/katana/R1"          "$(raw_dir abc katana R1)"   "raw_dir"
assert_eq "/tmp/eng/scans/abc/manifest.jsonl"         "$(manifest_path abc)"       "manifest_path app"
assert_eq "/tmp/eng/scans/manifest.jsonl"             "$(manifest_path _surface)"  "manifest_path surface"
r="$(new_run)"; assert_ne "" "$r" "new_run is non-empty"

assert_summary
