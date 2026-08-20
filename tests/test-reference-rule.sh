#!/usr/bin/env bash
# Tests the finding "references" rule enforced by `ptctl.py doctor`:
#   - at least 3 external references (lines bearing an http(s):// URL) in ## References
#   - at least one from cheatsheetseries.owasp.org or portswigger.net/web-security
# Warning in plain doctor (non-blocking), fatal under --strict.
# Uses bare `python3` (project convention); run with a real python3 on PATH.
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
mkdir -p scans/web
printf 'GET / HTTP/1.1\n' > scans/web/req.http
"${PT[@]}" observation add --title 'Reflected XSS' --family XSS --segment web \
    --asset A1 --component login --method GET --route '/x' --source manual \
    --evidence scans/web/req.http >/dev/null || fail "observation add failed"
"${PT[@]}" finding create --slug xss --group-key 'xss|reflected|web' \
    --title 'Reflected XSS' --severity MEDIUM --segment web \
    --observation O0001 >/dev/null || fail "finding create failed"

W="findings/xss.md"

# --- Test 1: a fresh finding (placeholder refs, no URLs) warns but does NOT block ---
out="$("${PT[@]}" doctor 2>&1)" \
    || fail "plain doctor must stay non-blocking (exit 0) on a references warning"
echo "$out" | grep -qi 'external reference' \
    || fail "plain doctor should warn about missing external references"
pass "plain doctor warns (non-blocking) on <3 external references"

# --- Test 2: doctor --strict treats the same finding as a failure ---
if "${PT[@]}" doctor --strict >/dev/null 2>&1; then
    fail "doctor --strict must fail when a finding has <3 external references"
fi
pass "doctor --strict fails on <3 external references"

# --- Test 3: 3 external refs but none from a priority domain still fails --strict ---
cat >> "$W" <<'REF'
- https://example.com/a
- https://example.org/b
- https://developer.mozilla.org/c
REF
if "${PT[@]}" doctor --strict >/dev/null 2>&1; then
    fail "doctor --strict must fail when no reference is from a priority domain"
fi
"${PT[@]}" doctor 2>&1 | grep -qi 'cheatsheetseries.owasp.org' \
    || fail "priority-domain warning should name the required domains"
pass "priority-domain rule: 3 refs without a priority domain still fails --strict"

# --- Test 4: one priority-domain ref among the three satisfies the rule ---
sed -i 's#https://example.com/a#https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html#' "$W"
"${PT[@]}" doctor --strict >/dev/null 2>&1 \
    || fail "doctor --strict should pass with 3 refs including a priority-domain reference"
pass "3 external refs including a priority-domain reference satisfies the rule"

# --- Test 5: portswigger web-security also counts as a priority domain ---
sed -i 's#https://cheatsheetseries.owasp.org/[^ ]*#https://portswigger.net/web-security/cross-site-scripting#' "$W"
"${PT[@]}" doctor --strict >/dev/null 2>&1 \
    || fail "portswigger.net/web-security must be accepted as a priority domain"
pass "portswigger.net/web-security is accepted as a priority domain"

echo "All reference-rule tests passed."
