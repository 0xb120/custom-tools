#!/usr/bin/env bash
# End-to-end tests for the observation -> finding -> evidence control plane.
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
    "INSERT INTO segment (name, description) VALUES ('customer-portal', 'web app');
     INSERT INTO host (name, dns) VALUES ('portal', 'portal.test');
     INSERT INTO host_ip (host_id, ip) VALUES (1, '192.0.2.10');
     INSERT INTO host_segment (host_id, segment_id) VALUES (1, 1);
     INSERT INTO asset (host_id, port, protocol, tls) VALUES (1, 443, 'https', 1);
     INSERT INTO asset (host_id, port, protocol, tls) VALUES (1, 8443, 'https', 1);"
mkdir -p scans/customer-portal/burp
printf 'GET /api/orders/100 HTTP/1.1\nHost: portal.test\n' \
    > scans/customer-portal/burp/req-1842.http
printf 'HTTP/1.1 200 OK\n\n{\"tenant\":\"other\",\"order\":100}\n' \
    > scans/customer-portal/burp/res-1842.http

# One concrete test case is idempotent even when two agents record it at once.
"${PT[@]}" observation add \
    --title 'Cross-tenant read through orderId' \
    --family BOLA --segment customer-portal \
    --asset A1 \
    --component orders-api --boundary cross-tenant \
    --method GET --route '/api/orders/:id' --selector orderId \
    --attacker-role customer --target-role customer \
    --source 'Burp Repeater item 1842' \
    --evidence scans/customer-portal/burp/req-1842.http \
    --evidence scans/customer-portal/burp/res-1842.http \
    >"$TMP/agent-a.out" &
agent_a_pid=$!

"${PT[@]}" observation add \
    --title 'Same occurrence recorded a second time' \
    --family IDOR --segment customer-portal \
    --asset A1 \
    --component orders-api --boundary cross-tenant \
    --method GET --route '/api/orders/:id' --selector orderId \
    --attacker-role customer --target-role customer \
    --source 'second agent' >"$TMP/agent-b.out" &
agent_b_pid=$!

wait "$agent_a_pid" || fail "first concurrent observation capture failed"
wait "$agent_b_pid" || fail "second concurrent observation capture failed"
out="$(cat "$TMP/agent-a.out" "$TMP/agent-b.out")"
echo "$out" | grep -q 'created O0001' || fail "one agent should create O0001"
echo "$out" | grep -q 'O0001 already exists' || \
    fail "the other agent should resolve to O0001"
[ "$(sqlite3 db/engagement.db 'SELECT COUNT(*) FROM observation;')" = 1 ] || \
    fail "duplicate observation created a second row"
pass "concurrent observation capture is serialized and idempotent"

"${PT[@]}" finding create \
    --slug cross-tenant-order-access \
    --group-key 'orders-api|object-authorization|cross-tenant' \
    --title 'Cross-tenant access to orders' --severity MEDIUM \
    --cwe 'CWE-639' --segment customer-portal \
    --observation O0001 >/dev/null || fail "could not promote O0001"

[ "$(sqlite3 db/engagement.db 'SELECT COUNT(*) FROM finding;')" = 1 ] || \
    fail "finding row missing"
test -f findings/cross-tenant-order-access.md || fail "finding write-up missing"
test -d poc/cross-tenant-order-access || fail "finding PoC directory missing"
grep -q 'Group key.*orders-api|object-authorization|cross-tenant' \
    findings/cross-tenant-order-access.md || fail "group key not synced to write-up"
grep -q 'Observation(s).*O0001' findings/cross-tenant-order-access.md || \
    fail "observation reference not synced to write-up"
grep -q 'res-1842.http' findings/cross-tenant-order-access.md || \
    fail "registered evidence not rendered into write-up"
grep -q 'Affected asset(s).*A1 portal:443/https' \
    findings/cross-tenant-order-access.md || fail "affected asset not derived from O0001"
[ "$(sqlite3 db/engagement.db \
    'SELECT COUNT(*) FROM finding_asset WHERE finding_id=1 AND asset_id=1;')" = 1 ] || \
    fail "observation asset was not linked to finding_asset"
