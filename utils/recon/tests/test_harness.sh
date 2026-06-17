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

# Negative-path self-test: a failing assertion must set ASSERT_FAILED, run in a
# subshell so it does not pollute the outer counter.
if ( source "$DIR/assert.sh"; assert_eq "a" "b" "intentional mismatch" >/dev/null 2>&1; [ "$ASSERT_FAILED" -eq 1 ] ); then
  echo "ok: assert_eq detects mismatch (negative path)"
else
  echo "FAIL: assert_eq did not flag a mismatch"; ASSERT_FAILED=1
fi

assert_summary
