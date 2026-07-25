#!/usr/bin/env bash
# Regression tests for bounded boot context, deliberate retrieval, and handoff freshness.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
NEWPT="$ROOT/org/newPT.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

cd "$TMP"
bash "$NEWPT" none engagement >/dev/null
cd engagement
PT=(python3 db/ptctl.py)

printf 'https://portal.example.test\n' > scope.txt
printf 'https://admin.example.test\n' > out-of-scope.txt
printf '%s\n' \
    '## customer-portal' \
    '- [ ] Investigate authz-topic on the orders API #manual' \
    '- [x] BIAS_SENTINEL_COMPLETED historical task' > TODO.md
printf '%s\n' \
    '## 2026-07-24' \
    '#hypothesis @portal authz-topic BIAS_SENTINEL_JOURNAL may share a tenant boundary' > journal.md

sqlite3 db/engagement.db "
  INSERT INTO segment(name, description) VALUES ('customer-portal', 'customer web portal');
  INSERT INTO host(name) VALUES ('portal.example.test');
  INSERT INTO host_ip(host_id, ip)
    VALUES ((SELECT id FROM host WHERE name='portal.example.test'), '192.0.2.10');
  INSERT INTO host_segment(host_id, segment_id)
    VALUES ((SELECT id FROM host WHERE name='portal.example.test'),
            (SELECT id FROM segment WHERE name='customer-portal'));
  INSERT INTO asset(host_id, port, protocol, tls, technologies)
    VALUES ((SELECT id FROM host WHERE name='portal.example.test'),
            443, 'https', 1, 'orders-api');"

mkdir -p scans/customer-portal/burp
printf 'GET /api/orders/100 HTTP/1.1\nEVIDENCE_BODY_SENTINEL\n' \
    > scans/customer-portal/burp/req-100.http

"${PT[@]}" observation add \
    --title 'authz-topic cross-tenant order read' \
    --family BOLA --segment customer-portal --asset A1 \
    --component orders-api --boundary cross-tenant \
    --method GET --route '/api/orders/:id' --selector orderId \
    --attacker-role customer --target-role customer \
    --source 'Burp Repeater item 100' \
    --evidence scans/customer-portal/burp/req-100.http >/dev/null
"${PT[@]}" finding create \
    --slug authz-topic-order-access \
    --group-key 'orders-api|object-authorization|cross-tenant' \
    --title 'Cross-tenant access to orders' --severity HIGH \
    --cwe CWE-639 --segment customer-portal --observation O0001 >/dev/null
printf '\nFINDING_PROSE_SENTINEL deliberately detailed prior conclusion.\n' \
    >> findings/authz-topic-order-access.md

boot="$("${PT[@]}" context boot --max-chars 16000)"
[ "${#boot}" -le 16000 ] || fail "boot exceeded its 16000-character budget"
grep -q 'portal.example.test' <<<"$boot" || fail "boot omitted compact scope"
grep -q 'Investigate authz-topic' <<<"$boot" || fail "boot omitted open task title"
grep -q 'Active findings: 1' <<<"$boot" || fail "boot omitted canonical counts"
grep -q 'BIAS_SENTINEL_COMPLETED' <<<"$boot" && fail "boot loaded completed TODO history"
grep -q 'BIAS_SENTINEL_JOURNAL' <<<"$boot" && fail "boot loaded journal prose"
grep -q 'FINDING_PROSE_SENTINEL' <<<"$boot" && fail "boot loaded finding prose"
grep -q 'EVIDENCE_BODY_SENTINEL' <<<"$boot" && fail "boot loaded an evidence body"
grep -q 'Never lose a plausible issue' <<<"$boot" && fail "Codex-style boot duplicated AGENTS.md"
pass "boot is bounded and excludes historical/prose/evidence bias"

claude_boot="$("${PT[@]}" context boot --include-rules --max-chars 16000)"
grep -q 'Never lose a plausible issue' <<<"$claude_boot" || \
    fail "Claude-style boot did not bridge hard engagement rules"
[ "${#claude_boot}" -le 16000 ] || fail "Claude-style boot exceeded its budget"

