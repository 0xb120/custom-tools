# Internal hostname↔IP mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give internal-NPT engagements a stable, human-readable host identity that survives DHCP IP churn, by splitting the logical machine (`host`) from the per-port service (`asset`) and keeping an IP lease ledger (`host_ip`).

**Architecture:** New `host` table is the stable identity (`name`, provisional = IP until DNS resolves). New `host_ip` table records every IP a machine has held (`current` flags the live lease). `asset` becomes a pure per-port service referencing `host_id`; segment membership moves from `asset_segment` to `host_segment`. `whatweknow.sh` resolves a name-or-IP to the full token set (name + dns + all historical IPs) and greps every token, so scan artifacts captured under an old IP surface under the current name. Manual population, consistent with the existing DB workflow.

**Tech Stack:** SQLite (`sqlite3` CLI), Bash. Tests are Bash assertion scripts in `tests/` following the repo's existing `fail`/`pass` + `mktemp -d` convention (see `tests/test-newPT.sh`).

**Spec:** `docs/superpowers/specs/2026-06-08-internal-hostname-mapping-design.md`

---

## File structure

| File | Responsibility | Change |
|------|----------------|--------|
| `org/templates/db/schema.sql` | DB schema (source of truth) | add `host`, `host_ip`, `host_segment`; rework `asset` to `host_id`; drop `asset_segment` |
| `org/templates/db/queries/host-dossier.sql` | one-host DB view | rewrite: resolve name/IP → host_id; identity + IP history + assets + segments + creds + findings |
| `org/templates/db/queries/assets-by-segment.sql` | coverage count | join via `host_segment` |
| `org/templates/db/queries/assets-no-access.sql` | untested assets | join via `host`/`host_segment`; show name + current IP |
| `org/templates/db/queries/creds-multi-host.sql` | cred pivots | `GROUP_CONCAT` over `host.name` |
| `org/templates/db/queries/hosts.sql` | **new** name↔IP map query | create |
| `org/templates/db/queries/findings-open.sql` | open findings | **unchanged** |
| `org/templates/db/whatweknow.sh` | folded host dossier | resolve name/IP → token set; grep every token; per-token charset guard |
| `org/templates/db/render.sh` | DB → markdown | new `hosts` block; rewrite `assets` + `credentials` joins |
| `org/templates/activity.md` | rendered deliverable | add `db:render hosts` section + update asset/cred headers |
| `org/templates/AGENT.md` | operator docs | rewrite asset-tracking / DB / journal sections |
| `tests/test-db-host-mapping.sh` | **new** test suite | create, grown one section per task |

`org/newPT.sh` is **not** modified — it already copies `schema.sql`, `render.sh`, `whatweknow.sh`, and `queries/*.sql` and runs the schema; new query files ride the existing glob. Scope is new engagements only — no migration of in-flight DBs.

---

## Task 1: Schema — `host`, `host_ip`, `host_segment`; rework `asset`

**Files:**
- Modify: `org/templates/db/schema.sql`
- Test: `tests/test-db-host-mapping.sh` (create)

- [ ] **Step 1: Write the failing test**

Create `tests/test-db-host-mapping.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# Tests for the host-identity DB model (org/templates/db/). Each section builds
# a throwaway DB or scaffolds a throwaway engagement under mktemp -d so the
# working tree stays clean. Style mirrors tests/test-newPT.sh.
set -eo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SCHEMA="$ROOT/org/templates/db/schema.sql"
NEWPT="$ROOT/org/newPT.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ===========================================================================
# Section A — schema (Task 1)
# ===========================================================================
db="$TMP/a.db"
sqlite3 "$db" < "$SCHEMA" || fail "schema.sql failed to apply"

have_table() { sqlite3 "$db" ".tables" | tr ' ' '\n' | grep -qx "$1"; }
have_table host         || fail "table 'host' missing"
have_table host_ip      || fail "table 'host_ip' missing"
have_table host_segment || fail "table 'host_segment' missing"
sqlite3 "$db" ".tables" | tr ' ' '\n' | grep -qx asset_segment && \
    fail "table 'asset_segment' should be gone"
pass "host / host_ip / host_segment exist; asset_segment removed"

# asset has host_id and no longer has a host column
cols="$(sqlite3 "$db" "SELECT name FROM pragma_table_info('asset');")"
echo "$cols" | grep -qx host_id || fail "asset.host_id missing"
echo "$cols" | grep -qx host    && fail "asset.host should be removed"
pass "asset reworked to host_id"

# A host can be inserted, renamed in place, and keeps its id (stable identity)
sqlite3 "$db" "INSERT INTO host (name) VALUES ('10.0.0.5');"
hid="$(sqlite3 "$db" "SELECT id FROM host WHERE name='10.0.0.5';")"
sqlite3 "$db" "UPDATE host SET name='DC01' WHERE id=$hid;"
[ "$(sqlite3 "$db" "SELECT id FROM host WHERE name='DC01';")" = "$hid" ] || \
    fail "host id changed on rename — identity not stable"
pass "host renamed in place, identity preserved"

# host_ip ledger: one current IP per host (partial unique index)
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid, '10.0.0.5');"
if sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid, '10.0.0.9');" 2>/dev/null; then
    fail "two current IPs for one host should violate idx_host_ip_one_current"
fi
pass "at most one current IP per host enforced"

# Retiring the old lease lets a new current IP land
sqlite3 "$db" "UPDATE host_ip SET current=0 WHERE host_id=$hid AND ip='10.0.0.5';"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid, '10.0.0.9');" || \
    fail "could not record new current IP after retiring old lease"
pass "lease rotation works"

# one current owner per IP across hosts
sqlite3 "$db" "INSERT INTO host (name) VALUES ('PC02');"
hid2="$(sqlite3 "$db" "SELECT id FROM host WHERE name='PC02';")"
if sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid2, '10.0.0.9');" 2>/dev/null; then
    fail "two hosts currently owning 10.0.0.9 should violate idx_host_ip_one_owner"
fi
pass "at most one current owner per IP enforced"

echo "Section A passed."
echo "All tests passed."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-db-host-mapping.sh`
Expected: FAIL at `table 'host' missing` (schema not updated yet).

- [ ] **Step 3: Replace `org/templates/db/schema.sql` with the new model**

Replace the entire file with:

