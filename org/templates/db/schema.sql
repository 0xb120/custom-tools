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
-- Assets: one row per (host, port). N:M with segments via asset_segment
-- (covers dual-homed hosts reachable from more than one vantage point).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS asset (
  id            INTEGER PRIMARY KEY,
  host          TEXT NOT NULL,
  port          INTEGER NOT NULL,
  protocol      TEXT,
  tls           INTEGER CHECK (tls IN (0, 1)),
  version       TEXT,
  technologies  TEXT,                       -- comma-separated stack fingerprint
  access        TEXT,                       -- free-form: anonymous / read-only / user / admin / rce / ...
  first_seen    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  notes         TEXT,
  UNIQUE (host, port)
);

CREATE TABLE IF NOT EXISTS asset_segment (
  asset_id   INTEGER NOT NULL REFERENCES asset(id)   ON DELETE CASCADE,
  segment_id INTEGER NOT NULL REFERENCES segment(id) ON DELETE CASCADE,
  PRIMARY KEY (asset_id, segment_id)
);

CREATE INDEX IF NOT EXISTS idx_asset_host   ON asset(host);
CREATE INDEX IF NOT EXISTS idx_asset_access ON asset(access);

-- Bump last_seen on every UPDATE that doesn't explicitly set it.
CREATE TRIGGER IF NOT EXISTS asset_touch_last_seen
AFTER UPDATE ON asset
FOR EACH ROW
WHEN NEW.last_seen = OLD.last_seen
BEGIN
  UPDATE asset SET last_seen = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;

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
  source_path    TEXT,                      -- optional: file the cred was extracted from (wl/hashes-ntlm.txt, scans/.../dump.txt, ...)
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
  evidence_path TEXT,                       -- relative path to the markdown report; auto-defaults to findings/<slug>.md on INSERT if NULL
  poc_dir       TEXT,                       -- relative path to the evidence directory; auto-defaults to poc/<slug>/ on INSERT if NULL
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
