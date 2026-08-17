#!/usr/bin/env bash
# Tests for `ptctl.py poc sync` — materializes kind='poc' evidence into poc/<slug>/.
# Follows the seeding pattern of test-finding-workflow.sh. Uses bare `python3`
# (project convention); run with a real python3 on PATH.
set -eo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
NEWPT="$ROOT/org/newPT.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
bash "$NEWPT" none engagement >/dev/null || fail "could not scaffold engagement"
cd engagement
PT=(python3 db/ptctl.py)

sqlite3 db/engagement.db \
    "INSERT INTO segment (name, description) VALUES ('web', 'web app');
     INSERT INTO host (name, dns) VALUES ('app', 'app.test');
     INSERT INTO host_ip (host_id, ip) VALUES (1, '192.0.2.10');
     INSERT INTO host_segment (host_id, segment_id) VALUES (1, 1);
     INSERT INTO asset (host_id, port, protocol, tls) VALUES (1, 443, 'https', 1);"

mkdir -p scans/web/xss
printf 'https://app.test/x?q=<script>alert(1)</script>\n' > scans/web/xss/poc-urls.txt
printf 'not-a-real-png\n'                                 > scans/web/xss/shot.png

# One observation carrying a kind='poc' evidence plus a non-poc (screenshot) evidence.
"${PT[@]}" observation add \
    --title 'Reflected XSS' --family XSS --segment web --asset A1 --source manual \
    --component login-aspx --method GET --route '/Login.aspx' --selector ReturnUrl \
    --evidence scans/web/xss/poc-urls.txt --kind poc >/dev/null \
    || fail "could not add observation with poc evidence"
"${PT[@]}" observation evidence O0001 \
    --evidence scans/web/xss/shot.png --kind screenshot >/dev/null \
    || fail "could not add non-poc evidence"

"${PT[@]}" finding create \
    --slug reflected-xss --group-key 'xss|reflected|web' \
    --title 'Reflected XSS' --severity MEDIUM --segment web \
    --observation O0001 >/dev/null || fail "could not create finding"

test -d poc/reflected-xss || fail "finding poc dir missing"
[ -z "$(ls -A poc/reflected-xss)" ] || fail "poc dir should start empty (ptctl only mkdirs it)"

# --- Test 1: poc sync copies kind='poc' evidence and skips non-poc ---
"${PT[@]}" poc sync >/dev/null || fail "poc sync failed"
test -f poc/reflected-xss/poc-urls.txt || fail "kind=poc evidence was not copied into poc/<slug>/"
test -f poc/reflected-xss/shot.png && fail "non-poc evidence must NOT be copied"
diff -q scans/web/xss/poc-urls.txt poc/reflected-xss/poc-urls.txt >/dev/null \
    || fail "copied poc file content differs from source"
pass "poc sync copies kind=poc evidence into poc/<slug>/ and skips non-poc"

# --- Test 2: idempotent — a second run neither errors nor duplicates ---
"${PT[@]}" poc sync >/dev/null || fail "second poc sync failed (not idempotent)"
[ "$(ls poc/reflected-xss | wc -l)" = 1 ] || fail "idempotent sync should not duplicate files"
pass "poc sync is idempotent"

# --- Test 3: no prune — a manually added repro script is preserved ---
printf '#!/bin/sh\necho repro\n' > poc/reflected-xss/repro.sh
"${PT[@]}" poc sync >/dev/null || fail "poc sync failed with a manual file present"
test -f poc/reflected-xss/repro.sh || fail "poc sync must not delete manually added files"
pass "poc sync preserves manually added repro scripts (no prune)"

# --- Test 4: basename collision from two source dirs is disambiguated ---
mkdir -p scans/web/openredirect
printf 'https://app.test/login?ReturnUrl=//evil\n' > scans/web/openredirect/poc-urls.txt
"${PT[@]}" observation evidence O0001 \
    --evidence scans/web/openredirect/poc-urls.txt --kind poc >/dev/null \
    || fail "could not add a second poc evidence with a colliding basename"
"${PT[@]}" poc sync >/dev/null || fail "poc sync failed on colliding basenames"
test -f poc/reflected-xss/poc-urls.txt || fail "first poc-urls.txt should remain"
[ "$(find poc/reflected-xss -name '*poc-urls.txt' | wc -l)" = 2 ] \
    || fail "both colliding poc files should be materialized under distinct names"
pass "poc sync disambiguates basename collisions from different source dirs"

# --- Test 5: single-finding form syncs only the named finding ---
"${PT[@]}" poc sync F01 >/dev/null || fail "poc sync <finding> failed"
pass "poc sync accepts an optional single-finding argument"

echo "All poc sync tests passed."