```sql
-- Engagement database. Source of truth for asset inventory, credentials,
-- and finding metadata. Markdown tables in <activity>.md are rendered from
-- this DB by db/render.sh — do not edit those tables by hand.

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ---------------------------------------------------------------------------
-- Segments (defined per engagement, see AGENT.md § Segments)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS segment (
  id          INTEGER PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  description TEXT
);

-- ---------------------------------------------------------------------------
-- Hosts: one row per logical machine — the engagement's stable identity.
-- `name` is a human-readable handle that does NOT change when DHCP reassigns
-- the IP: at first discovery it is the IP, renamed in place once the DNS /
-- NetBIOS name is known. Every IP the machine has held lives in host_ip.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS host (
  id          INTEGER PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,       -- stable speaking name; = IP until DNS resolves
  dns         TEXT,                       -- FQDN if richer than name (e.g. dc01.corp.local)
  mac         TEXT,                       -- layer-2 anchor, DHCP-immune (may be unknown off-segment)
  notes       TEXT,
  first_seen  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TRIGGER IF NOT EXISTS host_touch_last_seen
AFTER UPDATE ON host
FOR EACH ROW
WHEN NEW.last_seen = OLD.last_seen
BEGIN
  UPDATE host SET last_seen = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;

-- ---------------------------------------------------------------------------
-- IP lease ledger: every IP a host has held over time. `current=1` flags the
-- active lease. Under DHCP the same IP may later be reused by a different
-- machine, so uniqueness is per (host_id, ip) — NOT global. The partial unique
-- indexes enforce one current IP per host and one current owner per IP.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS host_ip (
  id          INTEGER PRIMARY KEY,
  host_id     INTEGER NOT NULL REFERENCES host(id) ON DELETE CASCADE,
  ip          TEXT NOT NULL,
  current     INTEGER NOT NULL DEFAULT 1 CHECK (current IN (0, 1)),
  first_seen  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (host_id, ip)                    -- a recurring IP just flips current back on
);

CREATE INDEX IF NOT EXISTS idx_host_ip_ip ON host_ip(ip);
CREATE UNIQUE INDEX IF NOT EXISTS idx_host_ip_one_current ON host_ip(host_id) WHERE current = 1;
CREATE UNIQUE INDEX IF NOT EXISTS idx_host_ip_one_owner   ON host_ip(ip)      WHERE current = 1;

-- ---------------------------------------------------------------------------
-- Assets: one row per (host, port) SERVICE. Hangs off a host (the machine).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS asset (
  id            INTEGER PRIMARY KEY,
  host_id       INTEGER NOT NULL REFERENCES host(id) ON DELETE CASCADE,
  port          INTEGER NOT NULL,
  protocol      TEXT,
  tls           INTEGER CHECK (tls IN (0, 1)),
  version       TEXT,
  technologies  TEXT,                       -- comma-separated stack fingerprint
  access        TEXT,                       -- free-form: anonymous / read-only / user / admin / rce / ...
  first_seen    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  notes         TEXT,
  UNIQUE (host_id, port)
);

CREATE INDEX IF NOT EXISTS idx_asset_host_id ON asset(host_id);
CREATE INDEX IF NOT EXISTS idx_asset_access  ON asset(access);

-- Bump last_seen on every UPDATE that doesn't explicitly set it.
CREATE TRIGGER IF NOT EXISTS asset_touch_last_seen
AFTER UPDATE ON asset
FOR EACH ROW
WHEN NEW.last_seen = OLD.last_seen
BEGIN
  UPDATE asset SET last_seen = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;

-- Segment membership is a property of the machine, not of each port.
CREATE TABLE IF NOT EXISTS host_segment (
  host_id    INTEGER NOT NULL REFERENCES host(id)    ON DELETE CASCADE,
  segment_id INTEGER NOT NULL REFERENCES segment(id) ON DELETE CASCADE,
  PRIMARY KEY (host_id, segment_id)
);

-- ---------------------------------------------------------------------------
-- Credentials: a username + secret (password/hash/token). N:M with assets
-- via credential_asset; verified_at marks the moment a combo authenticated.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS credential (
  id             INTEGER PRIMARY KEY,
  username       TEXT,
  secret         TEXT,
  secret_type    TEXT NOT NULL,             -- password / ntlm / bcrypt / kerberos / jwt / ssh-key / ...
  role           TEXT,                      -- admin / user / service / ...
  source         TEXT,                      -- cracked / leaked / sprayed / client-provided / recon
  source_path    TEXT,                      -- optional: file the cred was extracted from
  discovered_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  notes          TEXT
);

CREATE TABLE IF NOT EXISTS credential_asset (
  credential_id INTEGER NOT NULL REFERENCES credential(id) ON DELETE CASCADE,
  asset_id      INTEGER NOT NULL REFERENCES asset(id)      ON DELETE CASCADE,
  verified_at   DATETIME,                   -- when the combo authenticated
  PRIMARY KEY (credential_id, asset_id)
);

CREATE INDEX IF NOT EXISTS idx_credential_username ON credential(username);

-- ---------------------------------------------------------------------------
-- Findings: metadata only. Full prose lives in findings/<slug>.md.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS finding (
  id            INTEGER PRIMARY KEY,
  slug          TEXT NOT NULL UNIQUE,       -- matches findings/<slug>.md filename
  title         TEXT NOT NULL,
  severity      TEXT NOT NULL CHECK (severity IN ('CRITICAL','HIGH','MEDIUM','LOW','INFORMATIONAL')),
  status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','fixed','non-reproducible')),
  cwe           TEXT,                       -- 'CWE-79, CWE-89'
  segment_id    INTEGER REFERENCES segment(id),
  evidence_path TEXT,                       -- relative path to the markdown report; auto-defaults on INSERT
  poc_dir       TEXT,                       -- relative path to the evidence directory; auto-defaults on INSERT
  created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS finding_asset (
  finding_id INTEGER NOT NULL REFERENCES finding(id) ON DELETE CASCADE,
  asset_id   INTEGER NOT NULL REFERENCES asset(id)   ON DELETE CASCADE,
  PRIMARY KEY (finding_id, asset_id)
);

CREATE INDEX IF NOT EXISTS idx_finding_severity ON finding(severity);
CREATE INDEX IF NOT EXISTS idx_finding_status   ON finding(status);

-- Auto-populate evidence_path / poc_dir from slug on INSERT, but only for the
-- columns the operator didn't set explicitly (override stays intact).
CREATE TRIGGER IF NOT EXISTS finding_default_paths
AFTER INSERT ON finding
FOR EACH ROW
WHEN NEW.evidence_path IS NULL OR NEW.poc_dir IS NULL
BEGIN
  UPDATE finding
  SET evidence_path = COALESCE(NEW.evidence_path, 'findings/' || NEW.slug || '.md'),
      poc_dir       = COALESCE(NEW.poc_dir,       'poc/' || NEW.slug || '/')
  WHERE id = NEW.id;
END;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-db-host-mapping.sh`
Expected: PASS through `Section A passed.` then `All tests passed.`

