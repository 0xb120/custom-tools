#!/usr/bin/env bash
# Tests the finding "references" + "evidence links" rules enforced/rendered by ptctl:
#   - >=3 external references (each a line bearing an http(s):// URL) in ## References
#   - every reference list item must contain a link
#   - at least one reference from cheatsheetseries.owasp.org or portswigger.net/web-security
#   - managed evidence paths render as navigable ../-relative Markdown links
# References rule is a doctor warning (non-blocking) that is fatal under --strict.
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

W="findings/xss.md"
# Replace the whole ## References section (drops template placeholders) with the
# given bullet lines. References is the last section of the write-up.
set_refs() {
    sed -i '/^## References/,$d' "$W"
    { printf '## References\n\n'; printf '%s\n' "$@"; } >> "$W"
}

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

# --- Test 1: a fresh finding (placeholder refs, no links) warns but does NOT block ---
out="$("${PT[@]}" doctor 2>&1)" \
    || fail "plain doctor must stay non-blocking (exit 0) on a references warning"
echo "$out" | grep -qi 'external reference' \
    || fail "plain doctor should warn about missing external references"
pass "plain doctor warns (non-blocking) on a non-compliant references section"

# --- Test 2: doctor --strict treats the same finding as a failure ---
if "${PT[@]}" doctor --strict >/dev/null 2>&1; then
    fail "doctor --strict must fail on a non-compliant references section"
fi
pass "doctor --strict fails on a non-compliant references section"

# --- Test 3: a reference line without a link is flagged (every ref must be a link) ---
set_refs \
    '- https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html' \
    '- https://portswigger.net/web-security/cross-site-scripting' \
    '- https://cwe.mitre.org/data/definitions/79.html' \
    '- OWASP Testing Guide section 4.7 (no link)'
"${PT[@]}" doctor 2>&1 | grep -qi 'without a link' \
    || fail "doctor should warn that a reference line has no link"
if "${PT[@]}" doctor --strict >/dev/null 2>&1; then
    fail "doctor --strict must fail when a reference line has no link"
fi
pass "every reference must be a link: a text-only reference fails --strict"

# --- Test 4: three link references incl. a priority-domain one satisfies the rule ---
set_refs \
    '- https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html' \
    '- https://cwe.mitre.org/data/definitions/79.html' \
    '- https://developer.mozilla.org/en-US/docs/Glossary/Cross-site_scripting'
"${PT[@]}" doctor --strict >/dev/null 2>&1 \
    || fail "doctor --strict should pass with 3 link refs including a priority domain"
pass "3 link references including a priority-domain reference satisfies the rule"

# --- Test 5: three links but none from a priority domain still fails --strict ---
set_refs \
    '- https://example.com/a' \
    '- https://example.org/b' \
    '- https://developer.mozilla.org/c'
if "${PT[@]}" doctor --strict >/dev/null 2>&1; then
    fail "doctor --strict must fail when no reference is from a priority domain"
fi
pass "priority-domain rule: 3 links without a priority domain still fails --strict"

# --- Test 6: managed evidence paths render as navigable ../-relative links ---
grep -qF '[scans/web/req.http](../scans/web/req.http)' "$W" \
    || fail "evidence path should render as a navigable ../-relative Markdown link"
pass "managed evidence paths render as navigable relative links"

echo "All reference/evidence-link tests passed."
