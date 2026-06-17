#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
source "$DIR/../lib/appid.sh"

a="$(app_id_for example.com 443)"
b="$(app_id_for example.com 443)"
c="$(app_id_for other.com 443)"
d="$(app_id_for example.com 8443)"

assert_eq "$a" "$b" "same host:port is deterministic"
assert_eq "12" "${#a}" "app_id is 12 chars"
assert_ne "$a" "$c" "different host yields different id"
assert_ne "$a" "$d" "different port yields different id"

assert_summary