- [ ] **Step 5: Commit**

```bash
git add org/templates/db/schema.sql tests/test-db-host-mapping.sh
git commit -m "feat(db): split host identity from per-port asset; add IP lease ledger"
```

---

## Task 2: Rewrite `host-dossier.sql`

**Files:**
- Modify: `org/templates/db/queries/host-dossier.sql`
- Test: `tests/test-db-host-mapping.sh` (append Section B)

- [ ] **Step 1: Write the failing test**

Append to `tests/test-db-host-mapping.sh`, **before** the final `echo "All tests passed."` line (insert above it):

```bash
# ===========================================================================
# Section B — host-dossier.sql resolves by name AND by historical IP (Task 2)
# ===========================================================================
DOSSIER="$ROOT/org/templates/db/queries/host-dossier.sql"
db="$TMP/b.db"
sqlite3 "$db" < "$SCHEMA"
sqlite3 "$db" "INSERT INTO segment (name) VALUES ('server');"
sqlite3 "$db" "INSERT INTO host (name, dns) VALUES ('DC01', 'dc01.corp.local');"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1, '10.0.0.5', 0);"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1, '10.0.0.9', 1);"
sqlite3 "$db" "INSERT INTO host_segment (host_id, segment_id) VALUES (1, 1);"
sqlite3 "$db" "INSERT INTO asset (host_id, port, protocol) VALUES (1, 445, 'smb');"

out_by_name="$(sqlite3 "$db" ".param set :host 'DC01'"      ".read $DOSSIER")"
out_by_oldip="$(sqlite3 "$db" ".param set :host '10.0.0.5'" ".read $DOSSIER")"

echo "$out_by_name"  | grep -q "dc01.corp.local" || fail "dossier-by-name should show dns"
echo "$out_by_name"  | grep -q "445"              || fail "dossier-by-name should list the smb asset"
echo "$out_by_name"  | grep -q "10.0.0.5"         || fail "dossier-by-name should show historical IP 10.0.0.5"
echo "$out_by_oldip" | grep -q "DC01"             || fail "dossier resolved by an OLD ip should still find DC01"
pass "host-dossier resolves by name and by historical IP, shows IP history + assets"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-db-host-mapping.sh`
Expected: FAIL in Section B — the current `host-dossier.sql` filters `WHERE a.host = :host` and there is no `asset.host` column, so the query errors or returns nothing.

- [ ] **Step 3: Replace `org/templates/db/queries/host-dossier.sql`**

Replace the entire file with:

```sql
-- Host dossier: everything the DB knows about one machine, resolved from its
-- stable name, its dns, OR any IP it has ever held. Bind :host before reading.
--
-- Standalone:
--   sqlite3 db/engagement.db ".param set :host 'DC01'" ".read db/queries/host-dossier.sql"
-- Or via the wrapper that also folds in journal history + raw scan hits:
--   bash db/whatweknow.sh DC01
.mode column
.headers on

-- The :host arg may be a name, a dns, or any historical IP. Every section below
-- resolves it to host id(s) with the same UNION subquery.
.print '-- identity --'
SELECT h.name,
       COALESCE(h.dns,  '') AS dns,
       COALESCE(h.mac,  '') AS mac,
       COALESCE(h.notes,'') AS notes,
       h.first_seen,
       h.last_seen
FROM host h
WHERE h.id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
);

.print ''
.print '-- ip history --'
SELECT hi.ip,
       CASE hi.current WHEN 1 THEN 'current' ELSE '' END AS state,
       hi.first_seen,
       hi.last_seen
FROM host_ip hi
WHERE hi.host_id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
)
ORDER BY hi.current DESC, hi.last_seen DESC;

.print ''
.print '-- assets --'
SELECT a.port,
       COALESCE(a.protocol, '')                                    AS protocol,
       CASE a.tls WHEN 1 THEN 'tls' WHEN 0 THEN '-' ELSE '' END     AS tls,
       COALESCE(a.version, '')                                      AS version,
       COALESCE(a.technologies, '')                                 AS technologies,
       COALESCE(a.access, '')                                       AS access,
       a.last_seen,
       COALESCE(a.notes, '')                                        AS notes
FROM asset a
WHERE a.host_id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
)
ORDER BY a.port;

.print ''
.print '-- segments --'
SELECT s.name AS segment, COALESCE(s.description, '') AS description
FROM segment s
JOIN host_segment hs ON hs.segment_id = s.id
WHERE hs.host_id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
)
ORDER BY s.name;

.print ''
.print '-- credentials --'
SELECT COALESCE(c.username, '')    AS username,
       COALESCE(c.secret, '')      AS secret,
       c.secret_type,
       COALESCE(c.role, '')        AS role,
       COALESCE(c.source, '')      AS source,
       a.port                      AS port,
       COALESCE(ca.verified_at,'') AS verified_at
FROM credential c
JOIN credential_asset ca ON ca.credential_id = c.id
JOIN asset a             ON a.id = ca.asset_id
WHERE a.host_id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
)
ORDER BY ca.verified_at, c.username;

.print ''
.print '-- findings --'
SELECT f.severity, f.status, f.slug, f.title, f.evidence_path
FROM finding f
JOIN finding_asset fa ON fa.finding_id = f.id
JOIN asset a          ON a.id = fa.asset_id
WHERE a.host_id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
)
ORDER BY CASE f.severity
            WHEN 'CRITICAL'      THEN 1
            WHEN 'HIGH'          THEN 2
            WHEN 'MEDIUM'        THEN 3
            WHEN 'LOW'           THEN 4
            WHEN 'INFORMATIONAL' THEN 5
         END, f.id;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-db-host-mapping.sh`
