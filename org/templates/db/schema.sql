-- Engagement database. Source of truth for assets, credentials, observations,
-- evidence metadata, and finding metadata. Markdown projections are rendered
-- from this DB — do not edit those tables or managed blocks by hand.

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ---------------------------------------------------------------------------
-- Segments (defined per engagement, see AGENTS.md § Segments)
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
  id                   INTEGER PRIMARY KEY,
  slug                 TEXT NOT NULL UNIQUE,       -- matches findings/<slug>.md filename
  group_key            TEXT NOT NULL,              -- semantic identity: component|control|boundary|root-cause
  title                TEXT NOT NULL,
  severity             TEXT NOT NULL CHECK (severity IN ('CRITICAL','HIGH','MEDIUM','LOW','INFORMATIONAL')),
  status               TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','fixed','non-reproducible')),
  lifecycle            TEXT NOT NULL DEFAULT 'confirmed'
                         CHECK (lifecycle IN ('draft','confirmed','merged','rejected')),
  canonical_finding_id INTEGER REFERENCES finding(id), -- populated when lifecycle=merged
  cwe                  TEXT,                       -- 'CWE-79, CWE-89'
  segment_id           INTEGER NOT NULL REFERENCES segment(id),
  evidence_path        TEXT,                       -- relative path to the markdown report; auto-defaults on INSERT
  poc_dir              TEXT,                       -- relative path to the evidence directory; auto-defaults on INSERT
  created_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (
    (lifecycle = 'merged' AND canonical_finding_id IS NOT NULL)
    OR
    (lifecycle <> 'merged' AND canonical_finding_id IS NULL)
  )
);

CREATE TABLE IF NOT EXISTS finding_asset (
  finding_id INTEGER NOT NULL REFERENCES finding(id) ON DELETE CASCADE,
  asset_id   INTEGER NOT NULL REFERENCES asset(id)   ON DELETE CASCADE,
  PRIMARY KEY (finding_id, asset_id)
);

CREATE INDEX IF NOT EXISTS idx_finding_severity ON finding(severity);
CREATE INDEX IF NOT EXISTS idx_finding_status   ON finding(status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_finding_group_key_active
  ON finding(lower(group_key))
  WHERE group_key IS NOT NULL AND lifecycle IN ('draft', 'confirmed');

CREATE TRIGGER IF NOT EXISTS finding_touch_updated_at
AFTER UPDATE ON finding
FOR EACH ROW
WHEN NEW.updated_at = OLD.updated_at
BEGIN
  UPDATE finding SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;

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

-- ---------------------------------------------------------------------------
-- Observations: one row per concrete test case / occurrence. An observation is
-- captured immediately, before deciding whether it deserves a report finding.
-- Exact duplicate test cases collapse on `fingerprint`; several observations
-- can then be grouped under one finding through finding_observation.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS observation (
  id             INTEGER PRIMARY KEY,
  fingerprint    TEXT NOT NULL UNIQUE,
  state          TEXT NOT NULL DEFAULT 'new'
                   CHECK (state IN ('new','validating','confirmed','linked',
                                    'rejected','inconclusive','duplicate')),
  family         TEXT NOT NULL,             -- BOLA / XSS / authn / business-logic / ...
  title          TEXT NOT NULL,
  segment_id     INTEGER NOT NULL REFERENCES segment(id),
  asset_id       INTEGER REFERENCES asset(id),
  component      TEXT,
  boundary       TEXT,                      -- cross-tenant / cross-sede / vertical / ...
  method         TEXT,
  route          TEXT,                      -- normalized route, not a concrete object id
  selector       TEXT,                      -- parameter / field / object selector
  attacker_role  TEXT,
  target_role    TEXT,
  source         TEXT,                      -- Burp item, scanner result, journal note, manual test
  notes          TEXT,
  disposition    TEXT,                      -- why rejected/merged/inconclusive
  discovered_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_observation_state   ON observation(state);
CREATE INDEX IF NOT EXISTS idx_observation_family  ON observation(family);
CREATE INDEX IF NOT EXISTS idx_observation_segment ON observation(segment_id);

CREATE TRIGGER IF NOT EXISTS observation_touch_updated_at
AFTER UPDATE ON observation
FOR EACH ROW
WHEN NEW.updated_at = OLD.updated_at
BEGIN
  UPDATE observation SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;

-- A concrete occurrence belongs to at most one canonical report finding.
CREATE TABLE IF NOT EXISTS finding_observation (
  observation_id INTEGER PRIMARY KEY REFERENCES observation(id) ON DELETE CASCADE,
  finding_id     INTEGER NOT NULL REFERENCES finding(id) ON DELETE CASCADE,
  linked_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_finding_observation_finding
  ON finding_observation(finding_id);

-- Evidence is immutable metadata over an on-disk artefact. It hangs from an
-- observation, not directly from prose, so a merged finding keeps every proof.
CREATE TABLE IF NOT EXISTS evidence (
  id             INTEGER PRIMARY KEY,
  observation_id INTEGER NOT NULL REFERENCES observation(id) ON DELETE CASCADE,
  kind           TEXT NOT NULL,             -- http-request / http-response / screenshot / script / other
  path           TEXT NOT NULL UNIQUE,      -- engagement-relative path
  sha256         TEXT NOT NULL,
  description    TEXT,
  captured_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_evidence_observation ON evidence(observation_id);