"${PT[@]}" finding asset F01 --add A2 >/dev/null
grep -q 'A2 portal:8443/https' findings/cross-tenant-order-access.md || \
    fail "explicitly added asset was not synced to Markdown"
"${PT[@]}" finding asset F01 --remove A2 >/dev/null
grep -q 'A2 portal:8443/https' findings/cross-tenant-order-access.md && \
    fail "removed supplemental asset remained in Markdown"
if "${PT[@]}" finding asset F01 --remove A1 >"$TMP/remove-derived.out" 2>&1; then
    fail "asset required by a linked observation should not be removable"
fi
grep -q 'linked observation' "$TMP/remove-derived.out" || \
    fail "derived-asset rejection should explain the invariant"
grep -q 'F01' engagement.md || fail "finding index was not rendered"
pass "one command atomically creates DB row, write-up, PoC, and index"

# A new occurrence cannot be attached until its proof has been registered.
printf 'GET /api/orders/101?customerId=2 HTTP/1.1\n' \
    > scans/customer-portal/burp/req-1900.http
"${PT[@]}" observation add \
    --title 'Cross-tenant read through customerId' \
    --family BOLA --segment customer-portal \
    --asset A1 \
    --component orders-api --boundary cross-tenant \
    --method GET --route '/api/orders/:id' --selector customerId \
    --attacker-role customer --target-role customer \
    --source 'Burp Repeater item 1900' >/dev/null

if "${PT[@]}" finding attach F01 --observation O0002 >"$TMP/no-evidence.out" 2>&1; then
    fail "an observation without evidence should not be attachable"
fi
grep -q 'no registered evidence' "$TMP/no-evidence.out" || \
    fail "missing-evidence rejection should explain how to fix it"
if ! printf '{}' | CLAUDE_PROJECT_DIR="$PWD" \
    bash .claude/hooks/engagement-doctor.sh >"$TMP/new-observation-hook.out" 2>&1; then
    cat "$TMP/new-observation-hook.out" >&2
    fail "Stop hook must not block on an observation awaiting operator review"
fi
# A proposed observation is a queue entry, never drift: the hook hands it over,
# and doctor must not call it a warning.
grep -q 'Operator review queue' "$TMP/new-observation-hook.out" || \
    fail "Stop hook should hand over the operator review queue"
grep -q 'O0002' "$TMP/new-observation-hook.out" || \
    fail "Stop hook should name the queued observation"
grep -qi 'WARN.*O0002' "$TMP/new-observation-hook.out" && \
    fail "an observation awaiting review must not be reported as a warning"
"${PT[@]}" doctor >"$TMP/queue-doctor.out" 2>&1 || true
grep -q 'NOTE: 1 observation(s) awaiting operator review' "$TMP/queue-doctor.out" || \
    fail "doctor should report the review queue as a notice, not a warning"

"${PT[@]}" observation evidence O0002 \
    --evidence scans/customer-portal/burp/req-1900.http >/dev/null
"${PT[@]}" finding attach F01 --observation O0002 >/dev/null || \
    fail "could not attach evidenced occurrence O0002"
[ "$(sqlite3 db/engagement.db \
    'SELECT COUNT(*) FROM finding_observation WHERE finding_id=1;')" = 2 ] || \
    fail "second occurrence was not grouped under F01"
grep -q 'O0001.*,.*O0002' findings/cross-tenant-order-access.md || \
    fail "write-up does not list both occurrences"
if "${PT[@]}" observation state O0002 dismissed --reason 'late override' \
    >"$TMP/linked-state.out" 2>&1; then
    fail "an accepted observation should not be dismissable behind its finding"
fi
grep -q 'state is managed by that canonical link' "$TMP/linked-state.out" || \
    fail "linked-state rejection should explain the invariant"
pass "evidence is mandatory and field-level occurrences attach to one finding"

# A different occurrence with the same report identity cannot open a duplicate.
printf 'GET /api/invoices/77 HTTP/1.1\n' \
    > scans/customer-portal/burp/req-2000.http