Expected: PASS including `host-dossier resolves by name and by historical IP...`.

- [ ] **Step 5: Commit**

```bash
git add org/templates/db/queries/host-dossier.sql tests/test-db-host-mapping.sh
git commit -m "feat(db): host-dossier resolves by name or any historical IP"
```

---

## Task 3: Update saved queries + add `hosts.sql`

**Files:**
- Modify: `org/templates/db/queries/assets-by-segment.sql`
- Modify: `org/templates/db/queries/assets-no-access.sql`
- Modify: `org/templates/db/queries/creds-multi-host.sql`
- Create: `org/templates/db/queries/hosts.sql`
- Test: `tests/test-db-host-mapping.sh` (append Section C)

- [ ] **Step 1: Write the failing test**

Append to `tests/test-db-host-mapping.sh` (above the final `echo "All tests passed."`):

```bash
# ===========================================================================
# Section C — saved queries run on the new schema (Task 3)
# ===========================================================================
QDIR="$ROOT/org/templates/db/queries"
db="$TMP/c.db"
sqlite3 "$db" < "$SCHEMA"
sqlite3 "$db" "INSERT INTO segment (name) VALUES ('server');"
sqlite3 "$db" "INSERT INTO host (name) VALUES ('DC01');"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES (1, '10.0.0.9');"
sqlite3 "$db" "INSERT INTO host_segment (host_id, segment_id) VALUES (1, 1);"
sqlite3 "$db" "INSERT INTO asset (host_id, port, protocol) VALUES (1, 445, 'smb');"
sqlite3 "$db" "INSERT INTO asset (host_id, port, protocol) VALUES (1, 3389, 'rdp');"
sqlite3 "$db" "INSERT INTO credential (username, secret, secret_type) VALUES ('admin','x','password');"
sqlite3 "$db" "INSERT INTO credential_asset (credential_id, asset_id, verified_at) VALUES (1, 1, CURRENT_TIMESTAMP);"
sqlite3 "$db" "INSERT INTO credential_asset (credential_id, asset_id, verified_at) VALUES (1, 2, CURRENT_TIMESTAMP);"

for q in assets-by-segment assets-no-access creds-multi-host findings-open hosts; do
    sqlite3 "$db" < "$QDIR/$q.sql" >/dev/null 2>"$TMP/q.err" || \
        { echo "--- $q stderr ---" >&2; cat "$TMP/q.err" >&2; fail "$q.sql failed on new schema"; }
done
pass "all saved queries run clean on the new schema"

# assets-by-segment counts the server segment's assets
sqlite3 "$db" < "$QDIR/assets-by-segment.sql" | grep -q "server" || \
    fail "assets-by-segment should report the 'server' segment"
# hosts map shows the name and its current IP
hosts_out="$(sqlite3 "$db" < "$QDIR/hosts.sql")"
echo "$hosts_out" | grep -q "DC01"     || fail "hosts.sql should list DC01"
echo "$hosts_out" | grep -q "10.0.0.9" || fail "hosts.sql should show current IP 10.0.0.9"
# creds-multi-host concatenates by host name, not by a (gone) asset.host column
sqlite3 "$db" < "$QDIR/creds-multi-host.sql" | grep -q "DC01:445" || \
    fail "creds-multi-host should group by host name (DC01:445)"
pass "queries reflect host joins (segment count, host map, cred pivots)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-db-host-mapping.sh`
Expected: FAIL in Section C — `assets-by-segment.sql` joins the removed `asset_segment`, and `hosts.sql` does not exist yet.

- [ ] **Step 3a: Replace `org/templates/db/queries/assets-by-segment.sql`**

```sql
-- Asset count per segment — coarse coverage view.
.mode column
.headers on
SELECT s.name AS segment, COUNT(*) AS n_assets
FROM asset a
JOIN host h          ON h.id = a.host_id
JOIN host_segment hs ON hs.host_id = h.id
JOIN segment s       ON s.id = hs.segment_id
GROUP BY s.name
ORDER BY n_assets DESC;
```

- [ ] **Step 3b: Replace `org/templates/db/queries/assets-no-access.sql`**

```sql
-- Assets with no recorded access yet — what's still to crack / vuln-hunt.
.mode column
.headers on
SELECT h.name AS host,
       (SELECT ip FROM host_ip WHERE host_id = h.id AND current = 1) AS current_ip,
       a.port, a.protocol, a.version,
       s.name AS segment
FROM asset a
JOIN host h           ON h.id = a.host_id
LEFT JOIN host_segment hs ON hs.host_id = h.id
LEFT JOIN segment s       ON s.id = hs.segment_id
WHERE a.access IS NULL OR a.access = ''
ORDER BY s.name, h.name, a.port;
```

- [ ] **Step 3c: Replace `org/templates/db/queries/creds-multi-host.sql`**

```sql
-- Credentials verified on more than one asset — high-value pivots.
.mode column
.headers on
SELECT c.username,
       c.secret,
       c.secret_type,
       COUNT(*) AS n_assets,
       GROUP_CONCAT(h.name || ':' || a.port, ', ') AS hosts
FROM credential c
JOIN credential_asset ca ON ca.credential_id = c.id
JOIN asset a             ON a.id = ca.asset_id
JOIN host h              ON h.id = a.host_id
WHERE ca.verified_at IS NOT NULL
GROUP BY c.id
HAVING n_assets > 1
ORDER BY n_assets DESC;
```

- [ ] **Step 3d: Create `org/templates/db/queries/hosts.sql`**

```sql
-- Host map: every machine with its current IP, the IPs it has previously held,
-- and the segment(s) it sits in. The DHCP-stable name↔IP view.
.mode column
.headers on
SELECT h.name,
       COALESCE(h.dns, '') AS dns,
       COALESCE(h.mac, '') AS mac,
       COALESCE((SELECT ip FROM host_ip WHERE host_id = h.id AND current = 1), '') AS current_ip,
       COALESCE((SELECT GROUP_CONCAT(ip, ', ') FROM host_ip WHERE host_id = h.id AND current = 0), '') AS past_ips,
       COALESCE((SELECT GROUP_CONCAT(s.name, ', ')
                 FROM host_segment hs JOIN segment s ON s.id = hs.segment_id
                 WHERE hs.host_id = h.id), '') AS segments
FROM host h
ORDER BY h.name;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-db-host-mapping.sh`
Expected: PASS including `queries reflect host joins...`. (`findings-open.sql` is intentionally not edited — it must still run, which the loop verifies.)

