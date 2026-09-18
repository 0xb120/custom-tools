#!/usr/bin/env bash
# Regression tests for bounded boot context, deliberate retrieval, the cleanup and
# coverage registers, and concurrent-session safety.
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
grep -q 'Register everything, conclude nothing' <<<"$boot" && fail "boot duplicated AGENTS.md"
pass "boot is bounded and excludes historical/prose/evidence bias"

# Both clients discover AGENTS.md natively (Codex reads it; Claude Code
# hardcodes CLAUDE.md / AGENTS.md discovery), so no boot variant may inline it
# and the bridge flag that used to must be gone.
"${PT[@]}" context boot --include-rules >/dev/null 2>&1 && \
    fail "the removed --include-rules bridge should no longer be accepted"
# AGENTS.md is still paid once per session, natively. Keep it small.
rules_bytes="$(wc -c < AGENTS.md)"
[ "$rules_bytes" -le 11900 ] || \
    fail "AGENTS.md is $rules_bytes B; it is always-on in every session, shrink it"

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

# --- Cleanup register: the one thing no query can rediscover -----------------
"${PT[@]}" cleanup add --what 'created user pentest_tmp' --asset A1 --owner sessionA \
    >"$TMP/cleanup-add.out" || fail "cleanup add failed"
grep -q 'C01 registered (open)' "$TMP/cleanup-add.out" || fail "cleanup add did not mint C01"
"${PT[@]}" cleanup add --what 'uploaded shell.aspx' --location 'https://portal/uploads/' \
    --owner sessionB >/dev/null || fail "second cleanup add failed"

boot="$("${PT[@]}" context boot)"
grep -q 'Cleanup obligations still open' <<<"$boot" || \
    fail "boot omitted the cleanup section"
grep -q 'created user pentest_tmp' <<<"$boot" || \
    fail "boot omitted an open cleanup obligation"
grep -q 'Suggested next work' <<<"$boot" && \
    fail "boot must not carry a previous session's plan any more"
grep -q 'handoff' <<<"$boot" && fail "boot still references a handoff"

doctor_out="$("${PT[@]}" doctor 2>&1 || true)"
grep -q '2 cleanup obligation(s) still open' <<<"$doctor_out" || \
    fail "doctor did not warn about open cleanup obligations"
if "${PT[@]}" doctor --strict >/dev/null 2>&1; then
    fail "doctor --strict must fail while cleanup obligations are open"
fi
"${PT[@]}" cleanup done C01 --note 'removed, confirmed gone' >/dev/null || fail "cleanup done failed"
"${PT[@]}" cleanup list | grep -q 'C02' || fail "cleanup list lost the open obligation"
"${PT[@]}" cleanup list | grep -q 'C01' && fail "cleanup list should hide resolved rows"
"${PT[@]}" cleanup list --all | grep -q 'C01' || fail "cleanup list --all lost the resolved row"
"${PT[@]}" cleanup done C02 >/dev/null
pass "cleanup register survives sessions, blocks --strict, and reaches boot context"

# --- Attempt log: what was tried is a fact, "it is clean" is not ------------
# The ledger records attempts and refuses to record verdicts, so the note that
# describes the attempt is mandatory.
if "${PT[@]}" coverage add --asset A1 --class bola >"$TMP/coverage-no-note.out" 2>&1; then
    fail "an attempt with nothing said about it should not be recordable"
fi
grep -q 'note is required' "$TMP/coverage-no-note.out" || \
    fail "coverage add should explain that the attempt itself is the record"
"${PT[@]}" coverage add --asset A1 --class bola \
    --note 'cross-tenant write and delete both 403' >/dev/null || fail "coverage add failed"
"${PT[@]}" coverage add --asset A1 --class idor \
    --note 'alias of bola, must normalize' >/dev/null
"${PT[@]}" coverage list > "$TMP/coverage.out"
grep -q 'bola (2 attempt(s))' "$TMP/coverage.out" || \
    fail "idor should normalize onto bola and keep both attempts"
grep -q 'cross-tenant write and delete' "$TMP/coverage.out" || \
    fail "an earlier attempt must not be superseded away by a later one"
[ "$(grep -c 'A1 portal.example.test:443 bola' "$TMP/coverage.out")" -eq 1 ] || \
    fail "attempts against one target/class should group under one heading"
grep -q 'cross-tenant write and delete' <<<"$("${PT[@]}" context boot)" && \
    fail "attempt notes must not reach automatic boot context"
pass "attempt log records what was tried, normalizes classes, stays out of boot"