"${PT[@]}" observation add \
    --title 'Cross-tenant invoice read' \
    --family BOLA --segment customer-portal \
    --asset A1 \
    --component orders-api --boundary cross-tenant \
    --method GET --route '/api/invoices/:id' --selector invoiceId \
    --attacker-role customer --target-role customer \
    --source 'Burp Repeater item 2000' \
    --evidence scans/customer-portal/burp/req-2000.http >/dev/null

if "${PT[@]}" finding create \
    --slug duplicate-cross-tenant-access \
    --group-key 'orders-api|object-authorization|cross-tenant' \
    --title 'Duplicate BOLA' --severity HIGH \
    --segment customer-portal --observation O0003 \
    >"$TMP/duplicate-finding.out" 2>&1; then
    fail "same group_key should not create another active finding"
fi
grep -q 'attach the observation instead' "$TMP/duplicate-finding.out" || \
    fail "duplicate rejection should direct the agent to attach"
if "${PT[@]}" finding create \
    --slug synonym-cross-tenant-access \
    --group-key 'orders-api|broken-object-authz|cross-tenant' \
    --title 'Same BOLA under a synonymous key' --severity HIGH \
    --segment customer-portal --observation O0003 \
    >"$TMP/related-finding.out" 2>&1; then
    fail "same observation profile should flag a related finding despite a new key"
fi
grep -q 'related observation profile already belongs to F01' \
    "$TMP/related-finding.out" || fail "semantic candidate guard did not name F01"
"${PT[@]}" finding attach F01 --observation O0003 >/dev/null
[ "$(sqlite3 db/engagement.db \
    "SELECT COUNT(*) FROM finding WHERE lifecycle='confirmed';")" = 1 ] || \
    fail "duplicate finding reached the DB"
board="$("${PT[@]}" board)"
echo "$board" | grep -q 'occurrences=3' || fail "board should show three occurrences"
pass "semantic group_key prevents duplicate report findings"

# The references rule (>=3 links, every reference a link, >=1 from a priority
# domain) is a doctor warning fatal under --strict, so replace the canonical
# finding's placeholder references with compliant links before the checks below.
sed -i '/^## References/,$d' findings/cross-tenant-order-access.md
cat >> findings/cross-tenant-order-access.md <<'REF'
## References

- https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html
- https://portswigger.net/web-security/access-control
- https://cwe.mitre.org/data/definitions/639.html
REF

# Canonical updates repair DB, write-up, and rendered index together.
"${PT[@]}" finding update F01 --severity HIGH >/dev/null
[ "$(sqlite3 db/engagement.db 'SELECT severity FROM finding WHERE id=1;')" = HIGH ] || \
    fail "DB severity did not update"
grep -q 'Severity.*`HIGH`' findings/cross-tenant-order-access.md || \
    fail "Markdown severity did not update"
grep -q '| F01 | HIGH' engagement.md || fail "rendered severity did not update"
if ! doctor_out="$("${PT[@]}" doctor --strict 2>&1)"; then
    echo "$doctor_out" >&2
    fail "clean engagement failed strict doctor"
fi

sed -i 's/- \*\*Severity\*\*: `HIGH`/- **Severity**: `LOW`/' \
    findings/cross-tenant-order-access.md
if "${PT[@]}" doctor >"$TMP/drift.out" 2>&1; then
    fail "doctor should fail on DB/Markdown severity drift"
fi
grep -q 'Severity drift' "$TMP/drift.out" || fail "doctor did not name severity drift"
"${PT[@]}" finding update F01 --severity HIGH >/dev/null
if ! doctor_out="$("${PT[@]}" doctor --strict 2>&1)"; then
    echo "$doctor_out" >&2
    fail "ptctl update did not repair drift"
fi

sed -i 's/res-1842.http/res-unregistered.http/' \
    findings/cross-tenant-order-access.md
if "${PT[@]}" doctor >"$TMP/evidence-block.out" 2>&1; then
    fail "doctor should fail when the managed evidence block is edited"
fi
grep -q 'managed evidence block drift' "$TMP/evidence-block.out" || \
    fail "doctor did not identify evidence-block drift"
"${PT[@]}" observation evidence O0001 \
    --evidence scans/customer-portal/burp/res-1842.http >/dev/null
if ! doctor_out="$("${PT[@]}" doctor --strict 2>&1)"; then
    echo "$doctor_out" >&2
    fail "evidence re-registration did not repair the managed block"