- [ ] **Step 5: Commit**

```bash
git add org/templates/db/queries/ tests/test-db-host-mapping.sh
git commit -m "feat(db): port saved queries to host model; add hosts map query"
```

---

## Task 4: Rewrite `whatweknow.sh` — token-set expansion

**Files:**
- Modify: `org/templates/db/whatweknow.sh`
- Test: `tests/test-db-host-mapping.sh` (append Section D)

- [ ] **Step 1: Write the failing test**

Append to `tests/test-db-host-mapping.sh` (above the final `echo "All tests passed."`):

```bash
# ===========================================================================
# Section D — whatweknow.sh folds in scans captured under an OLD IP (Task 4)
# ===========================================================================
cd "$TMP"
rm -rf eng-d
bash "$NEWPT" none eng-d >/dev/null || fail "scaffold eng-d failed"
db="eng-d/db/engagement.db"
sqlite3 "$db" "INSERT INTO host (name, dns) VALUES ('DC01', 'dc01.corp.local');"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1, '10.0.0.5', 0);"  # old DHCP lease
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1, '10.0.0.9', 1);"  # current lease
# a scan captured yesterday, labelled by the OLD ip
mkdir -p eng-d/scans/nmap
printf '10.0.0.5 445/tcp open microsoft-ds\n' > eng-d/scans/nmap/hosts.txt
# a journal entry tagged by the current name
printf '## 2026-06-08\n#observation @DC01 smb signing disabled\n' > eng-d/journal.md

out="$(bash eng-d/db/whatweknow.sh DC01)" || fail "whatweknow.sh DC01 exited non-zero"
echo "$out" | grep -q "dc01.corp.local"            || fail "dossier section missing (DB view)"
echo "$out" | grep -q "10.0.0.5"                    || fail "should surface the OLD ip from the ledger"
echo "$out" | grep -q "microsoft-ds"                || fail "should fold in the scan captured under the OLD ip"
echo "$out" | grep -q "smb signing disabled"        || fail "should fold in the @DC01 journal entry"
pass "whatweknow.sh DC01 folds DB + journal + scans across every historical IP"

# Injection guard: a bogus arg with shell/SQL metachars is rejected, not run
if bash eng-d/db/whatweknow.sh "DC01; rm -rf /" 2>/tmp/wwk.err; then
    fail "whatweknow.sh should reject an arg with invalid characters"
fi
grep -q "invalid host" /tmp/wwk.err || fail "stderr should explain the invalid-host rejection"
pass "whatweknow.sh rejects args outside the host charset"
rm -f /tmp/wwk.err
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-db-host-mapping.sh`
Expected: FAIL in Section D — the current `whatweknow.sh` only greps the single literal arg, so the scan under `10.0.0.5` is not surfaced when querying `DC01`.

- [ ] **Step 3: Replace `org/templates/db/whatweknow.sh`**

```bash
#!/bin/bash
# What do we know about a single machine? One host-centric view folded from
# every source the engagement keeps, because each holds something the others
# don't:
#
#   1. db/engagement.db  — structured truth: ports, access, creds, findings
#   2. journal.md        — chronological analysis tagged @<host> (the "why")
#   3. scans/            — raw tool output mentioning the host
#
# The argument may be the machine's stable name, its dns, OR any IP it has ever
# held. We resolve it to the machine's full token set — name + dns + every IP in
# the host_ip ledger (current and retired) — and search journal.md and scans/
# for ALL of them. That is what defeats DHCP churn: a scan captured under a now-
# retired IP still surfaces when you ask by the machine's stable name.
#
# Run from anywhere — paths resolve relative to this script's location.
#
# Usage: bash db/whatweknow.sh <name-or-ip>     e.g. bash db/whatweknow.sh DC01

set -euo pipefail

# Hostnames, dns names and IPs only ever use this charset; rejecting the rest
# closes the quote-injection hole (the value reaches SQLite's .param dot-command
# single-quoted inline, and grep) without needing to escape. Applied to the CLI
# arg AND to every token read back from the DB before it reaches grep.
valid_token() { case "$1" in *[!A-Za-z0-9.:_-]*) return 1 ;; *) return 0 ;; esac; }

host="${1:-}"
[ -n "$host" ] || { echo "Usage: $0 <name-or-ip>   (e.g. $0 DC01)" >&2; exit 1; }
valid_token "$host" || { echo "ERROR: invalid host '$host' (allowed: letters, digits, . : _ -)" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
activity_root="$(cd "$script_dir/.." && pwd)"
db="$script_dir/engagement.db"
query="$script_dir/queries/host-dossier.sql"

echo "############################################################"
echo "# Dossier: $host"
echo "############################################################"

# --- 1. DB-side view: identity / ip history / assets / segments / creds / findings
echo
echo "=== DATABASE ==="
if [ -f "$db" ] && [ -f "$query" ]; then
    sqlite3 "$db" ".param set :host '$host'" ".read $query"
else
    echo "(missing $db or $query — skipping)"
fi

# --- Build the token set: name + dns + every IP this machine has held. --------
# Resolve $host (name, dns, or any ip) to its host id(s), then collect all the
# strings that identify the same machine. Always include the literal arg so an
# unknown host still searches for what the operator typed.
tokens="$host"
if [ -f "$db" ]; then
    db_tokens="$(sqlite3 "$db" "
        WITH ids AS (
            SELECT id      FROM host    WHERE name = '$host' OR dns = '$host'
            UNION
            SELECT host_id FROM host_ip WHERE ip = '$host'
        )
        SELECT name FROM host    WHERE id      IN (SELECT id FROM ids)
        UNION
        SELECT dns  FROM host    WHERE id      IN (SELECT id FROM ids) AND dns IS NOT NULL AND dns <> ''
        UNION
        SELECT ip   FROM host_ip WHERE host_id IN (SELECT id FROM ids);
    " 2>/dev/null || true)"
    tokens="$tokens"$'\n'"$db_tokens"
fi
# Dedupe + drop blanks + drop anything failing the charset guard.
search_tokens="$(printf '%s\n' "$tokens" | sort -u | while IFS= read -r t; do
    [ -n "$t" ] || continue
    if valid_token "$t"; then printf '%s\n' "$t"; else echo "  (skipping invalid token '$t')" >&2; fi
done)"

# --- 2. Journal history: entries tagged @<token> for every token --------------
echo
echo "=== JOURNAL (@$host and aliases) ==="
if [ -f "$activity_root/journal.md" ]; then
    found=0
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        hits="$(grep -n -F "@$t" "$activity_root/journal.md" || true)"
        if [ -n "$hits" ]; then echo "--- @$t"; printf '%s\n' "$hits"; found=1; fi
    done <<< "$search_tokens"
    [ "$found" = 1 ] || echo "(no journal entries for $host or its aliases)"
else
    echo "(no journal.md)"
fi

# --- 3. Raw scan artifacts mentioning ANY token -------------------------------
# List which files name a token, then a bounded preview of the matching lines
# (capped per file so a huge dump can't bury the rest of the dossier).
echo
echo "=== RAW SCANS (scans/ mentioning $host or its IPs) ==="
if [ -d "$activity_root/scans" ]; then
    # Collect matching files across all tokens, dedupe.
    matches=""
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        m="$(grep -rIlF "$t" "$activity_root/scans" 2>/dev/null || true)"
        [ -n "$m" ] && matches="$matches"$'\n'"$m"
    done <<< "$search_tokens"
    matches="$(printf '%s\n' "$matches" | sed '/^$/d' | sort -u)"
    if [ -n "$matches" ]; then
        printf '%s\n' "$matches" | while IFS= read -r f; do
            echo "--- ${f#"$activity_root"/}"
            # show lines matching any token in this file
            grep -nE "$(printf '%s\n' "$search_tokens" | sed '/^$/d' | paste -sd'|' -)" "$f" | head -n 20
        done
    else
        echo "(no scans/ files mention $host or its IPs)"
    fi
else
    echo "(no scans/ dir)"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-db-host-mapping.sh`