# --- Coverage gaps: memory that points at what nobody has touched -----------
sqlite3 db/engagement.db "
  INSERT INTO host(name) VALUES ('api.example.test');
  INSERT INTO host_segment(host_id, segment_id)
    VALUES ((SELECT id FROM host WHERE name='api.example.test'),
            (SELECT id FROM segment WHERE name='customer-portal'));
  INSERT INTO asset(host_id, port, protocol, tls, technologies)
    VALUES ((SELECT id FROM host WHERE name='api.example.test'), 8443, 'https', 1, 'internal-api');"
gaps="$("${PT[@]}" coverage gaps)"
grep -q 'api.example.test:8443' <<<"$gaps" || fail "gaps omitted the untested asset"
grep -q 'A1 ' <<<"$(sed -n '/Never tested/,/^$/p' <<<"$gaps")" && \
    fail "an asset with coverage must not be listed as never tested"
grep -q 'Assets with nothing recorded: 1' <<<"$("${PT[@]}" context boot)" || \
    fail "boot should point at untested assets without listing them"
pass "coverage gaps exposes unexplored surface instead of a backlog to close"

# --- Concurrency: two sessions must not erase or exempt each other ----------
# The removed .context/ layer failed exactly here: one global active marker and
# one global baseline meant the first session to close absorbed the other's
# artifacts and silently released its capture gate.
test -d .context && fail ".context/ session state should no longer exist"
mkdir -p scans/customer-portal/parallel
echo "session A output" > scans/customer-portal/parallel/a.txt
echo "session B output" > scans/customer-portal/parallel/b.txt
"${PT[@]}" cleanup add --what 'session A left a tunnel open' --owner sessionA >/dev/null
"${PT[@]}" coverage add --asset A1 --class xss --note 'reflected params only' \
    --owner sessionA >/dev/null
"${PT[@]}" coverage add --asset A1 --class auth --note 'no lockout bypass found' \
    --owner sessionB >/dev/null
"${PT[@]}" coverage list | grep -q 'reflected params only' || fail "session A attempt lost"
"${PT[@]}" coverage list | grep -q 'no lockout bypass found' || fail "session B attempt lost"
"${PT[@]}" cleanup list | grep -q 'session A left a tunnel open' || \
    fail "one session's cleanup obligation was lost"

# Concurrent writers converge instead of clobbering: same fingerprint, one O####.
for owner in A B; do
    "${PT[@]}" observation add \
        --title 'concurrent capture of the same issue' \
        --family BOLA --segment customer-portal --asset A1 \
        --component orders-api --boundary cross-tenant \
        --method POST --route '/api/orders' --selector orderId \
        --attacker-role customer --target-role customer \
        --source "session $owner" >/dev/null &
done
wait
observations="$(sqlite3 db/engagement.db "SELECT COUNT(*) FROM observation WHERE route='/api/orders';")"
[ "$observations" -eq 1 ] || \
    fail "concurrent identical captures should converge on one observation (got $observations)"
pass "concurrent sessions share the DB without erasing or exempting each other"

# --- Stop hook reports, never blocks ----------------------------------------
"${PT[@]}" cleanup add --what 'still open at stop time' --owner sessionA >/dev/null
printf '\n#observation unregistered entry with no canonical identity\n' >> journal.md
if ! printf '{}' | CLAUDE_PROJECT_DIR="$PWD" \
    bash .claude/hooks/engagement-doctor.sh >"$TMP/stop-hook.out" 2>&1; then
    cat "$TMP/stop-hook.out" >&2
    fail "Stop hook must not block a session on engagement-global state"
fi
grep -q 'cleanup obligation(s) still open' "$TMP/stop-hook.out" || \
    fail "Stop hook should still report open cleanup obligations"
grep -q '#observation entries without O/F/V reference' "$TMP/stop-hook.out" || \
    fail "Stop hook should still report unregistered journal observations"
pass "Stop hook reports drift on stderr without blocking a concurrent session"

# --- Boot context stays bounded and complete --------------------------------
boot="$("${PT[@]}" context boot)"
grep -q 'INCOMPLETE BOOT' <<<"$boot" && \
    fail "a DB-derived boot section no longer fits its budget and is cut silently"
grep -q 'Register everything, conclude nothing' <<<"$boot" && \
    fail "boot must not inline natively loaded AGENTS.md"
grep -q 'Sessions are independent' <<<"$boot" || \
    fail "boot policy should state that sessions run concurrently"
pass "boot stays DB-derived and complete"

echo "All context router tests passed."
