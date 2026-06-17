# Tiny assertion helper. Source it, run assert_*, then call assert_summary.
ASSERT_FAILED=0

assert_eq() {  # expected actual msg
  if [ "$1" != "$2" ]; then echo "FAIL: $3 (expected '$1', got '$2')"; ASSERT_FAILED=1
  else echo "ok: $3"; fi
}
assert_ne() {  # a b msg
  if [ "$1" = "$2" ]; then echo "FAIL: $3 (both '$1')"; ASSERT_FAILED=1
  else echo "ok: $3"; fi
}
assert_file_exists() {  # path msg
  if [ ! -e "$1" ]; then echo "FAIL: $2 (missing $1)"; ASSERT_FAILED=1
  else echo "ok: $2"; fi
}
assert_contains() {  # file substr msg
  if ! grep -qF "$2" "$1" 2>/dev/null; then echo "FAIL: $3 (no '$2' in $1)"; ASSERT_FAILED=1
  else echo "ok: $3"; fi
}
assert_summary() {
  if [ "$ASSERT_FAILED" -eq 0 ]; then echo "PASS"; else echo "FAILED"; exit 1; fi
}