Expected: PASS including `whatweknow.sh DC01 folds DB + journal + scans...` and the injection-guard assertion.

- [ ] **Step 5: Commit**

```bash
git add org/templates/db/whatweknow.sh tests/test-db-host-mapping.sh
git commit -m "feat(db): whatweknow expands name/IP to full token set, defeating DHCP churn"
```

---

## Task 5: Rewrite `render.sh` + add the `hosts` render block to `activity.md`

**Files:**
- Modify: `org/templates/db/render.sh`
- Modify: `org/templates/activity.md`
- Test: `tests/test-db-host-mapping.sh` (append Section E)

- [ ] **Step 1: Write the failing test**

Append to `tests/test-db-host-mapping.sh` (above the final `echo "All tests passed."`):

```bash
# ===========================================================================
# Section E — render.sh emits the hosts map + host-keyed asset/cred tables (Task 5)
# ===========================================================================
cd "$TMP"
rm -rf eng-e
bash "$NEWPT" none eng-e >/dev/null || fail "scaffold eng-e failed"
db="eng-e/db/engagement.db"
sqlite3 "$db" "INSERT INTO segment (name) VALUES ('server');"
sqlite3 "$db" "INSERT INTO host (name, dns) VALUES ('DC01','dc01.corp.local');"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1,'10.0.0.5',0);"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1,'10.0.0.9',1);"
sqlite3 "$db" "INSERT INTO host_segment (host_id, segment_id) VALUES (1,1);"
sqlite3 "$db" "INSERT INTO asset (host_id, port, protocol) VALUES (1,445,'smb');"
sqlite3 "$db" "INSERT INTO credential (username, secret, secret_type) VALUES ('admin','x','password');"
sqlite3 "$db" "INSERT INTO credential_asset (credential_id, asset_id, verified_at) VALUES (1,1,CURRENT_TIMESTAMP);"

bash eng-e/db/render.sh >/dev/null || fail "render.sh failed"
md="eng-e/eng-e.md"
# hosts map block rendered with name, current + past IP
awk '/<!-- db:render hosts -->/{f=1} f; /<!-- \/db:render hosts -->/{f=0}' "$md" > "$TMP/hosts.block"
grep -q "DC01"     "$TMP/hosts.block" || fail "hosts block should list DC01"
grep -q "10.0.0.9" "$TMP/hosts.block" || fail "hosts block should show current IP"
grep -q "10.0.0.5" "$TMP/hosts.block" || fail "hosts block should show past IP"
# assets block keyed by host name + current IP
awk '/<!-- db:render assets -->/{f=1} f; /<!-- \/db:render assets -->/{f=0}' "$md" > "$TMP/assets.block"
grep -q "DC01" "$TMP/assets.block" || fail "assets block should show host name DC01"
grep -q "445"  "$TMP/assets.block" || fail "assets block should list port 445"
pass "render.sh emits hosts map + host-keyed asset table"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-db-host-mapping.sh`
Expected: FAIL in Section E — `activity.md` has no `db:render hosts` markers and `render.sh` joins the removed `asset_segment`.

- [ ] **Step 3a: Replace the three rendered-block builders in `org/templates/db/render.sh`**

Replace the `assets_md` builder block (the segment loop, currently lines ~47-73) with this, and **insert a new `hosts_md` builder immediately before it**:

