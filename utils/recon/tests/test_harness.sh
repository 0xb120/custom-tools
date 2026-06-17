#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

assert_eq "a" "a" "eq matches equal values"
assert_ne "a" "b" "ne matches different values"
tmp="$(mktemp)"; echo "hello world" > "$tmp"
assert_file_exists "$tmp" "file exists after write"
assert_contains "$tmp" "hello" "contains finds substring"
rm -f "$tmp"

assert_summary
