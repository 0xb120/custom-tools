#!/usr/bin/env bash
# Migration of a live engagement DB onto the decision-based registry vocabulary.
#
# Engagements already exist on the seven-state observation lifecycle and the
# three-verdict coverage ledger, so `ptctl.py` has to carry them across without
# losing a row, a reason, or a foreign key. The rules it applies:
#
#   new/validating/confirmed/inconclusive -> proposed  (nobody had ruled on them)
#   linked                                -> accepted
#   rejected/duplicate                    -> dismissed (reason preserved)
#   coverage.verdict                      -> folded into the mandatory note
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
NEWPT="$ROOT/org/newPT.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
q() { sqlite3 db/engagement.db "$1"; }

cd "$TMP"
bash "$NEWPT" none engagement >/dev/null
cd engagement
PT=(python3 db/ptctl.py)

sqlite3 db/engagement.db "
  INSERT INTO segment(name) VALUES ('web');
  INSERT INTO host(name) VALUES ('app.example.test');
  INSERT INTO host_segment(host_id, segment_id) VALUES (1, 1);
  INSERT INTO asset(host_id, port, protocol) VALUES (1, 443, 'https');"

mkdir -p scans/web
printf 'GET /api/orders/1 HTTP/1.1\nHost: app.example.test\n' > scans/web/req.http

# A real finding, created the normal way, so the migration runs against a DB
# with live finding_observation and evidence rows hanging off the table.
"${PT[@]}" observation add --title 'Cross-tenant order read' --family BOLA \
    --segment web --asset A1 --component orders-api --boundary cross-tenant \
    --from-http scans/web/req.http >/dev/null
"${PT[@]}" finding create --slug cross-tenant-orders \
    --group-key 'orders-api|object-authorization|cross-tenant' \
    --title 'Cross-tenant access to orders' --severity HIGH \
    --segment web --observation O0001 >/dev/null