```bash
hosts_md="$tmpdir/hosts.md"
echo "" > "$hosts_md"
sqlite3 "$db" -markdown <<'SQL' >> "$hosts_md"
SELECT h.name AS "name",
       COALESCE(h.dns, '') AS "dns",
       COALESCE(h.mac, '') AS "mac",
       COALESCE((SELECT ip FROM host_ip WHERE host_id = h.id AND current = 1), '') AS "current ip",
       COALESCE((SELECT GROUP_CONCAT(ip, ', ') FROM host_ip WHERE host_id = h.id AND current = 0), '') AS "past ips",
       COALESCE((SELECT GROUP_CONCAT(s.name, ', ')
                 FROM host_segment hs JOIN segment s ON s.id = hs.segment_id
                 WHERE hs.host_id = h.id), '') AS "segment"
FROM host h
ORDER BY h.name;
SQL
echo "" >> "$hosts_md"
[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM host;")" -gt 0 ] || \
    printf '\n_No hosts recorded yet — see AGENT.md § Engagement database for write snippets._\n' > "$hosts_md"

assets_md="$tmpdir/assets.md"
: > "$assets_md"
# One sub-table per segment that has at least one asset (via host_segment).
sqlite3 "$db" "SELECT name FROM segment WHERE id IN (SELECT segment_id FROM host_segment) ORDER BY name;" |
while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    {
        echo ""
        echo "### $seg"
        echo ""
        sqlite3 "$db" -markdown <<SQL
SELECT h.name AS "name",
       COALESCE((SELECT ip FROM host_ip WHERE host_id = h.id AND current = 1), '') AS "current ip",
       a.port AS port,
       COALESCE(a.protocol, '') AS protocol,
       CASE a.tls WHEN 1 THEN 'True' WHEN 0 THEN 'False' ELSE '' END AS tls,
       COALESCE(a.version, '') AS version,
       COALESCE(a.technologies, '') AS technologies,
       COALESCE(a.access, '') AS access
FROM asset a
JOIN host h          ON h.id = a.host_id
JOIN host_segment hs ON hs.host_id = h.id
JOIN segment s       ON s.id = hs.segment_id
WHERE s.name = '$seg'
ORDER BY h.name, a.port;
SQL
    } >> "$assets_md"
done
[ -s "$assets_md" ] || echo $'\n_No assets recorded yet — see AGENT.md § Engagement database for write snippets._' > "$assets_md"
```

- [ ] **Step 3b: Replace the `credentials_md` builder in `org/templates/db/render.sh`**

Replace the existing `credentials_md` heredoc block with:

```bash
credentials_md="$tmpdir/credentials.md"
echo "" > "$credentials_md"
sqlite3 "$db" -markdown <<'SQL' >> "$credentials_md"
SELECT COALESCE(c.username, '') AS Username,
       COALESCE(c.secret, '')   AS "Password / Hash",
       COALESCE(h.name, '')     AS Host,
       COALESCE((SELECT ip FROM host_ip WHERE host_id = h.id AND current = 1), '') AS "Current IP",
       COALESCE(a.port, '')     AS Port,
       COALESCE(c.role, '')     AS Role
FROM credential c
LEFT JOIN credential_asset ca ON ca.credential_id = c.id
LEFT JOIN asset a              ON a.id = ca.asset_id
LEFT JOIN host h               ON h.id = a.host_id
ORDER BY c.username, h.name, a.port;
SQL
echo "" >> "$credentials_md"
```

- [ ] **Step 3c: Register the new `hosts` block in the splice section of `org/templates/db/render.sh`**

Find the three `replace_block` calls near the end and add the `hosts` line first:

```bash
replace_block hosts       "$hosts_md"       "$activity_md"
replace_block assets      "$assets_md"      "$activity_md"
replace_block credentials "$credentials_md" "$activity_md"
replace_block findings    "$findings_md"    "$activity_md"
```

- [ ] **Step 3d: Add the `hosts` section + update headers in `org/templates/activity.md`**

Insert a new section immediately before `## Asset inventory`:

```markdown
## Host inventory

Source of truth: `db/engagement.db` (`host` + `host_ip` + `host_segment`). The DHCP-stable name↔IP map — rendered by `bash db/render.sh`. See `AGENT.md` § Engagement database.

<!-- db:render hosts -->

| name | dns | mac | current ip | past ips | segment |
| ---- | --- | --- | ---------- | -------- | ------- |
|      |     |     |            |          |         |

<!-- /db:render hosts -->
```

Then update the `## Asset inventory` source-of-truth line and the asset table header, and the credentials header, so the static (pre-render) view matches the new columns:

Replace:
```markdown
Source of truth: `db/engagement.db` (`asset` + `asset_segment`). Rendered by `bash db/render.sh` — see `AGENT.md` § Engagement database for write/read snippets.

<!-- db:render assets -->

### <segment>

| ip / hostname | port | protocol | tls | version | technologies | access |
| ------------- | ---- | -------- | --- | ------- | ------------ | ------ |
|               |      |          |     |         |              |        |
```
with:
```markdown
Source of truth: `db/engagement.db` (`asset` + `host` + `host_segment`). Rendered by `bash db/render.sh` — see `AGENT.md` § Engagement database for write/read snippets.

<!-- db:render assets -->

### <segment>

| name | current ip | port | protocol | tls | version | technologies | access |
| ---- | ---------- | ---- | -------- | --- | ------- | ------------ | ------ |
|      |            |      |          |     |         |              |        |
```

Replace the credentials header:
```markdown
| Username | Password / Hash | IP / Hostname | Port | Role |
| -------- | --------------- | ------------- | ---- | ---- |
|          |                 |               |      |      |
```
with:
```markdown
| Username | Password / Hash | Host | Current IP | Port | Role |
| -------- | --------------- | ---- | ---------- | ---- | ---- |
|          |                 |      |            |      |      |
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-db-host-mapping.sh`
Expected: PASS including `render.sh emits hosts map + host-keyed asset table`.

- [ ] **Step 5: Run the existing newPT suite to confirm no regression**

Run: `bash tests/test-newPT.sh`
Expected: `All tests passed.` (Test 8 still renders `<activity>.md` by marker — the new `hosts` block must not break it.)

- [ ] **Step 6: Commit**

```bash
git add org/templates/db/render.sh org/templates/activity.md tests/test-db-host-mapping.sh
git commit -m "feat(db): render name↔IP host map and key asset/cred tables by host"
```

---

## Task 6: Update `AGENT.md` operator documentation

**Files:**
- Modify: `org/templates/AGENT.md`
- Test: `tests/test-db-host-mapping.sh` (append Section F — a doc-freshness guard)