fi
pass "doctor detects drift and canonical update repairs every projection"

# Orphan prose is never silently accepted.
cp findings/_template.md findings/orphan.md
if "${PT[@]}" doctor >"$TMP/orphan.out" 2>&1; then
    fail "doctor should reject an unmanaged finding write-up"
fi
grep -q 'orphan write-up' "$TMP/orphan.out" || fail "orphan error not reported"
rm findings/orphan.md
pass "unmanaged finding files are detected"

# Consolidation retains audit history while moving occurrences to one canonical F.
printf 'GET /api/orders/export/88 HTTP/1.1\n' \
    > scans/customer-portal/burp/req-2100.http
"${PT[@]}" observation add \
    --title 'Cross-tenant order export' \
    --family BOLA --segment customer-portal \
    --asset A1 \
    --component orders-api --boundary cross-tenant \
    --method GET --route '/api/orders/export/:id' --selector orderId \
    --source 'Burp Repeater item 2100' \
    --evidence scans/customer-portal/burp/req-2100.http >/dev/null
"${PT[@]}" finding create \
    --slug cross-tenant-order-export \
    --group-key 'orders-api|object-authorization-export|cross-tenant' \
    --title 'Cross-tenant access to exported orders' --severity MEDIUM \
    --segment customer-portal --observation O0004 --allow-related >/dev/null
"${PT[@]}" finding merge F02 --into F01 >/dev/null || fail "merge failed"

state="$(sqlite3 db/engagement.db \
    "SELECT lifecycle || ':' || canonical_finding_id FROM finding WHERE id=2;")"
[ "$state" = 'merged:1' ] || fail "source finding is not linked to canonical F01"
[ "$(sqlite3 db/engagement.db \
    'SELECT COUNT(*) FROM finding_observation WHERE finding_id=1;')" = 4 ] || \
    fail "merge did not move every occurrence"
grep -q 'F02' engagement.md && fail "merged F02 should not remain in report index"
test -f findings/cross-tenant-order-export.md || \
    fail "merged source write-up should be retained"
if ! doctor_out="$("${PT[@]}" doctor --strict 2>&1)"; then
    echo "$doctor_out" >&2
    fail "merged state violates doctor invariants"
fi
pass "merge consolidates findings without deleting audit history"

# An observation nobody has ruled on is normal session residue, not a defect:
# it must survive the reporting-freeze gate untouched.
printf 'GET /api/profile/9 HTTP/1.1\nHost: portal.example.test\n' \
    > scans/customer-portal/burp/req-2200.http
"${PT[@]}" observation add \
    --title 'Profile object reachable cross-tenant' \
    --family BOLA --segment customer-portal --asset A1 \
    --component profile-api \
    --from-http scans/customer-portal/burp/req-2200.http \
    --source 'Burp Repeater item 2200' >"$TMP/from-http.out" || \
    fail "--from-http capture failed"
grep -q 'state=proposed confidence=suspected' "$TMP/from-http.out" || \
    fail "a captured observation should start proposed and merely suspected"
[ "$(sqlite3 db/engagement.db \
    "SELECT method || ' ' || route FROM observation WHERE id=5;")" = 'GET /api/profile/:id' ] || \
    fail "--from-http did not derive the method and normalized route"
[ "$(sqlite3 db/engagement.db \
    "SELECT kind FROM evidence WHERE observation_id=5;")" = 'http-request' ] || \
    fail "--from-http did not register the request as http-request evidence"
if ! doctor_out="$("${PT[@]}" doctor --strict 2>&1)"; then
    echo "$doctor_out" >&2
    fail "--strict must not fail because the operator review queue is not empty"
fi
grep -q 'awaiting operator review' <<<"$doctor_out" || \
    fail "doctor should still surface the queue as a notice under --strict"
"${PT[@]}" inbox >"$TMP/inbox.out" || fail "inbox failed"
grep -q 'O0005' "$TMP/inbox.out" || fail "inbox omitted the queued observation"

# Dismissal is a decision and always carries its reason; the reason then comes
# back at the moment someone re-captures the same thing.
if "${PT[@]}" observation state O0005 dismissed >"$TMP/no-reason.out" 2>&1; then
    fail "an observation should not be dismissable without a reason"