explain="$("${PT[@]}" context explain)"
grep -q 'journal.md prose' <<<"$explain" || fail "context explain did not disclose journal exclusion"
grep -q 'evidence contents' <<<"$explain" || fail "context explain did not disclose evidence exclusion"
pass "context explain makes bootstrap composition auditable"

focus="$("${PT[@]}" context focus --topic authz-topic)"
grep -q 'O0001' <<<"$focus" || fail "focus omitted matching observation pointer"
grep -q 'F01' <<<"$focus" || fail "focus omitted matching finding pointer"
grep -q 'Investigate authz-topic' <<<"$focus" || fail "focus omitted matching open task"
grep -q 'BIAS_SENTINEL_JOURNAL' <<<"$focus" && fail "focus loaded journal conclusions"
grep -q 'FINDING_PROSE_SENTINEL' <<<"$focus" && fail "focus loaded finding prose"

history="$("${PT[@]}" context history --topic authz-topic)"
grep -q 'BIAS_SENTINEL_JOURNAL' <<<"$history" || fail "explicit history did not load journal match"
grep -q 'FINDING_PROSE_SENTINEL' <<<"$history" && fail "history should not load full finding prose"

resume="$("${PT[@]}" context resume F01)"
grep -q 'FINDING_PROSE_SENTINEL' <<<"$resume" || fail "resume did not load selected finding prose"
grep -q 'req-100.http' <<<"$resume" || fail "resume omitted selected evidence registry"
grep -q 'EVIDENCE_BODY_SENTINEL' <<<"$resume" && fail "resume should not inline raw evidence bodies"
pass "focus, history, and resume progressively disclose distinct context layers"

if "${PT[@]}" session check >/dev/null 2>&1; then
    fail "handoff should be stale after engagement mutations"
fi
delta="$("${PT[@]}" session delta)"
grep -q '+ scans/customer-portal/burp/req-100.http' <<<"$delta" || \
    fail "session delta omitted newly captured evidence"
grep -q 'Capture gate: REQUIRED' <<<"$delta" || \
    fail "new scans/poc artifacts should activate the capture gate"
if "${PT[@]}" session close --focus 'authorization testing' >/dev/null 2>&1; then
    fail "session close should require an outcome when artifacts changed"
fi
"${PT[@]}" session close \
    --focus 'authorization testing on orders API' \
    --outcome captured \
    --completed 'captured O0001 and promoted F01' \
    --live-state 'Burp Repeater item 100 is the source exchange' \
    --next 'test write and delete operations' \
    --reference F01 >/dev/null
"${PT[@]}" session check >/dev/null || fail "session close did not refresh handoff"
grep -q 'EVIDENCE_BODY_SENTINEL' .context/state.json && \
    fail "session state must never contain evidence bodies"
"${PT[@]}" session start --client test --quiet
active_boot="$("${PT[@]}" context boot --max-chars 16000)"
grep -q 'Session.*active since' <<<"$active_boot" || \
    fail "boot did not surface the active capture gate"
"${PT[@]}" context focus --topic authz-topic >/dev/null
"${PT[@]}" context resume F01 >/dev/null
if "${PT[@]}" session check >/dev/null 2>&1; then
    fail "an active session should require an explicit closing outcome"
fi
if printf '{}' | CLAUDE_PROJECT_DIR="$PWD" \
    bash .claude/hooks/engagement-doctor.sh >"$TMP/active-hook.out" 2>&1; then
    fail "Stop hook should block an active session with no outcome"
fi
grep -q 'Active session has no closing outcome' "$TMP/active-hook.out" || \
    fail "Stop hook did not explain the missing session outcome"
"${PT[@]}" session close \
    --focus 'context-only orientation' \
    --outcome administrative \
    --assessment 'reviewed bounded context without executing tests' >/dev/null
"${PT[@]}" session check >/dev/null || fail "closing outcome did not clear active gate"
pass "active session lifecycle requires an outcome even without local artifacts"

sqlite3 db/engagement.db \
    "UPDATE asset SET notes='authorization target' WHERE id=1;"
delta="$("${PT[@]}" session delta)"
grep -q 'Database state: changed' <<<"$delta" || \
    fail "session delta omitted a structured database change"