This task has no runtime behavior, so the "test" is a guard that the docs no longer reference the removed schema and do describe the new flow.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-db-host-mapping.sh` (above the final `echo "All tests passed."`):

```bash
# ===========================================================================
# Section F — AGENT.md docs describe the host model, not the dropped one (Task 6)
# ===========================================================================
AGENT="$ROOT/org/templates/AGENT.md"
grep -q "asset_segment" "$AGENT" && fail "AGENT.md still references the removed asset_segment table"
grep -qE "INSERT INTO host\b"     "$AGENT" || fail "AGENT.md should document INSERT INTO host"
grep -q "host_ip"                  "$AGENT" || fail "AGENT.md should document the host_ip ledger"
grep -q "host_segment"             "$AGENT" || fail "AGENT.md should document host_segment"
grep -q "whatweknow.sh"            "$AGENT" || fail "AGENT.md should keep the whatweknow.sh reference"
pass "AGENT.md documents the host-identity model"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-db-host-mapping.sh`
Expected: FAIL in Section F — `AGENT.md` still says `asset_segment` and has no `INSERT INTO host`.

- [ ] **Step 3: Edit `org/templates/AGENT.md`**

Make these edits (keep the file's terse, rules-over-examples tone — see memory `feedback_template_terseness`):

1. **"What lives where" table** (around line 206): change the Asset inventory row source-of-truth from `DB (asset, asset_segment)` to `DB (host, host_ip, asset, host_segment)`, and add a new first data row:
   `| Host map (name↔IP) | DB (host, host_ip, host_segment) | <activity_name>.md § Host inventory |`

2. **"Common writes" block** (around lines 215-239): replace the `-- Define segments` + `-- Add an asset` snippets with the host-first flow. Use exactly:

```bash
# Define segments first — needed before hosts/findings can reference them.
sqlite3 db/engagement.db "INSERT INTO segment (name, description) VALUES
  ('server', 'on-prem servers'),
  ('pc',     'workstations');"

# Register a machine. At IP-first discovery the name IS the IP; rename it in
# place once DNS/NetBIOS resolves (the host id — the stable identity — is kept).
sqlite3 db/engagement.db "INSERT INTO host (name) VALUES ('10.0.0.5');"
sqlite3 db/engagement.db "INSERT INTO host_ip (host_id, ip) VALUES (last_insert_rowid(), '10.0.0.5');"
sqlite3 db/engagement.db "UPDATE host SET name='DC01', dns='dc01.corp.local', mac='00:11:22:33:44:55'
  WHERE name='10.0.0.5';"
sqlite3 db/engagement.db "INSERT INTO host_segment (host_id, segment_id)
  VALUES ((SELECT id FROM host WHERE name='DC01'), (SELECT id FROM segment WHERE name='server'));"

# DHCP moved the machine: retire the old lease, record the new current IP.
sqlite3 db/engagement.db "UPDATE host_ip SET current=0 WHERE ip='10.0.0.5' AND current=1;"
sqlite3 db/engagement.db "INSERT INTO host_ip (host_id, ip)
  VALUES ((SELECT id FROM host WHERE name='DC01'), '10.0.0.9')
  ON CONFLICT(host_id, ip) DO UPDATE SET current=1, last_seen=CURRENT_TIMESTAMP;"

# Add a service (asset) on that machine.
sqlite3 db/engagement.db "INSERT INTO asset
  (host_id, port, protocol, tls, version, technologies)
  VALUES ((SELECT id FROM host WHERE name='DC01'), 445, 'smb', 0, 'Windows Server 2019', 'smb');"
```

   And in the credential snippet, change the `credential_asset` sub-select and the `UPDATE asset` from `WHERE host='10.0.0.5' AND port=443` to:
   `WHERE host_id=(SELECT id FROM host WHERE name='DC01') AND port=445`.

3. **"Common reads" table** (around line 262): add a row
   `| hosts.sql | The name↔IP host map (current + past IPs, segments) |`
   and update the `host-dossier.sql` row description to "Everything the DB knows about one machine — bind `:host` to a name or any IP it has held".

4. **§ Asset tracking** (around lines 274-286): replace the `host` column-semantics bullet:
   - Remove: "`host` — IP for external/internal, hostname for web. Pick the canonical form per segment."
   - Add a short paragraph: a service row (`asset`) hangs off a machine (`host`) via `host_id`; the machine's `name` is the stable identity (provisional = IP, renamed on DNS resolution); IPs the machine has held live in `host_ip` (`current=1` = live lease); segment membership is on the machine (`host_segment`), inherited by all its services. Note `UNIQUE(host_id, port)` replaces `UNIQUE(host, port)`.

5. **§ Working journal** (around line 331): change the host-tag guidance to "Tag the machine an entry concerns with `@<name>` — the stable host name (fall back to `@<ip>` only when the name isn't known yet; `whatweknow.sh` expands either to the full alias set)."

6. **whatweknow description** (around line 270): update to "folds the DB dossier, journal entries, and raw `scans/` output for the machine's full token set — its name, dns, and every IP it has ever held — so a scan captured under a now-retired DHCP IP still surfaces when you query by the stable name."

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-db-host-mapping.sh`
Expected: `All tests passed.` (all sections A–F green).

- [ ] **Step 5: Commit**

```bash
git add org/templates/AGENT.md tests/test-db-host-mapping.sh
git commit -m "docs(agent): document host-identity model and DHCP-stable workflow"
```

---

## Final verification

- [ ] **Run both suites:**

Run: `bash tests/test-db-host-mapping.sh && bash tests/test-newPT.sh`
Expected: both print `All tests passed.`

- [ ] **End-to-end smoke (manual):**

```bash
cd "$(mktemp -d)"
bash /opt/custom-tools/org/newPT.sh internal smoke-internal >/dev/null
cd smoke-internal
sqlite3 db/engagement.db "INSERT INTO segment (name) VALUES ('server');"
sqlite3 db/engagement.db "INSERT INTO host (name) VALUES ('10.0.0.5');"
sqlite3 db/engagement.db "INSERT INTO host_ip (host_id, ip) VALUES (1,'10.0.0.5');"
sqlite3 db/engagement.db "UPDATE host SET name='DC01' WHERE name='10.0.0.5';"
sqlite3 db/engagement.db "INSERT INTO host_segment VALUES (1,1);"
sqlite3 db/engagement.db "INSERT INTO asset (host_id,port,protocol) VALUES (1,445,'smb');"
bash db/render.sh                 # → Host inventory + Asset inventory tables populated
bash db/whatweknow.sh DC01        # → DB dossier + (empty) journal/scans sections
```
Expected: `render.sh` reports `Rendered .../smoke-internal.md`; the `## Host inventory` table shows `DC01 | | | 10.0.0.5 | | server`; `whatweknow.sh DC01` prints the identity/ip-history/assets sections.

- [ ] **Update the root `CLAUDE.md` pipeline note only if needed:** the recon pipeline section does not reference `engagement.db`, so no change is expected — confirm with `grep -n "engagement.db\|asset_segment" CLAUDE.md` (expected: no matches).