fi
grep -q 'reason is required' "$TMP/no-reason.out" || \
    fail "dismissal without a reason should explain itself"
"${PT[@]}" observation state O0005 dismissed --reason 'same-tenant object, not cross-tenant' \
    --by operator >/dev/null || fail "dismissal failed"
"${PT[@]}" observation add \
    --title 'Profile object reachable cross-tenant' \
    --family BOLA --segment customer-portal --asset A1 \
    --component profile-api \
    --from-http scans/customer-portal/burp/req-2200.http \
    --source 'second session, same idea' >"$TMP/recapture.out"
grep -q 'dismissed: same-tenant object' "$TMP/recapture.out" || \
    fail "re-capturing a dismissed issue must say why it was dismissed"
if "${PT[@]}" finding create --slug dismissed-profile --group-key 'profile-api|x|y' \
    --title 'Should not promote' --severity LOW --segment customer-portal \
    --observation O0005 >"$TMP/promote-dismissed.out" 2>&1; then
    fail "a dismissed observation should not be promotable"
fi
grep -q 'was dismissed; reopen it' "$TMP/promote-dismissed.out" || \
    fail "promotion of a dismissed observation should explain the reopen path"
"${PT[@]}" observation list --state dismissed >"$TMP/list-dismissed.out"
grep -q 'same-tenant object' "$TMP/list-dismissed.out" || \
    fail "observation list must read dismissal reasons back"
"${PT[@]}" inbox --quiet >"$TMP/inbox-empty.out"
[ -s "$TMP/inbox-empty.out" ] && fail "inbox --quiet should stay silent on an empty queue"
pass "capture is cheap, dismissal carries its reason, and the queue never blocks"

# Journal observations cannot become an untracked shadow registry.
printf '## 2026-07-24\n#observation @portal cross-tenant data returned\n' \
    > journal.md
# The Stop hook reports; it never blocks, so a concurrent session is not held
# hostage by engagement-global state it did not create.
if ! printf '{}' | CLAUDE_PROJECT_DIR="$PWD" \
    bash .claude/hooks/engagement-doctor.sh >"$TMP/journal-hook.out" 2>&1; then
    cat "$TMP/journal-hook.out" >&2
    fail "Stop hook must not block on a journal observation with no O/F identity"
fi
grep -q '#observation entries without O/F reference' "$TMP/journal-hook.out" || \
    fail "Stop hook did not report the unregistered journal observation"
sed -i 's/#observation /#observation F01 /' journal.md
if ! printf '{}' | CLAUDE_PROJECT_DIR="$PWD" \
    bash .claude/hooks/engagement-doctor.sh >"$TMP/clean-hook.out" 2>&1; then
    cat "$TMP/clean-hook.out" >&2
    fail "Stop hook should stay silent-and-clean once the entry is canonical"
fi
grep -q '#observation entries without O/F reference' "$TMP/clean-hook.out" && \
    fail "Stop hook still reports a journal entry that is now canonical"

# Evidence mutation is a hard doctor error, surfaced (not enforced) at stop time
# and blocking at the reporting-freeze gate.
printf '\nmodified after capture\n' >> scans/customer-portal/burp/res-1842.http
if "${PT[@]}" doctor >"$TMP/checksum.out" 2>&1; then
    fail "doctor should fail after registered evidence changes"
fi
grep -q 'checksum drift' "$TMP/checksum.out" || fail "checksum drift not reported"
if "${PT[@]}" doctor --strict >/dev/null 2>&1; then
    fail "doctor --strict should fail on evidence checksum drift"
fi
if ! printf '{}' | CLAUDE_PROJECT_DIR="$PWD" \
    bash .claude/hooks/engagement-doctor.sh >"$TMP/hook.out" 2>&1; then
    cat "$TMP/hook.out" >&2
    fail "Stop hook must report drift without blocking the session"
fi
grep -q 'checksum drift' "$TMP/hook.out" || fail "Stop hook hid the evidence drift"
pass "immutable evidence drift is reported at stop time and blocks --strict"

echo "All finding workflow tests passed."