if "${PT[@]}" session check >/dev/null 2>&1; then
    fail "structured database changes should stale the handoff"
fi
"${PT[@]}" session close \
    --focus 'asset inventory enrichment' \
    --completed 'marked A1 as the authorization target' \
    --next 'continue write-operation coverage' \
    --reference A1 >/dev/null
"${PT[@]}" session check >/dev/null || fail "database snapshot did not refresh"

printf 'GET /api/orders/999 returned 403\n' \
    > scans/customer-portal/burp/negative-999.txt
if "${PT[@]}" session close \
    --focus 'negative authorization test' \
    --outcome captured --reference F01 >/dev/null 2>&1; then
    fail "an old unchanged finding must not satisfy the capture gate"
fi
if "${PT[@]}" session close \
    --focus 'negative authorization test' \
    --outcome no-finding >/dev/null 2>&1; then
    fail "no-finding outcome should require an assessment"
fi
if printf '{}' | CLAUDE_PROJECT_DIR="$PWD" \
    bash .claude/hooks/engagement-doctor.sh >"$TMP/artifact-hook.out" 2>&1; then
    fail "Stop hook should block an unresolved scans/poc artifact delta"
fi
grep -q 'Capture gate: REQUIRED' "$TMP/artifact-hook.out" || \
    fail "Stop hook did not surface the capture gate"
"${PT[@]}" session close \
    --focus 'negative authorization test' \
    --outcome no-finding \
    --assessment 'order 999 remained forbidden for the cross-tenant account' \
    --completed 'tested inaccessible order 999' \
    --next 'continue write-operation coverage' >/dev/null
"${PT[@]}" session check >/dev/null || fail "no-finding assessment did not resolve gate"

touch scans/customer-portal/burp/negative-999.txt
delta="$("${PT[@]}" session delta)"
grep -q '~ scans/customer-portal/burp/negative-999.txt' <<<"$delta" && \
    fail "metadata-only timestamp changes must not count as content changes"
grep -q 'Capture gate: not required' <<<"$delta" || \
    fail "metadata-only timestamp changes should not activate the gate"

printf 'DELETE /api/orders/999 also returned 403\n' \
    >> scans/customer-portal/burp/negative-999.txt
delta="$("${PT[@]}" session delta)"
grep -q '~ scans/customer-portal/burp/negative-999.txt' <<<"$delta" || \
    fail "session delta omitted a modified artifact"
"${PT[@]}" session close \
    --focus 'negative authorization retest' \
    --outcome no-finding \
    --assessment 'read and delete operations both remained forbidden' >/dev/null

rm scans/customer-portal/burp/negative-999.txt
delta="$("${PT[@]}" session delta)"
grep -q -- '- scans/customer-portal/burp/negative-999.txt' <<<"$delta" || \
    fail "session delta omitted a deleted artifact"
"${PT[@]}" session close \
    --focus 'artifact cleanup' \
    --outcome administrative \
    --assessment 'removed temporary negative-test transcript after recording result' \
    --completed 'cleaned temporary transcript' >/dev/null
pass "capture gate tracks add/modify/delete and rejects unchanged canonical references"

printf '\n#decision authorization matrix updated\n' >> journal.md
if printf '{}' | CLAUDE_PROJECT_DIR="$PWD" \
    bash .claude/hooks/engagement-doctor.sh >"$TMP/stale-hook.out" 2>&1; then
    fail "Stop hook should block after work changed beyond the handoff"
fi
grep -q 'session handoff is stale' "$TMP/stale-hook.out" || \
    fail "Stop hook did not explain stale handoff"

"${PT[@]}" session close \
    --focus 'authorization testing on orders API' \
    --completed 'recorded authorization matrix decision' \
    --next 'test write and delete operations' \
    --reference F01 >/dev/null
if ! printf '{}' | CLAUDE_PROJECT_DIR="$PWD" \
    bash .claude/hooks/engagement-doctor.sh >"$TMP/current-hook.out" 2>&1; then
    cat "$TMP/current-hook.out" >&2
    fail "Stop hook should pass with valid registry and current handoff"
fi
pass "Stop hook enforces a current structured handoff"

echo "All context router tests passed."
