#!/usr/bin/env bash
# Tests the "complete HTTP request evidence" rule enforced by ptctl doctor:
#   - every active finding must have >=1 evidence of kind 'http-request' whose file
#     contains a valid HTTP request line (^METHOD path HTTP/x.y),
#   - unless the write-up carries an opt-out marker <!-- no-http-request: reason -->.
# Warning in plain doctor, blocking under --hook (Stop hook), fatal under --strict.
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

# Compliant references so the references rule never confounds the --strict checks.
REFS=(
    '- https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html'
    '- https://portswigger.net/web-security/cross-site-scripting'
    '- https://cwe.mitre.org/data/definitions/79.html'
)
set_refs() {  # $1 = write-up path
    local w="$1"; shift
    sed -i '/^## References/,$d' "$w"
    { printf '## References\n\n'; printf '%s\n' "${REFS[@]}"; } >> "$w"
}

sqlite3 db/engagement.db \
    "INSERT INTO segment (name, description) VALUES ('web', 'web app');
     INSERT INTO host (name, dns) VALUES ('app', 'app.test');
     INSERT INTO host_ip (host_id, ip) VALUES (1, '192.0.2.10');
     INSERT INTO host_segment (host_id, segment_id) VALUES (1, 1);
     INSERT INTO asset (host_id, port, protocol, tls) VALUES (1, 443, 'https', 1);"

mkdir -p scans/web
printf 'not-a-real-png\n'          > scans/web/shot.png
printf 'not-a-real-png-3\n'        > scans/web/shot3.png
printf 'GET /x HTTP/1.1\nHost: app.test\n' > scans/web/req.http
printf 'GET /r HTTP/1.1\nHost: app.test\n' > scans/web/req2.http
printf 'just some notes, no request line\n' > scans/web/bad.http

# --- Finding F01: created from an observation whose only evidence is a screenshot ---
"${PT[@]}" observation add --title 'Reflected XSS' --family XSS --segment web \
    --asset A1 --component login --method GET --route '/x' --selector q --source manual \
    --evidence scans/web/shot.png --kind screenshot >/dev/null || fail "obs1 add failed"
"${PT[@]}" finding create --slug xss --group-key 'xss|reflected|web' \
    --title 'Reflected XSS' --severity MEDIUM --segment web \
    --observation O0001 >/dev/null || fail "finding create failed"
set_refs findings/xss.md

# --- Test 1: no http-request evidence → warn (plain), block (--hook), fatal (--strict) ---
out="$("${PT[@]}" doctor 2>&1)" || fail "plain doctor must stay non-blocking (exit 0)"
echo "$out" | grep -q 'HTTP request evidence' \
    || fail "plain doctor should warn that the finding has no HTTP request evidence"
pass "plain doctor warns (non-blocking) when a finding has no HTTP request evidence"

if "${PT[@]}" doctor --hook --quiet >/dev/null 2>&1; then
    fail "doctor --hook (Stop hook) must block when a finding has no HTTP request"
fi
pass "doctor --hook blocks the stop when a finding has no HTTP request"

if "${PT[@]}" doctor --strict >/dev/null 2>&1; then
    fail "doctor --strict must fail when a finding has no HTTP request"
fi
pass "doctor --strict fails when a finding has no HTTP request"

# --- Test 2: registering a complete request makes F01 compliant ---
"${PT[@]}" observation evidence O0001 --evidence scans/web/req.http --kind http-request \
    >/dev/null || fail "could not register http-request evidence"
"${PT[@]}" doctor --strict >/dev/null 2>&1 \
    || fail "doctor --strict should pass once a complete http-request is registered"
"${PT[@]}" doctor --hook --quiet >/dev/null 2>&1 \
    || fail "doctor --hook should not block once a complete http-request is registered"
pass "a registered http-request with a valid request line satisfies the rule"

# --- Test 3: an http-request file without a request line is flagged as incomplete ---
"${PT[@]}" observation add --title 'Open redirect' --family open-redirect --segment web \
    --asset A1 --component redirect --method GET --route '/r' --selector url --source manual \
    --evidence scans/web/bad.http >/dev/null || fail "obs2 add failed"
"${PT[@]}" finding create --slug open-redirect --group-key 'open-redirect|returnurl|web' \
    --title 'Open redirect' --severity LOW --segment web \
    --observation O0002 >/dev/null || fail "finding2 create failed"
set_refs findings/open-redirect.md
"${PT[@]}" doctor 2>&1 | grep -q 'is incomplete' \
    || fail "doctor should flag an http-request evidence with no valid request line"
if "${PT[@]}" doctor --strict >/dev/null 2>&1; then
    fail "doctor --strict must fail on an incomplete (no request line) http-request"
fi
pass "an http-request evidence without a request line is flagged as incomplete"
# repair F02 so the engagement is compliant again for the opt-out test
"${PT[@]}" observation evidence O0002 --evidence scans/web/req2.http --kind http-request \
    >/dev/null || fail "could not repair F02 with a complete request"
"${PT[@]}" doctor --strict >/dev/null 2>&1 || fail "F02 repair should restore --strict"

# --- Test 4: the opt-out marker exempts a finding with no http-request evidence ---
"${PT[@]}" observation add --title 'Weak TLS config' --family tls --segment web \
    --asset A1 --component tls --route '/' --source manual \
    --evidence scans/web/shot3.png --kind screenshot >/dev/null || fail "obs3 add failed"
"${PT[@]}" finding create --slug weak-tls --group-key 'tls|weak-config|web' \
    --title 'Weak TLS config' --severity LOW --segment web \
    --observation O0003 >/dev/null || fail "finding3 create failed"
set_refs findings/weak-tls.md
if "${PT[@]}" doctor --strict >/dev/null 2>&1; then
    fail "F03 without a request should fail --strict before the opt-out marker"
fi
printf '\n<!-- no-http-request: TLS misconfiguration, not tied to a single request -->\n' \
    >> findings/weak-tls.md
"${PT[@]}" doctor --strict >/dev/null 2>&1 \
    || fail "the no-http-request opt-out marker should exempt the finding"
pass "the opt-out marker exempts a finding with no http-request evidence"

echo "All http-request-rule tests passed."
