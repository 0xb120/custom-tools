#!/usr/bin/env bash
# Runs every test_*.sh in this directory; non-zero exit if any fail.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$DIR"/test_*.sh; do
  [ -e "$t" ] || continue
  echo "== $(basename "$t") =="
  bash "$t" || rc=1
done
exit "$rc"