# --- Roll the engagement back onto the legacy schema -------------------------
sqlite3 db/engagement.db <<'SQL'
PRAGMA foreign_keys=OFF;
BEGIN;
CREATE TABLE observation_legacy (
  id             INTEGER PRIMARY KEY,
  fingerprint    TEXT NOT NULL UNIQUE,
  state          TEXT NOT NULL DEFAULT 'new'
                   CHECK (state IN ('new','validating','confirmed','linked',
                                    'rejected','inconclusive','duplicate')),
  family         TEXT NOT NULL,
  title          TEXT NOT NULL,
  segment_id     INTEGER NOT NULL REFERENCES segment(id),
  asset_id       INTEGER REFERENCES asset(id),
  component      TEXT,
  boundary       TEXT,
  method         TEXT,
  route          TEXT,
  selector       TEXT,
  attacker_role  TEXT,
  target_role    TEXT,
  source         TEXT,
  notes          TEXT,
  disposition    TEXT,
  discovered_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO observation_legacy
  (id, fingerprint, state, family, title, segment_id, asset_id, component,
   boundary, method, route, selector, attacker_role, target_role, source,
   notes, disposition, discovered_at, updated_at)
SELECT id, fingerprint, 'linked', family, title, segment_id, asset_id,
       component, boundary, method, route, selector, attacker_role,
       target_role, source, notes, disposition, discovered_at, updated_at
FROM observation;
DROP TABLE observation;
ALTER TABLE observation_legacy RENAME TO observation;

INSERT INTO observation (fingerprint, state, family, title, segment_id, asset_id, component, notes)
  VALUES ('fp-new', 'new', 'xss', 'Reflected parameter', 1, 1, 'search', NULL);
INSERT INTO observation (fingerprint, state, family, title, segment_id, asset_id, component)
  VALUES ('fp-validating', 'validating', 'xss', 'Maybe stored', 1, 1, 'profile');
INSERT INTO observation (fingerprint, state, family, title, segment_id, asset_id, component)
  VALUES ('fp-confirmed', 'confirmed', 'auth', 'Session fixation', 1, 1, 'login');
INSERT INTO observation (fingerprint, state, family, title, segment_id, asset_id, component, notes, disposition)
  VALUES ('fp-inconclusive', 'inconclusive', 'ssrf', 'Blind callback', 1, 1, 'webhook',
          'tried 3 payloads', 'no out-of-band channel available');
INSERT INTO observation (fingerprint, state, family, title, segment_id, asset_id, component, disposition)
  VALUES ('fp-rejected', 'rejected', 'xss', 'Scanner noise', 1, 1, 'assets',
          'scanner false positive, output is html-encoded');
INSERT INTO observation (fingerprint, state, family, title, segment_id, asset_id, component)
  VALUES ('fp-duplicate', 'duplicate', 'bola', 'Same as O0001', 1, 1, 'orders-api');

CREATE TABLE coverage_legacy (
  id          INTEGER PRIMARY KEY,
  asset_id    INTEGER REFERENCES asset(id) ON DELETE CASCADE,
  segment_id  INTEGER REFERENCES segment(id) ON DELETE SET NULL,
  test_class  TEXT NOT NULL,
  verdict     TEXT NOT NULL CHECK (verdict IN ('negative','partial','positive')),
  note        TEXT,
  owner       TEXT,
  recorded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (asset_id IS NOT NULL OR segment_id IS NOT NULL)
);
DROP TABLE coverage;
ALTER TABLE coverage_legacy RENAME TO coverage;
INSERT INTO coverage (asset_id, segment_id, test_class, verdict, note, owner)
  VALUES (1, 1, 'bola', 'negative', 'cross-tenant read/write/delete all 403', 'sessionA');
INSERT INTO coverage (asset_id, segment_id, test_class, verdict, note)
  VALUES (1, 1, 'xss', 'partial', NULL);
COMMIT;
PRAGMA foreign_keys=ON;
SQL

[ "$(q "SELECT COUNT(*) FROM pragma_table_info('coverage') WHERE name='verdict';")" = 1 ] || \
    fail "test setup did not restore the legacy coverage schema"

# --- Any ptctl invocation migrates in place ----------------------------------
"${PT[@]}" observation list >"$TMP/list.out" 2>&1 || {
    cat "$TMP/list.out" >&2; fail "ptctl failed against a legacy engagement DB"; }

[ "$(q "SELECT COUNT(*) FROM observation;")" = 7 ] || fail "migration lost an observation"
[ "$(q "SELECT state FROM observation WHERE fingerprint='fp-new';")" = proposed ] || \
    fail "state=new should become proposed"
[ "$(q "SELECT state FROM observation WHERE fingerprint='fp-validating';")" = proposed ] || \
    fail "state=validating should become proposed"
[ "$(q "SELECT state || '/' || confidence FROM observation WHERE fingerprint='fp-confirmed';")" \
    = 'proposed/reproduced' ] || \
    fail "an agent-confirmed observation should stay queued but keep that it was reproduced"
[ "$(q "SELECT state FROM observation WHERE fingerprint='fp-inconclusive';")" = proposed ] || \
    fail "inconclusive was never a decision and should return to the queue"
[ "$(q "SELECT state FROM observation WHERE fingerprint='fp-rejected';")" = dismissed ] || \
    fail "state=rejected should become dismissed"
[ "$(q "SELECT state FROM observation WHERE fingerprint='fp-duplicate';")" = dismissed ] || \
    fail "state=duplicate should become dismissed"
[ "$(q "SELECT state || '/' || confidence FROM observation WHERE id=1;")" = 'accepted/reproduced' ] || \
    fail "a linked observation should become accepted"
pass "the seven-state lifecycle collapses onto proposed/accepted/dismissed"

# Reasons survive: a dismissal keeps its own, an attempt note is not mistaken
# for one, and a duplicate that never had a reason gets a traceable placeholder.
q "SELECT disposition FROM observation WHERE fingerprint='fp-rejected';" \
    | grep -q 'html-encoded' || fail "a rejection reason was lost"
q "SELECT notes FROM observation WHERE fingerprint='fp-inconclusive';" \
    | grep -q 'previously inconclusive: no out-of-band channel' || \
    fail "an inconclusive reason should survive as a note on the queued row"
[ "$(q "SELECT disposition IS NULL FROM observation WHERE fingerprint='fp-inconclusive';")" = 1 ] || \
    fail "a queued observation must not carry a dismissal reason"
q "SELECT disposition FROM observation WHERE fingerprint='fp-duplicate';" \
    | grep -q 'migrated from state=duplicate' || \
    fail "a reasonless dismissal should be traceable to the migration"
pass "every recorded reason survives the vocabulary change"

# The rebuild must not orphan anything hanging off the observation table.
[ "$(q "SELECT COUNT(*) FROM evidence WHERE observation_id=1;")" = 1 ] || \
    fail "migration dropped registered evidence"
[ "$(q "SELECT COUNT(*) FROM finding_observation WHERE observation_id=1;")" = 1 ] || \
    fail "migration dropped the canonical finding link"
[ -z "$(q 'PRAGMA foreign_key_check;')" ] || fail "migration left a foreign key violation"
[ "$(q "SELECT COUNT(*) FROM pragma_table_info('coverage') WHERE name='verdict';")" = 0 ] || \
    fail "the verdict column should be gone"
[ "$(q "SELECT COUNT(*) FROM coverage;")" = 2 ] || fail "migration lost an attempt"
q "SELECT note FROM coverage WHERE test_class='bola';" | grep -q 'was verdict=negative' || \
    fail "the old verdict should survive inside the note"
q "SELECT note FROM coverage WHERE test_class='xss';" | grep -q 'verdict=partial' || \
    fail "a verdict-only row should keep its verdict as its note"
pass "foreign keys, evidence and the old verdicts all survive the rebuild"

# Migration is idempotent and the workspace is usable straight afterwards.
before="$(q 'SELECT COUNT(*) FROM observation;')"
"${PT[@]}" inbox >"$TMP/inbox.out" || fail "inbox failed after migration"
[ "$(q 'SELECT COUNT(*) FROM observation;')" = "$before" ] || \
    fail "a second ptctl run re-migrated the table"
grep -q 'awaiting a decision' "$TMP/inbox.out" || fail "inbox did not render"
[ "$(grep -c 'O000' "$TMP/inbox.out")" = 4 ] || \
    fail "the four never-decided observations should be the operator's queue"
"${PT[@]}" coverage add --asset A1 --class auth --note 'post-migration write' >/dev/null || \
    fail "the migrated coverage table does not accept new attempts"
if ! doctor_out="$("${PT[@]}" doctor 2>&1)"; then
    echo "$doctor_out" >&2
    fail "doctor should not error on a freshly migrated engagement"
fi
grep -q '4 observation(s) awaiting operator review' <<<"$doctor_out" || \
    fail "doctor should report the migrated queue as a notice"
pass "migration is idempotent and leaves a working engagement"

echo "All registry migration tests passed."
