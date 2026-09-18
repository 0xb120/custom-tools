#!/usr/bin/env python3
"""Transactional finding/observation registry for a PT engagement workspace."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
DB_PATH = SCRIPT_DIR / "engagement.db"
# Sized for the DB-derived sections only (identity, scope, cleanup, counts,
# open task titles). The old 18000 existed to fit an inlined AGENTS.md, which
# both clients now load natively.
DEFAULT_BOOT_CHARS = 8000
DEFAULT_DETAIL_CHARS = 24000
CLEANUP_STATES = ("open", "done")
SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL")
STATUSES = ("open", "fixed", "non-reproducible")
# Who decided what — never how sure the agent feels. `accepted` is reachable
# only through `finding create` / `finding attach`, so an agent cannot promote
# its own work into the report, and `proposed` is a review queue rather than a
# defect: nothing asks an agent to declare an open-ended exploration finished.
OBSERVATION_STATES = ("proposed", "accepted", "dismissed")
# What the agent CAN state as fact about its own work.
OBSERVATION_CONFIDENCE = ("suspected", "reproduced")
ACTIVE_LIFECYCLES = ("draft", "confirmed")
REQUIRED_MD_LABELS = (
    "Vuln_ID",
    "Group key",
    "Severity",
    "Status",
    "Affected asset(s)",
    "Related CWE(s)",
    "Segment",
    "Observation(s)",
)
EVIDENCE_START = "<!-- ptctl:evidence -->"
EVIDENCE_END = "<!-- /ptctl:evidence -->"
FAMILY_ALIASES = {
    "idor": "bola",
    "bola": "bola",
    "broken-object-authorization": "bola",
    "broken-object-level-authorization": "bola",
    "object-level-authorization": "bola",
    "xss": "xss",
    "cross-site-scripting": "xss",
}


class PTError(RuntimeError):
    pass


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def connect() -> sqlite3.Connection:
    if not DB_PATH.is_file():
        raise PTError(f"{DB_PATH} not found")
    con = sqlite3.connect(DB_PATH, timeout=10)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    con.execute("PRAGMA busy_timeout = 10000")
    ensure_schema(con)
    return con


def table_columns(con: sqlite3.Connection, table: str) -> set[str]:
    return {row["name"] for row in con.execute(f"PRAGMA table_info({table})")}


def ensure_schema(con: sqlite3.Connection) -> None:
    """Migrate an older engagement DB in place before using the registry."""
    columns = table_columns(con, "finding")
    if not columns:
        raise PTError("finding table missing; apply db/schema.sql first")

    additions = (
        ("group_key", "TEXT"),
        (
            "lifecycle",
            "TEXT NOT NULL DEFAULT 'confirmed' "
            "CHECK (lifecycle IN ('draft','confirmed','merged','rejected'))",
        ),
        ("canonical_finding_id", "INTEGER REFERENCES finding(id)"),
        ("updated_at", "DATETIME"),
    )
    for name, declaration in additions:
        if name not in columns:
            con.execute(f"ALTER TABLE finding ADD COLUMN {name} {declaration}")

    con.execute(
        """
        UPDATE finding
        SET updated_at=COALESCE(created_at, CURRENT_TIMESTAMP)
        WHERE updated_at IS NULL
        """
    )
    con.executescript(
        """
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

        CREATE TABLE IF NOT EXISTS observation (
          id             INTEGER PRIMARY KEY,
          fingerprint    TEXT NOT NULL UNIQUE,
          state          TEXT NOT NULL DEFAULT 'proposed'
                           CHECK (state IN ('proposed','accepted','dismissed')),
          confidence     TEXT NOT NULL DEFAULT 'suspected'
                           CHECK (confidence IN ('suspected','reproduced')),
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
          decided_by     TEXT,
          discovered_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
          updated_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_observation_state
          ON observation(state);
        CREATE INDEX IF NOT EXISTS idx_observation_family
          ON observation(family);
        CREATE INDEX IF NOT EXISTS idx_observation_segment
          ON observation(segment_id);

        CREATE TRIGGER IF NOT EXISTS observation_touch_updated_at
        AFTER UPDATE ON observation
        FOR EACH ROW
        WHEN NEW.updated_at = OLD.updated_at
        BEGIN
          UPDATE observation SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
        END;

        CREATE TABLE IF NOT EXISTS finding_observation (
          observation_id INTEGER PRIMARY KEY REFERENCES observation(id) ON DELETE CASCADE,
          finding_id     INTEGER NOT NULL REFERENCES finding(id) ON DELETE CASCADE,
          linked_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_finding_observation_finding
          ON finding_observation(finding_id);

        CREATE TABLE IF NOT EXISTS evidence (
          id             INTEGER PRIMARY KEY,
          observation_id INTEGER NOT NULL REFERENCES observation(id) ON DELETE CASCADE,
          kind           TEXT NOT NULL,
          path           TEXT NOT NULL UNIQUE,
          sha256         TEXT NOT NULL,
          description    TEXT,
          captured_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        );

        CREATE INDEX IF NOT EXISTS idx_evidence_observation
          ON evidence(observation_id);

        CREATE TABLE IF NOT EXISTS cleanup (
          id          INTEGER PRIMARY KEY,
          what        TEXT NOT NULL,
          location    TEXT,
          asset_id    INTEGER REFERENCES asset(id) ON DELETE SET NULL,
          owner       TEXT,
          note        TEXT,
          state       TEXT NOT NULL DEFAULT 'open'
                        CHECK (state IN ('open','done')),
          created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
          resolved_at DATETIME
        );

        CREATE INDEX IF NOT EXISTS idx_cleanup_state ON cleanup(state);

        CREATE TABLE IF NOT EXISTS coverage (
          id          INTEGER PRIMARY KEY,
          asset_id    INTEGER REFERENCES asset(id) ON DELETE CASCADE,
          segment_id  INTEGER REFERENCES segment(id) ON DELETE SET NULL,
          test_class  TEXT NOT NULL,
          note        TEXT NOT NULL,
          owner       TEXT,
          recorded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
          CHECK (asset_id IS NOT NULL OR segment_id IS NOT NULL)
        );

        CREATE INDEX IF NOT EXISTS idx_coverage_asset ON coverage(asset_id);
        CREATE INDEX IF NOT EXISTS idx_coverage_class ON coverage(test_class);
        """
    )
    con.commit()
    migrate_observation_vocabulary(con)
    migrate_coverage_ledger(con)


def table_sql(con: sqlite3.Connection, table: str) -> str:
    row = con.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()
    return str(row["sql"]) if row and row["sql"] else ""


def rebuild_table(con: sqlite3.Connection, table: str, create: str, copy: str) -> None:
    """SQLite cannot drop a CHECK constraint, so a vocabulary change means
    rebuilding the table (the documented 12-step ALTER procedure). Foreign keys
    are off for the swap so that dropping the old table does not cascade into
    evidence/finding_observation, and so the rename leaves other tables'
    REFERENCES clauses pointing at the name rather than the temporary table."""
    con.commit()
    con.execute("PRAGMA foreign_keys=OFF")
    try:
        con.execute("BEGIN IMMEDIATE")
        con.executescript(create)
        con.execute(copy)
        con.execute(f"DROP TABLE {table}")
        con.execute(f"ALTER TABLE {table}_migrated RENAME TO {table}")
        con.commit()
        violations = con.execute("PRAGMA foreign_key_check").fetchall()
        if violations:
            raise PTError(
                f"{table} migration left {len(violations)} foreign key violation(s); "
                "restore db/engagement.db from backup and report this"
            )
    except Exception:
        con.rollback()
        raise
    finally:
        con.execute("PRAGMA foreign_keys=ON")


def migrate_observation_vocabulary(con: sqlite3.Connection) -> None:
    """Collapse the old seven-state observation lifecycle onto the three states
    that record who decided what.

    new/validating/confirmed/inconclusive all meant "no human has ruled on this
    yet" — they differed only by how sure the agent was, which now lives in
    `confidence`. So they all become `proposed`, and nothing an agent wrote is
    silently treated as closed. `linked` becomes `accepted`; `rejected` and
    `duplicate` become `dismissed` and keep their reason. An `inconclusive`
    reason describes an attempt rather than a decision, so it is folded into
    `notes` where the operator still reads it."""
    columns = table_columns(con, "observation")
    if not columns or ("confidence" in columns and "decided_by" in columns):
        return
    create = """
        CREATE TABLE observation_migrated (
          id             INTEGER PRIMARY KEY,
          fingerprint    TEXT NOT NULL UNIQUE,
          state          TEXT NOT NULL DEFAULT 'proposed'
                           CHECK (state IN ('proposed','accepted','dismissed')),
          confidence     TEXT NOT NULL DEFAULT 'suspected'
                           CHECK (confidence IN ('suspected','reproduced')),
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
          decided_by     TEXT,
          discovered_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
          updated_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
    """
    copy = """
        INSERT INTO observation_migrated
          (id, fingerprint, state, confidence, family, title, segment_id,
           asset_id, component, boundary, method, route, selector,
           attacker_role, target_role, source, notes, disposition, decided_by,
           discovered_at, updated_at)
        SELECT id, fingerprint,
               CASE state
                 WHEN 'linked' THEN 'accepted'
                 WHEN 'rejected' THEN 'dismissed'
                 WHEN 'duplicate' THEN 'dismissed'
                 ELSE 'proposed'
               END,
               CASE WHEN state IN ('confirmed','linked')
                    THEN 'reproduced' ELSE 'suspected' END,
               family, title, segment_id, asset_id, component, boundary, method,
               route, selector, attacker_role, target_role, source,
               CASE WHEN state='inconclusive' AND disposition IS NOT NULL
                    THEN COALESCE(notes || ' | ', '')
                         || 'previously inconclusive: ' || disposition
                    ELSE notes END,
               CASE WHEN state IN ('rejected','duplicate')
                    THEN COALESCE(disposition, 'migrated from state=' || state)
                    ELSE NULL END,
               NULL,
               discovered_at, updated_at
        FROM observation
    """
    rebuild_table(con, "observation", create, copy)
    con.executescript(
        """
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
        """
    )
    con.commit()


def migrate_coverage_ledger(con: sqlite3.Connection) -> None:
    """Drop the verdict column. `negative` vs `partial` differed only by a
    completeness judgement nobody can make honestly, and `positive` duplicated
    the observation registry. The attempt itself is the fact worth keeping, so
    the old verdict is preserved inside the (now mandatory) note rather than
    thrown away."""
    columns = table_columns(con, "coverage")
    if not columns or "verdict" not in columns:
        return
    create = """
        CREATE TABLE coverage_migrated (
          id          INTEGER PRIMARY KEY,
          asset_id    INTEGER REFERENCES asset(id) ON DELETE CASCADE,
          segment_id  INTEGER REFERENCES segment(id) ON DELETE SET NULL,
          test_class  TEXT NOT NULL,
          note        TEXT NOT NULL,
          owner       TEXT,
          recorded_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
          CHECK (asset_id IS NOT NULL OR segment_id IS NOT NULL)
        );
    """
    copy = """
        INSERT INTO coverage_migrated
          (id, asset_id, segment_id, test_class, note, owner, recorded_at)
        SELECT id, asset_id, segment_id, test_class,
               CASE WHEN note IS NULL OR trim(note)=''
                    THEN 'recorded as verdict=' || verdict
                         || ' before the attempt log replaced verdicts'
                    ELSE note || ' [was verdict=' || verdict || ']' END,
               owner, recorded_at
        FROM coverage
    """
    rebuild_table(con, "coverage", create, copy)
    con.executescript(
        """
        CREATE INDEX IF NOT EXISTS idx_coverage_asset ON coverage(asset_id);
        CREATE INDEX IF NOT EXISTS idx_coverage_class ON coverage(test_class);
        """
    )
    con.commit()


def clean_single_line(value: str | None, field: str) -> str | None:
    if value is None:
        return None
    value = value.strip()
    if not value:
        return None
    if "\n" in value or "\r" in value:
        raise PTError(f"{field} must be a single line")
    return value


def normalize_group_key(value: str) -> str:
    raw_parts = value.strip().lower().split("|")
    parts: list[str] = []
    for raw in raw_parts:
        part = re.sub(r"[^a-z0-9._:-]+", "-", raw.strip()).strip("-")
        if not part:
            raise PTError(
                "group key components must contain letters/numbers "
                "(example: api|object-authorization|cross-tenant)"
            )
        parts.append(part)
    if len(parts) < 2:
        raise PTError("group key must have at least two '|' separated components")
    return "|".join(parts)


def normalize_family(value: str) -> str:
    cleaned = clean_single_line(value, "family")
    if not cleaned:
        raise PTError("--family is required")
    key = re.sub(r"[^a-z0-9]+", "-", cleaned.lower()).strip("-")
    return FAMILY_ALIASES.get(key, key)


def segment_id(con: sqlite3.Connection, name: str) -> int:
    row = con.execute("SELECT id FROM segment WHERE name=?", (name,)).fetchone()
    if row is None:
        raise PTError(
            f"unknown segment '{name}'; define it in the segment table before recording work"
        )
    return int(row["id"])


def asset_id(con: sqlite3.Connection, ref: str) -> int:
    match = re.fullmatch(r"[Aa](\d+)", ref)
    if match:
        value = int(match.group(1))
    elif ref.isdigit():
        value = int(ref)
    else:
        raise PTError(f"invalid asset reference '{ref}' (expected A1 or numeric id)")
    if con.execute("SELECT 1 FROM asset WHERE id=?", (value,)).fetchone() is None:
        raise PTError(f"asset A{value} not found")
    return value


def observation_id(con: sqlite3.Connection, ref: str) -> int:
    match = re.fullmatch(r"[Oo](\d+)", ref)
    if match:
        value = int(match.group(1))
    elif ref.isdigit():
        value = int(ref)
    else:
        raise PTError(f"invalid observation reference '{ref}' (expected O0001)")
    if con.execute("SELECT 1 FROM observation WHERE id=?", (value,)).fetchone() is None:
        raise PTError(f"observation O{value:04d} not found")
    return value


def finding_row(con: sqlite3.Connection, ref: str) -> sqlite3.Row:
    match = re.fullmatch(r"[Ff](\d+)", ref)
    if match:
        row = con.execute(
            "SELECT * FROM finding WHERE id=?", (int(match.group(1)),)
        ).fetchone()
    elif ref.isdigit():
        row = con.execute("SELECT * FROM finding WHERE id=?", (int(ref),)).fetchone()
    else:
        row = con.execute("SELECT * FROM finding WHERE slug=?", (ref,)).fetchone()
    if row is None:
        raise PTError(f"finding '{ref}' not found")
    return row


def display_finding(value: int) -> str:
    return f"F{value:02d}"


def display_observation(value: int) -> str:
    return f"O{value:04d}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def infer_evidence_kind(path: Path) -> str:
    suffix = path.suffix.lower()
    name = path.name.lower()
    if suffix in {".png", ".jpg", ".jpeg", ".webp", ".gif"}:
        return "screenshot"
    if suffix == ".http" or name.startswith("req"):
        return "http-request"
    if name.startswith("res"):
        return "http-response"
    if suffix in {".sh", ".py", ".js", ".rb", ".ps1"}:
        return "script"
    return "other"


def engagement_relative(value: str) -> tuple[Path, str]:
    candidate = Path(value)
    absolute = candidate if candidate.is_absolute() else ROOT / candidate
    absolute = absolute.resolve()
    try:
        relative = absolute.relative_to(ROOT.resolve())
    except ValueError as exc:
        raise PTError(f"evidence must live under the engagement root: {value}") from exc
    if not absolute.is_file():
        raise PTError(f"evidence file not found: {relative}")
    return absolute, relative.as_posix()


def register_evidence(
    con: sqlite3.Connection,
    obs_id: int,
    values: Iterable[str],
    kind: str | None = None,
    description: str | None = None,
) -> int:
    added = 0
    for value in values:
        absolute, relative = engagement_relative(value)
        existing = con.execute(
            "SELECT observation_id, sha256 FROM evidence WHERE path=?", (relative,)
        ).fetchone()
        digest = sha256_file(absolute)
        if existing:
            if int(existing["observation_id"]) != obs_id:
                raise PTError(
                    f"evidence '{relative}' is already owned by "
                    f"{display_observation(int(existing['observation_id']))}"
                )
            if existing["sha256"] != digest:
                raise PTError(
                    f"evidence '{relative}' changed after registration; "
                    "preserve the original or register a new file"
                )
            continue
        con.execute(
            """
            INSERT INTO evidence
              (observation_id, kind, path, sha256, description)
            VALUES (?, ?, ?, ?, ?)
            """,
            (obs_id, kind or infer_evidence_kind(absolute), relative, digest, description),
        )
        added += 1
    return added


HTTP_ID_SEGMENT = re.compile(
    r"^(?:\d+"
    r"|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    r"|[0-9a-fA-F]{16,})$"
)


def normalize_route(path: str) -> str:
    """Concrete object ids become `:id`, so two captures of the same endpoint
    share a fingerprint instead of minting an observation per object."""
    return "/".join(
        ":id" if HTTP_ID_SEGMENT.match(part) else part for part in path.split("/")
    )


def parse_http_request(path: Path) -> dict[str, str]:
    """Derive method/route/selector from a saved raw HTTP request.

    Capture is supposed to happen before the work continues, so the command that
    does it cannot cost eleven flags — the request file already carries most of
    them. Explicitly passed flags always win over what is derived here."""
    text = path.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"^([A-Z]+)\s+(\S+)\s+HTTP/\d", text, re.MULTILINE)
    if not match:
        raise PTError(
            f"{path.name} has no HTTP request line (METHOD path HTTP/x.y); "
            "pass --method/--route by hand"
        )
    method, target = match.group(1), match.group(2)
    target = re.sub(r"^https?://[^/]+", "", target) or "/"
    raw_path, _, query = target.partition("?")
    derived = {"method": method, "route": normalize_route(raw_path or "/")}
    if query:
        selector = query.split("&")[0].split("=")[0].strip()
        if selector:
            derived["selector"] = selector
    return derived


def apply_http_request_defaults(args: argparse.Namespace) -> None:
    if not getattr(args, "from_http", None):
        return
    absolute, _ = engagement_relative(args.from_http)
    for field, value in parse_http_request(absolute).items():
        if not getattr(args, field, None):
            setattr(args, field, value)


def observation_fingerprint(args: argparse.Namespace, seg_id: int) -> str:
    canonical = {
        "family": args.family.strip().lower(),
        "segment_id": seg_id,
        "asset_id": args.asset_id,
        "component": (args.component or "").strip().lower(),
        "boundary": (args.boundary or "").strip().lower(),
        "method": (args.method or "").strip().upper(),
        "route": (args.route or "").strip(),
        "selector": (args.selector or "").strip().lower(),
        "attacker_role": (args.attacker_role or "").strip().lower(),
        "target_role": (args.target_role or "").strip().lower(),
    }
    if not canonical["route"] and not canonical["component"]:
        raise PTError("provide at least --route or --component for a stable fingerprint")
    payload = json.dumps(canonical, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def write_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(temp_name, path)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def evidence_markdown(con: sqlite3.Connection, finding_id: int) -> str:
    rows = con.execute(
        """
        SELECT DISTINCT e.path, e.kind, COALESCE(e.description, '') AS description,
                        o.id AS observation_id
        FROM finding_observation fo
        JOIN observation o ON o.id=fo.observation_id
        JOIN evidence e ON e.observation_id=o.id
        WHERE fo.finding_id=?
        ORDER BY o.id, e.id
        """,
        (finding_id,),
    ).fetchall()
    if not rows:
        return "_No registered evidence yet — use `ptctl.py observation evidence`._"
    lines = []
    for row in rows:
        suffix = f" — {row['description']}" if row["description"] else ""
        path = row["path"]
        # Navigable ../-relative link: write-ups live in findings/, evidence
        # paths are relative to the engagement root.
        lines.append(
            f"- [{path}](../{path}) ({row['kind']}, "
            f"{display_observation(int(row['observation_id']))}){suffix}"
        )
    return "\n".join(lines)


def observation_refs(con: sqlite3.Connection, finding_id: int) -> str:
    ids = [
        display_observation(int(row["observation_id"]))
        for row in con.execute(
            """
            SELECT observation_id
            FROM finding_observation
            WHERE finding_id=?
            ORDER BY observation_id
            """,
            (finding_id,),
        )
    ]
    return ", ".join(ids) if ids else "<none>"


def affected_assets(con: sqlite3.Connection, finding_id: int) -> str:
    rows = con.execute(
        """
        SELECT a.id, h.name AS host, a.port, COALESCE(a.protocol, '') AS protocol
        FROM finding_asset fa
        JOIN asset a ON a.id=fa.asset_id
        JOIN host h ON h.id=a.host_id
        WHERE fa.finding_id=?
        ORDER BY h.name, a.port
        """,
        (finding_id,),
    ).fetchall()
    if rows:
        values = []
        for row in rows:
            protocol = f"/{row['protocol']}" if row["protocol"] else ""
            values.append(f"A{int(row['id'])} {row['host']}:{row['port']}{protocol}")
        return ", ".join(values)

    occurrences = con.execute(
        """
        SELECT DISTINCT COALESCE(o.component, '') AS component,
                        COALESCE(o.route, '') AS route
        FROM finding_observation fo
        JOIN observation o ON o.id=fo.observation_id
        WHERE fo.finding_id=?
        ORDER BY component, route
        """,
        (finding_id,),
    ).fetchall()
    values = []
    for row in occurrences:
        if row["component"] and row["route"]:
            values.append(f"{row['component']} ({row['route']})")
        elif row["component"] or row["route"]:
            values.append(row["component"] or row["route"])
    return ", ".join(values) if values else "<unlinked>"


def initial_writeup(con: sqlite3.Connection, row: sqlite3.Row) -> str:
    template_path = ROOT / "findings" / "_template.md"
    if not template_path.is_file():
        raise PTError(f"{template_path} not found")
    text = template_path.read_text(encoding="utf-8")
    replacements = {
        "# <Title>": f"# {row['title']}",
        "`<finding_slug>`": f"`{row['slug']}`",
        "`<group_key>`": f"`{row['group_key']}`",
        "`<CRITICAL | HIGH | MEDIUM | LOW | INFORMATIONAL>`": f"`{row['severity']}`",
        "`<open | fixed | non-reproducible>`": f"`{row['status']}`",
        "`<host / URL / endpoint / parameter / binary — one per line if multiple>`": (
            affected_assets(con, int(row["id"]))
        ),
        "`<CWE-NNN: short name>`": row["cwe"] or "`<fill CWE>`",
        "`<segment-name from AGENTS.md>`": f"`{segment_name(con, row['segment_id'])}`",
        "`<O0001, O0002>`": observation_refs(con, int(row["id"])),
    }
    for old, new in replacements.items():
        text = text.replace(old, new)
    text = replace_evidence_block(text, evidence_markdown(con, int(row["id"])))
    return text


def segment_name(con: sqlite3.Connection, value: int | None) -> str:
    if value is None:
        return ""
    row = con.execute("SELECT name FROM segment WHERE id=?", (value,)).fetchone()
    return row["name"] if row else ""


def replace_evidence_block(text: str, body: str) -> str:
    replacement = f"{EVIDENCE_START}\n{body}\n{EVIDENCE_END}"
    pattern = re.compile(
        re.escape(EVIDENCE_START) + r".*?" + re.escape(EVIDENCE_END), re.DOTALL
    )
    if not pattern.search(text):
        raise PTError("finding template/write-up is missing ptctl evidence markers")
    return pattern.sub(replacement, text, count=1)


def replace_label(text: str, label: str, value: str) -> str:
    pattern = re.compile(rf"^- \*\*{re.escape(label)}\*\*:.*$", re.MULTILINE)
    replacement = f"- **{label}**: {value}"
    if pattern.search(text):
        return pattern.sub(replacement, text, count=1)
    heading = re.search(r"^## ", text, re.MULTILINE)
    if not heading:
        raise PTError(f"cannot insert missing '{label}' metadata into write-up")
    return text[: heading.start()] + replacement + "\n" + text[heading.start() :]


def sync_finding_markdown(con: sqlite3.Connection, finding_id: int) -> None:
    row = con.execute(
        """
        SELECT f.*, s.name AS segment
        FROM finding f
        LEFT JOIN segment s ON s.id=f.segment_id
        WHERE f.id=?
        """,
        (finding_id,),
    ).fetchone()
    if row is None:
        raise PTError(f"finding {finding_id} not found")
    path = ROOT / (row["evidence_path"] or f"findings/{row['slug']}.md")
    if not path.is_file():
        raise PTError(f"finding write-up missing: {path.relative_to(ROOT)}")
    text = path.read_text(encoding="utf-8")
    text = re.sub(r"^# .*$", f"# {row['title']}", text, count=1, flags=re.MULTILINE)
    values = {
        "Vuln_ID": f"`{row['slug']}`",
        "Group key": f"`{row['group_key'] or '<missing>'}`",
        "Severity": f"`{row['severity']}`",
        "Status": f"`{row['status']}`",
        "Affected asset(s)": affected_assets(con, finding_id),
        "Related CWE(s)": row["cwe"] or "`<fill CWE>`",
        "Segment": f"`{row['segment'] or '<missing>'}`",
        "Observation(s)": observation_refs(con, finding_id),
    }
    for label, value in values.items():
        text = replace_label(text, label, value)
    text = replace_evidence_block(text, evidence_markdown(con, finding_id))
    write_atomic(path, text)


def render_report() -> None:
    render = SCRIPT_DIR / "render.sh"
    if not render.is_file():
        raise PTError(f"{render} not found")
    result = subprocess.run(
        ["bash", str(render)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise PTError(f"render failed: {result.stderr.strip() or result.stdout.strip()}")


def clip_text(value: str, limit: int) -> str:
    value = value.strip()
    if len(value) <= limit:
        return value
    marker = "\n… [truncated by context budget]"
    return value[: max(0, limit - len(marker))].rstrip() + marker


def file_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def read_text(path: Path) -> str:
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")


def open_tasks() -> list[tuple[str, str]]:
    tasks: list[tuple[str, str]] = []
    section = "Engagement-wide"
    for line in read_text(ROOT / "TODO.md").splitlines():
        heading = re.match(r"^##\s+(.+?)\s*$", line)
        if heading:
            section = heading.group(1)
            continue
        task = re.match(r"^- \[ \]\s+(.+?)\s*$", line)
        if task:
            tasks.append((section, task.group(1)))
    return tasks


def query_terms(value: str) -> list[str]:
    terms = re.findall(r"[a-z0-9][a-z0-9._:/-]*", value.lower())
    return list(dict.fromkeys(term for term in terms if len(term) >= 2))


def text_matches(value: str, terms: list[str]) -> bool:
    lowered = value.lower()
    return bool(terms) and all(term in lowered for term in terms)


def engagement_identity() -> str:
    agents = read_text(ROOT / "AGENTS.md")
    fields = []
    for display, labels in (
        ("Client", ("Client",)),
        ("Activity", ("Activity", "Activity name")),
        ("Type", ("Type", "Engagement type")),
        ("Environment", ("Environment",)),
        ("Methodology", ("Methodology",)),
        ("Testing window", ("Testing window",)),
        ("Start date", ("Start date",)),
        ("End date", ("End date",)),
        ("Reporting deadline", ("Reporting deadline",)),
    ):
        for label in labels:
            match = re.search(
                rf"^- \*\*{re.escape(label)}\*\*:\s*(.+?)\s*$",
                agents,
                re.MULTILINE,
            )
            if match:
                fields.append(f"- {display}: {match.group(1).strip()}")
                break
    return "\n".join(fields) if fields else "- Engagement metadata not initialized"


def scope_summary() -> str:
    sections = []
    for title, filename in (
        ("In scope", "scope.txt"),
        ("Out of scope", "out-of-scope.txt"),
    ):
        values = [
            line.strip()
            for line in read_text(ROOT / filename).splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        if values:
            body = "\n".join(f"- {clip_text(value, 180)}" for value in values[:10])
            if len(values) > 10:
                body += f"\n- … {len(values) - 10} more target(s); read {filename}"
        else:
            body = f"- No entries in {filename}"
        sections.append(f"{title}:\n{body}")
    return "\n\n".join(sections)


def registry_summary(con: sqlite3.Connection) -> str:
    finding_counts = {
        row["lifecycle"]: int(row["n"])
        for row in con.execute(
            "SELECT lifecycle, COUNT(*) AS n FROM finding GROUP BY lifecycle"
        )
    }
    observation_counts = {
        row["state"]: int(row["n"])
        for row in con.execute(
            "SELECT state, COUNT(*) AS n FROM observation GROUP BY state"
        )
    }
    assets = int(con.execute("SELECT COUNT(*) AS n FROM asset").fetchone()["n"])
    hosts = int(con.execute("SELECT COUNT(*) AS n FROM host").fetchone()["n"])
    active_findings = finding_counts.get("confirmed", 0) + finding_counts.get(
        "draft", 0
    )
    lines = [
        f"- Active findings: {active_findings}",
        f"- Merged/rejected findings: "
        f"{finding_counts.get('merged', 0) + finding_counts.get('rejected', 0)}",
        f"- Observations awaiting operator review: "
        f"{observation_counts.get('proposed', 0)} (`ptctl.py inbox`)",
        f"- Observations accepted into findings: "
        f"{observation_counts.get('accepted', 0)}",
        f"- Observations dismissed: {observation_counts.get('dismissed', 0)}",
        f"- Inventory: {hosts} host(s), {assets} asset(s)",
    ]
    if assets:
        untested = int(
            con.execute(
                """
                SELECT COUNT(*) AS n FROM asset a
                WHERE NOT EXISTS (SELECT 1 FROM coverage c WHERE c.asset_id=a.id)
                  AND NOT EXISTS (SELECT 1 FROM observation o WHERE o.asset_id=a.id)
                """
            ).fetchone()["n"]
        )
        lines.append(
            f"- Assets with nothing recorded: {untested} "
            "(`ptctl.py coverage gaps` lists them)"
        )
    open_cleanup = int(
        con.execute(
            "SELECT COUNT(*) AS n FROM cleanup WHERE state='open'"
        ).fetchone()["n"]
    )
    if open_cleanup:
        lines.append(f"- Open cleanup obligations: {open_cleanup}")
    return "\n".join(lines)


def pending_summary(limit: int) -> str:
    tasks = open_tasks()
    if not tasks:
        return "- No open TODO items"
    lines = [
        f"- [{section}] {clip_text(task, 180)}"
        for section, task in tasks[:limit]
    ]
    if len(tasks) > limit:
        lines.append(
            f"- … {len(tasks) - limit} more open task(s); "
            "run `python3 db/ptctl.py context pending`"
        )
    return "\n".join(lines)


def clipped_sections(sections: list[tuple[str, str, int]]) -> list[str]:
    """Sections whose own cap is smaller than their body — reported, never silent."""
    return [
        f"{title} (-{len(body.strip()) - section_cap} chars)"
        for title, body, section_cap in sections
        if len(body.strip()) > section_cap
    ]


def build_bounded_context(
    sections: list[tuple[str, str, int]], max_chars: int
) -> str:
    if max_chars < 4000:
        raise PTError("--max-chars must be at least 4000")
    output = ["PT CONTEXT BOOT — progressive disclosure"]
    reserve = 900
    for title, body, section_cap in sections:
        if not body.strip():
            continue
        prefix = f"\n\n--- {title} ---\n"
        available = max_chars - len("".join(output)) - len(prefix) - reserve
        if available <= 100:
            break
        output.extend((prefix, clip_text(body, min(section_cap, available))))
    overflow = clipped_sections(sections)
    warning = (
        "\n\n--- INCOMPLETE BOOT ---\n"
        "These sections did not fit and were cut mid-text: "
        + "; ".join(overflow)
        + ".\nRead the source file directly before relying on them, and shrink it "
        "or raise --max-chars.\n"
        if overflow
        else ""
    )
    manifest = warning + (
        "\n\n--- Context policy ---\n"
        "Loaded now: engagement identity, scope, open cleanup obligations, "
        "registry counts, compact open tasks. The hard rules are in AGENTS.md, "
        "which your client loads natively — they are not repeated here.\n"
        "Not loaded: journal prose, finding write-ups, evidence bodies, scans, "
        "completed TODO history.\n"
        "After the human chooses a target, form an independent test plan first; "
        "then use `context focus`, `context history`, `context resume`, or "
        "`coverage gaps`.\n"
        "Sessions are independent and may run concurrently: the engagement DB "
        "is the only state you share with the other agents."
    )
    result = "".join(output)
    if len(result) + len(manifest) <= max_chars:
        result += manifest
    else:
        result = clip_text(result, max_chars - len(manifest)) + manifest
    return clip_text(result, max_chars)


def boot_context(
    con: sqlite3.Connection, max_chars: int, task_limit: int
) -> str:
    # AGENTS.md is never inlined here. Both supported clients discover it
    # natively (Codex reads it; Claude Code hardcodes CLAUDE.md / AGENTS.md
    # discovery), so bridging it into the bootstrap put the same ~12 KB of
    # rules in context twice, re-paid on every resume and compact.
    sections: list[tuple[str, str, int]] = [
        ("Engagement", engagement_identity(), 1000)
    ]
    sections.extend(
        (
            ("Scope boundaries", scope_summary(), 1600),
            (
                "Cleanup obligations still open",
                cleanup_summary(con),
                1200,
            ),
            ("Canonical registry counts", registry_summary(con), 600),
            ("Open work (titles only)", pending_summary(task_limit), 1500),
        )
    )
    return build_bounded_context(sections, max_chars)


def cmd_context_boot(args: argparse.Namespace) -> None:
    with connect() as con:
        print(
            boot_context(
                con,
                max_chars=args.max_chars,
                task_limit=args.task_limit,
            )
        )


def cmd_context_explain(args: argparse.Namespace) -> None:
    with connect() as con:
        rendered = boot_context(
            con,
            max_chars=args.max_chars,
            task_limit=args.task_limit,
        )
        counts = con.execute(
            """
            SELECT
              (SELECT COUNT(*) FROM finding) AS findings,
              (SELECT COUNT(*) FROM observation) AS observations,
              (SELECT COUNT(*) FROM evidence) AS evidence,
              (SELECT COUNT(*) FROM coverage) AS coverage
            """
        ).fetchone()
    print(f"Direct boot context: {len(rendered)} chars (budget={args.max_chars})")
    print("Sources:")
    rules_bytes = file_size(ROOT / "AGENTS.md")
    print(
        f"- AGENTS.md: never inlined; loaded natively by both clients, "
        f"identity fields summarized ({rules_bytes} bytes)"
    )
    print(f"- scope.txt: summarized ({file_size(ROOT / 'scope.txt')} bytes)")
    print(
        f"- out-of-scope.txt: summarized "
        f"({file_size(ROOT / 'out-of-scope.txt')} bytes)"
    )
    print("- cleanup table: open obligations only (what testing left behind)")
    print(f"- TODO.md: open titles only ({len(open_tasks())} open)")
    print(
        f"- registry: counts only ({counts['findings']} findings, "
        f"{counts['observations']} observations, {counts['evidence']} evidence, "
        f"{counts['coverage']} coverage entries)"
    )
    print("Excluded:")
    print("- journal.md prose")
    print("- finding write-ups and report prose")
    print("- evidence contents, scans, and Burp history")
    print("- completed TODO history")
    print("- the attempt log itself (`coverage list` loads it)")
    print("- the operator review queue (`ptctl.py inbox` loads it)")


def cmd_context_pending(args: argparse.Namespace) -> None:
    tasks = open_tasks()
    selected = [
        (section, task)
        for section, task in tasks
        if not args.segment or section.lower() == args.segment.lower()
    ]
    print(f"Open TODO items: {len(selected)}")
    for number, (section, task) in enumerate(selected[: args.limit], 1):
        print(f"{number:02d}. [{section}] {clip_text(task, 500)}")
    if len(selected) > args.limit:
        print(f"… {len(selected) - args.limit} more; increase --limit")


def matching_registry_rows(
    con: sqlite3.Connection, terms: list[str], segment: str | None
) -> tuple[list[sqlite3.Row], list[sqlite3.Row], list[sqlite3.Row]]:
    assets = con.execute(
        """
        SELECT a.id, h.name AS host, a.port, COALESCE(a.protocol, '') AS protocol,
               COALESCE(a.version, '') AS version,
               COALESCE(a.technologies, '') AS technologies,
               COALESCE(GROUP_CONCAT(DISTINCT s.name), '') AS segments
        FROM asset a
        JOIN host h ON h.id=a.host_id
        LEFT JOIN host_segment hs ON hs.host_id=h.id
        LEFT JOIN segment s ON s.id=hs.segment_id
        GROUP BY a.id
        ORDER BY h.name, a.port
        """
    ).fetchall()
    observations = con.execute(
        """
        SELECT o.id, o.state, o.confidence, o.family, o.title,
               COALESCE(o.component, '') AS component,
               COALESCE(o.boundary, '') AS boundary, COALESCE(o.method, '') AS method,
               COALESCE(o.route, '') AS route,
               COALESCE(o.disposition, '') AS disposition, s.name AS segment
        FROM observation o
        JOIN segment s ON s.id=o.segment_id
        ORDER BY o.id
        """
    ).fetchall()
    findings = con.execute(
        """
        SELECT f.id, f.lifecycle, f.slug, f.group_key, f.title, f.severity,
               COALESCE(f.cwe, '') AS cwe, s.name AS segment
        FROM finding f
        JOIN segment s ON s.id=f.segment_id
        ORDER BY f.id
        """
    ).fetchall()

    def selected(row: sqlite3.Row, fields: Iterable[str]) -> bool:
        if segment:
            row_segments = str(row["segments"] if "segments" in row.keys() else row["segment"])
            if segment.lower() not in row_segments.lower():
                return False
        haystack = " ".join(str(row[field]) for field in fields)
        return text_matches(haystack, terms)

    return (
        [
            row
            for row in assets
            if selected(
                row, ("host", "port", "protocol", "version", "technologies", "segments")
            )
        ],
        [
            row
            for row in observations
            if selected(
                row,
                ("family", "title", "component", "boundary", "method", "route", "segment"),
            )
        ],
        [
            row
            for row in findings
            if selected(row, ("slug", "group_key", "title", "cwe", "segment"))
        ],
    )


def cmd_context_focus(args: argparse.Namespace) -> None:
    terms = query_terms(args.topic)
    if not terms:
        raise PTError("--topic must contain searchable terms")
    with connect() as con:
        assets, observations, findings = matching_registry_rows(
            con, terms, args.segment
        )
    tasks = [
        (section, task)
        for section, task in open_tasks()
        if (not args.segment or section.lower() == args.segment.lower())
        and text_matches(f"{section} {task}", terms)
    ]
    lines = [
        f"FOCUS DOSSIER — topic={args.topic!r}"
        + (f" segment={args.segment}" if args.segment else ""),
        "",
        "This is a post-plan orientation view. Journal prose, finding prose, "
        "evidence bodies, and scans remain excluded.",
        "",
        f"Open tasks ({len(tasks)}):",
    ]
    lines.extend(
        f"- [{section}] {clip_text(task, 360)}" for section, task in tasks[: args.limit]
    )
    if not tasks:
        lines.append("- none")
    lines.append(f"\nMatching assets ({len(assets)}):")
    lines.extend(
        f"- A{int(row['id'])} {row['host']}:{row['port']}/{row['protocol']} "
        f"[{row['segments']}] {row['technologies'] or row['version']}"
        for row in assets[: args.limit]
    )
    if not assets:
        lines.append("- none")
    lines.append(f"\nRegistry pointers ({len(observations)} observations, {len(findings)} findings):")
    lines.extend(
        f"- {display_observation(int(row['id']))} state={row['state']} "
        f"confidence={row['confidence']} "
        f"{row['family']} [{row['segment']}] {row['component']} {row['route']}"
        for row in observations[: args.limit]
    )
    lines.extend(
        f"- {display_finding(int(row['id']))} lifecycle={row['lifecycle']} "
        f"group_key={row['group_key']} [{row['segment']}]"
        for row in findings[: args.limit]
    )
    if not observations and not findings:
        lines.append("- none")
    lines.append(
        "\nFor prior conclusions run `context history`; to resume one canonical "
        "item run `context resume F##|O####`."
    )
    print(clip_text("\n".join(lines), args.max_chars))


def journal_matches(terms: list[str], limit: int) -> list[tuple[int, str]]:
    matches = []
    for number, line in enumerate(
        read_text(ROOT / "journal.md").splitlines(), 1
    ):
        if text_matches(line, terms):
            matches.append((number, clip_text(line, 1200)))
    return matches[-limit:]


def cmd_context_history(args: argparse.Namespace) -> None:
    terms = query_terms(args.topic)
    if not terms:
        raise PTError("--topic must contain searchable terms")
    with connect() as con:
        _, observations, findings = matching_registry_rows(con, terms, args.segment)
    journal = journal_matches(terms, args.limit)
    lines = [
        f"HISTORY — topic={args.topic!r}"
        + (f" segment={args.segment}" if args.segment else ""),
        "",
        "Prior conclusions are being loaded explicitly; treat hypotheses as "
        "untrusted until reproduced.",
        "",
        f"Findings ({len(findings)}):",
    ]
    lines.extend(
        f"- {display_finding(int(row['id']))} {row['severity']} "
        f"[{row['group_key']}] — {row['title']}"
        for row in findings[: args.limit]
    )
    if not findings:
        lines.append("- none")
    lines.append(f"\nObservations ({len(observations)}):")
    lines.extend(
        f"- {display_observation(int(row['id']))} {row['state']}"
        f"/{row['confidence']} {row['family']} [{row['segment']}] — {row['title']}"
        + (f" — dismissed: {row['disposition']}" if row["disposition"] else "")
        for row in observations[: args.limit]
    )
    if not observations:
        lines.append("- none")
    lines.append(f"\nJournal matches ({len(journal)}):")
    lines.extend(f"- line {number}: {line}" for number, line in journal)
    if not journal:
        lines.append("- none")
    print(clip_text("\n".join(lines), args.max_chars))


def finding_resume_context(
    con: sqlite3.Connection, row: sqlite3.Row, max_chars: int
) -> str:
    finding_id = int(row["id"])
    observations = con.execute(
        """
        SELECT o.*
        FROM finding_observation fo
        JOIN observation o ON o.id=fo.observation_id
        WHERE fo.finding_id=?
        ORDER BY o.id
        """,
        (finding_id,),
    ).fetchall()
    evidence = con.execute(
        """
        SELECT e.*, o.id AS observation_id
        FROM evidence e
        JOIN observation o ON o.id=e.observation_id
        JOIN finding_observation fo ON fo.observation_id=o.id
        WHERE fo.finding_id=?
        ORDER BY o.id, e.id
        """,
        (finding_id,),
    ).fetchall()
    ref = display_finding(finding_id)
    journal = journal_matches(
        [ref.lower()], 12
    ) + journal_matches([str(row["slug"]).lower()], 12)
    writeup = ROOT / (
        row["evidence_path"] or f"findings/{row['slug']}.md"
    )
    lines = [
        f"RESUME {ref} — {row['title']}",
        f"- lifecycle: {row['lifecycle']}",
        f"- group_key: {row['group_key']}",
        f"- severity/status: {row['severity']} / {row['status']}",
        f"- segment: {segment_name(con, row['segment_id'])}",
        f"- affected: {affected_assets(con, finding_id)}",
        f"- observations: {observation_refs(con, finding_id)}",
        "",
        "Evidence registry:",
    ]
    lines.extend(
        f"- {display_observation(int(item['observation_id']))}: "
        f"{item['path']} ({item['kind']}, sha256={item['sha256'][:12]}…)"
        for item in evidence
    )
    if not evidence:
        lines.append("- none")
    lines.append("\nObservation details:")
    lines.extend(
        f"- {display_observation(int(item['id']))} {item['state']} "
        f"{item['family']} component={item['component'] or '-'} "
        f"boundary={item['boundary'] or '-'} "
        f"{item['method'] or ''} {item['route'] or ''} "
        f"selector={item['selector'] or '-'}"
        for item in observations
    )
    lines.append("\nFinding write-up:\n" + (read_text(writeup) or "<missing>"))
    if journal:
        lines.append("\nReferenced journal entries:")
        seen = set()
        for number, line in journal:
            if number in seen:
                continue
            seen.add(number)
            lines.append(f"- line {number}: {line}")
    return clip_text("\n".join(lines), max_chars)


def observation_resume_context(
    con: sqlite3.Connection, observation_ref: str, max_chars: int
) -> str:
    obs_id = observation_id(con, observation_ref)
    row = con.execute(
        """
        SELECT o.*, s.name AS segment
        FROM observation o
        JOIN segment s ON s.id=o.segment_id
        WHERE o.id=?
        """,
        (obs_id,),
    ).fetchone()
    link = con.execute(
        """
        SELECT f.*
        FROM finding_observation fo
        JOIN finding f ON f.id=fo.finding_id
        WHERE fo.observation_id=?
        """,
        (obs_id,),
    ).fetchone()
    evidence = con.execute(
        "SELECT * FROM evidence WHERE observation_id=? ORDER BY id", (obs_id,)
    ).fetchall()
    ref = display_observation(obs_id)
    lines = [
        f"RESUME {ref} — {row['title']}",
        f"- state: {row['state']} (confidence={row['confidence']}"
        + (f", decided by {row['decided_by']}" if row["decided_by"] else "")
        + ")",
        f"- family/segment: {row['family']} / {row['segment']}",
        f"- component/boundary: {row['component'] or '-'} / {row['boundary'] or '-'}",
        f"- request identity: {row['method'] or '-'} {row['route'] or '-'} "
        f"selector={row['selector'] or '-'}",
        f"- roles: {row['attacker_role'] or '-'} -> {row['target_role'] or '-'}",
        f"- source: {row['source'] or '-'}",
        f"- notes: {row['notes'] or '-'}",
        f"- dismissal reason: {row['disposition'] or '-'}",
        f"- canonical finding: "
        f"{display_finding(int(link['id'])) + ' ' + link['slug'] if link else '<none>'}",
        "",
        "Evidence registry:",
    ]
    lines.extend(
        f"- {item['path']} ({item['kind']}, sha256={item['sha256'][:12]}…)"
        for item in evidence
    )
    if not evidence:
        lines.append("- none")
    journal = journal_matches([ref.lower()], 16)
    if journal:
        lines.append("\nReferenced journal entries:")
        lines.extend(f"- line {number}: {line}" for number, line in journal)
    if link:
        lines.append(
            "\nUse `context resume "
            f"{display_finding(int(link['id']))}` for the complete finding dossier."
        )
    return clip_text("\n".join(lines), max_chars)


def cmd_context_resume(args: argparse.Namespace) -> None:
    with connect() as con:
        if re.fullmatch(r"[Oo]\d+", args.reference):
            print(observation_resume_context(con, args.reference, args.max_chars))
            return
        print(finding_resume_context(con, finding_row(con, args.reference), args.max_chars))


# ---------------------------------------------------------------------------
# Cleanup register and coverage ledger
#
# These replaced the single-tenant .context/ session layer (handoff.md,
# state.json, active.json), which assumed exactly one agent per engagement: the
# baseline was global, so the first session to close absorbed every other
# session's in-flight artifacts and silently released their capture gate.
#
# Both tables live in the engagement DB and are INSERT-only (or a single-row
# state flip), so any number of concurrent sessions record into them with no
# shared file to overwrite. They hold the two things the registry cannot
# reconstruct on its own: what we left behind on the target, and what we tested
# without finding anything.
# ---------------------------------------------------------------------------


def display_cleanup(value: int) -> str:
    return f"C{value:02d}"


def cleanup_id(con: sqlite3.Connection, ref: str) -> int:
    match = re.fullmatch(r"[Cc](\d+)", ref)
    if match:
        value = int(match.group(1))
    elif ref.isdigit():
        value = int(ref)
    else:
        raise PTError(f"invalid cleanup reference '{ref}' (expected C01 or numeric id)")
    if con.execute("SELECT 1 FROM cleanup WHERE id=?", (value,)).fetchone() is None:
        raise PTError(f"cleanup {display_cleanup(value)} not found")
    return value


def cleanup_rows(con: sqlite3.Connection, include_done: bool) -> list[sqlite3.Row]:
    where = "" if include_done else "WHERE c.state='open'"
    return con.execute(
        f"""
        SELECT c.id, c.what, COALESCE(c.location, '') AS location, c.state,
               COALESCE(c.owner, '') AS owner, COALESCE(c.note, '') AS note,
               c.created_at, COALESCE(h.name, '') AS host,
               COALESCE(a.port, '') AS port
        FROM cleanup c
        LEFT JOIN asset a ON a.id=c.asset_id
        LEFT JOIN host h ON h.id=a.host_id
        {where}
        ORDER BY c.state, c.id
        """
    ).fetchall()


def cleanup_where(row: sqlite3.Row) -> str:
    if row["location"]:
        return str(row["location"])
    if row["host"]:
        return f"{row['host']}:{row['port']}" if row["port"] != "" else str(row["host"])
    return ""


def cleanup_summary(con: sqlite3.Connection, limit: int = 10) -> str:
    rows = cleanup_rows(con, include_done=False)
    if not rows:
        return "- None open"
    lines = []
    for row in rows[:limit]:
        where = cleanup_where(row)
        lines.append(
            f"- {display_cleanup(int(row['id']))} {clip_text(row['what'], 160)}"
            + (f" [{where}]" if where else "")
        )
    if len(rows) > limit:
        lines.append(
            f"- … {len(rows) - limit} more; run `python3 db/ptctl.py cleanup list`"
        )
    return "\n".join(lines)


def cmd_cleanup_add(args: argparse.Namespace) -> None:
    what = clean_single_line(args.what, "what")
    if not what:
        raise PTError("--what is required")
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        target = asset_id(con, args.asset) if args.asset else None
        cursor = con.execute(
            "INSERT INTO cleanup (what, location, asset_id, owner, note) "
            "VALUES (?, ?, ?, ?, ?)",
            (
                what,
                clean_single_line(args.location, "location"),
                target,
                clean_single_line(args.owner, "owner"),
                clean_single_line(args.note, "note"),
            ),
        )
        con.commit()
        print(f"{display_cleanup(int(cursor.lastrowid))} registered (open)")


def cmd_cleanup_done(args: argparse.Namespace) -> None:
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        row_id = cleanup_id(con, args.reference)
        con.execute(
            "UPDATE cleanup SET state='done', resolved_at=CURRENT_TIMESTAMP, "
            "note=COALESCE(?, note) WHERE id=?",
            (clean_single_line(args.note, "note"), row_id),
        )
        con.commit()
    print(f"{display_cleanup(row_id)} resolved")


def cmd_cleanup_list(args: argparse.Namespace) -> None:
    with connect() as con:
        rows = cleanup_rows(con, include_done=args.all)
    print(f"Cleanup obligations: {len(rows)}")
    for row in rows:
        where = cleanup_where(row) or "-"
        owner = f" owner={row['owner']}" if row["owner"] else ""
        print(
            f"{display_cleanup(int(row['id']))} [{row['state']}] {row['what']} "
            f"@ {where}{owner} ({row['created_at']})"
        )


def coverage_target(
    con: sqlite3.Connection, args: argparse.Namespace
) -> tuple[int | None, int | None, str]:
    """Resolve --asset / --segment into (asset_id, segment_id, label)."""
    target_asset = asset_id(con, args.asset) if args.asset else None
    target_segment = segment_id(con, args.segment) if args.segment else None
    if target_asset is None and target_segment is None:
        raise PTError("coverage needs --asset A1 or --segment <name>")
    if target_asset is not None and target_segment is None:
        row = con.execute(
            """
            SELECT hs.segment_id FROM asset a
            JOIN host_segment hs ON hs.host_id=a.host_id
            WHERE a.id=? LIMIT 1
            """,
            (target_asset,),
        ).fetchone()
        target_segment = int(row["segment_id"]) if row else None
    label = f"A{target_asset}" if target_asset is not None else str(args.segment)
    return target_asset, target_segment, label


def cmd_coverage_add(args: argparse.Namespace) -> None:
    test_class = normalize_family(args.test_class)
    note = clean_single_line(args.note, "note")
    if not note:
        # The note IS the record. Without it the row asserts that a class was
        # "covered" while saying nothing about what was actually tried, which is
        # the completeness claim this ledger deliberately refuses to make.
        raise PTError(
            "--note is required: say what was actually tried "
            "(e.g. 'cross-tenant read/write/delete all 403 for customer/customer')"
        )
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        target_asset, target_segment, label = coverage_target(con, args)
        con.execute(
            "INSERT INTO coverage "
            "(asset_id, segment_id, test_class, note, owner) "
            "VALUES (?, ?, ?, ?, ?)",
            (
                target_asset,
                target_segment,
                test_class,
                note,
                clean_single_line(args.owner, "owner") or decided_by(args),
            ),
        )
        con.commit()
    print(f"attempt recorded: {label} {test_class} — {clip_text(note, 120)}")


def coverage_ledger(
    con: sqlite3.Connection, segment: str | None
) -> dict[tuple[str, str], list[sqlite3.Row]]:
    """Every attempt per (target, test_class), oldest first.

    Nothing supersedes anything here. Two sessions poking at the same class from
    different angles both did real work, and a reader judging whether a class is
    covered needs to see both attempts, not the most recent one."""
    rows = con.execute(
        """
        SELECT c.id, c.test_class, c.note,
               COALESCE(c.owner, '') AS owner, c.recorded_at, c.asset_id,
               COALESCE(s.name, '') AS segment,
               COALESCE(h.name, '') AS host, COALESCE(a.port, '') AS port
        FROM coverage c
        LEFT JOIN asset a ON a.id=c.asset_id
        LEFT JOIN host h ON h.id=a.host_id
        LEFT JOIN segment s ON s.id=c.segment_id
        ORDER BY c.id
        """
    ).fetchall()
    ledger: dict[tuple[str, str], list[sqlite3.Row]] = {}
    for row in rows:
        if segment and row["segment"].lower() != segment.lower():
            continue
        target = (
            f"A{int(row['asset_id'])} {row['host']}:{row['port']}"
            if row["asset_id"] is not None
            else f"[{row['segment']}]"
        )
        ledger.setdefault((target, row["test_class"]), []).append(row)
    return ledger


def cmd_coverage_list(args: argparse.Namespace) -> None:
    with connect() as con:
        ledger = coverage_ledger(con, args.segment)
    total = sum(len(rows) for rows in ledger.values())
    print(f"Recorded attempts: {total} across {len(ledger)} target/class pair(s)")
    for (target, test_class), rows in sorted(ledger.items()):
        print(f"{target} {test_class} ({len(rows)} attempt(s)):")
        for row in rows[-args.limit :]:
            owner = f" ({row['owner']})" if row["owner"] else ""
            print(
                f"  [{row['recorded_at']}]{owner} {clip_text(row['note'], 300)}"
            )


def cmd_coverage_gaps(args: argparse.Namespace) -> None:
    with connect() as con:
        assets = con.execute(
            """
            SELECT a.id, h.name AS host, a.port,
                   COALESCE(a.protocol, '') AS protocol,
                   COALESCE(a.technologies, '') AS technologies,
                   COALESCE(GROUP_CONCAT(DISTINCT s.name), '') AS segments
            FROM asset a
            JOIN host h ON h.id=a.host_id
            LEFT JOIN host_segment hs ON hs.host_id=h.id
            LEFT JOIN segment s ON s.id=hs.segment_id
            GROUP BY a.id
            ORDER BY h.name, a.port
            """
        ).fetchall()
        touched: dict[int, set[str]] = {}
        for table, column in (("coverage", "test_class"), ("observation", "family")):
            for row in con.execute(
                f"SELECT asset_id, {column} AS value FROM {table} "
                "WHERE asset_id IS NOT NULL"
            ):
                touched.setdefault(int(row["asset_id"]), set()).add(row["value"])

    if args.segment:
        assets = [
            row for row in assets if args.segment.lower() in str(row["segments"]).lower()
        ]
    # The engagement's own vocabulary: every class anyone has tested or observed
    # anywhere. Self-calibrating — no hardcoded taxonomy to keep in sync.
    vocabulary: set[str] = set()
    for values in touched.values():
        vocabulary |= values

    untouched = [row for row in assets if int(row["id"]) not in touched]
    print(f"COVERAGE GAPS — {len(assets)} asset(s) in view")
    print(
        "\nVocabulary in this engagement: "
        + (", ".join(sorted(vocabulary)) if vocabulary else "<nothing recorded yet>")
    )
    print(f"\nNever tested ({len(untouched)}):")
    for row in untouched[: args.limit]:
        print(
            f"- A{int(row['id'])} {row['host']}:{row['port']}/{row['protocol']} "
            f"[{row['segments']}] {row['technologies']}"
        )
    if not untouched:
        print("- none")
    if len(untouched) > args.limit:
        print(f"… {len(untouched) - args.limit} more; increase --limit")

    partial = []
    for row in assets:
        seen = touched.get(int(row["id"]))
        if not seen:
            continue
        missing = sorted(vocabulary - seen)
        if missing:
            partial.append((row, missing))
    print(f"\nTested, but not for every class seen elsewhere ({len(partial)}):")
    for row, missing in partial[: args.limit]:
        print(
            f"- A{int(row['id'])} {row['host']}:{row['port']} missing: "
            + ", ".join(missing)
        )
    if not partial:
        print("- none")
    print(
        "\nA gap is a question, not a task: it says nobody recorded work there, "
        "not that work is owed."
    )


def register_observation_evidence(
    con: sqlite3.Connection, obs_id: int, args: argparse.Namespace
) -> int:
    """Register --evidence under the caller's --kind, and --from-http as the
    http-request evidence every finding will eventually be required to carry."""
    added = register_evidence(con, obs_id, args.evidence, args.kind, args.description)
    if getattr(args, "from_http", None):
        added += register_evidence(
            con, obs_id, [args.from_http], HTTP_REQUEST_KIND, args.description
        )
    return added


def cmd_observation_add(args: argparse.Namespace) -> None:
    apply_http_request_defaults(args)
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        seg_id = segment_id(con, args.segment)
        args.asset_id = asset_id(con, args.asset) if args.asset else None
        family = normalize_family(args.family)
        args.family = family
        fingerprint = args.fingerprint or observation_fingerprint(args, seg_id)
        existing = con.execute(
            "SELECT id, state, confidence, disposition FROM observation "
            "WHERE fingerprint=?",
            (fingerprint,),
        ).fetchone()
        if existing:
            obs_id = int(existing["id"])
            added = register_observation_evidence(con, obs_id, args)
            # A recapture that actually reproduced the behaviour upgrades the
            # row; confidence never silently walks back to a suspicion.
            confidence = existing["confidence"]
            if args.confidence == "reproduced" and confidence != "reproduced":
                con.execute(
                    "UPDATE observation SET confidence='reproduced' WHERE id=?",
                    (obs_id,),
                )
                confidence = "reproduced"
            for row in con.execute(
                "SELECT finding_id FROM finding_observation WHERE observation_id=?",
                (obs_id,),
            ):
                sync_finding_markdown(con, int(row["finding_id"]))
            con.commit()
            # Say WHY it was dismissed, here, where someone is about to spend
            # time re-testing what a previous session already ruled out.
            reason = (
                f" — dismissed: {existing['disposition']}"
                if existing["state"] == "dismissed" and existing["disposition"]
                else ""
            )
            print(
                f"{display_observation(obs_id)} already exists "
                f"(state={existing['state']}, confidence={confidence}, "
                f"evidence_added={added}){reason}"
            )
            return

        title = clean_single_line(args.title, "title")
        if not title:
            raise PTError("--title is required")
        cursor = con.execute(
            """
            INSERT INTO observation
              (fingerprint, state, confidence, family, title, segment_id,
               asset_id, component, boundary, method, route, selector,
               attacker_role, target_role, source, notes)
            VALUES (?, 'proposed', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                fingerprint,
                args.confidence,
                family,
                title,
                seg_id,
                args.asset_id,
                clean_single_line(args.component, "component"),
                clean_single_line(args.boundary, "boundary"),
                clean_single_line(args.method, "method"),
                clean_single_line(args.route, "route"),
                clean_single_line(args.selector, "selector"),
                clean_single_line(args.attacker_role, "attacker role"),
                clean_single_line(args.target_role, "target role"),
                clean_single_line(args.source, "source"),
                clean_single_line(args.notes, "notes"),
            ),
        )
        obs_id = int(cursor.lastrowid)
        added = register_observation_evidence(con, obs_id, args)
        con.commit()
        print(
            f"created {display_observation(obs_id)} state=proposed "
            f"confidence={args.confidence} "
            f"(fingerprint={fingerprint[:12]}, evidence={added})"
        )


def decided_by(args: argparse.Namespace) -> str | None:
    """Who ruled on this. Falls back to $PT_OPERATOR so the workspace can supply
    it once instead of every command carrying a flag."""
    return clean_single_line(
        getattr(args, "by", None) or os.environ.get("PT_OPERATOR"), "by"
    )


def cmd_observation_state(args: argparse.Namespace) -> None:
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        obs_id = observation_id(con, args.observation)
        row = con.execute(
            "SELECT state, notes, disposition FROM observation WHERE id=?", (obs_id,)
        ).fetchone()
        link = con.execute(
            "SELECT finding_id FROM finding_observation WHERE observation_id=?",
            (obs_id,),
        ).fetchone()
        if link:
            raise PTError(
                f"{display_observation(obs_id)} is accepted into "
                f"{display_finding(int(link['finding_id']))}; "
                "its state is managed by that canonical link"
            )
        if args.state == "accepted":
            raise PTError(
                "state=accepted is set by 'finding create' or 'finding attach' — "
                "an observation enters the report by being promoted, not relabelled"
            )
        disposition = clean_single_line(args.reason, "reason")
        if args.state == "dismissed" and not disposition:
            raise PTError("--reason is required to dismiss an observation")
        notes = row["notes"]
        if args.state == "proposed":
            # Reopening: the old reason stops being the current disposition but
            # stays readable, so nobody re-dismisses it for a settled reason.
            if row["state"] == "dismissed" and row["disposition"]:
                prefix = f"{notes} | " if notes else ""
                notes = f"{prefix}previously dismissed: {row['disposition']}"
            disposition = None
        con.execute(
            "UPDATE observation SET state=?, disposition=?, notes=?, decided_by=? "
            "WHERE id=?",
            (
                args.state,
                disposition,
                notes,
                decided_by(args) if args.state == "dismissed" else None,
                obs_id,
            ),
        )
        con.commit()
        print(f"{display_observation(obs_id)} state={args.state}")


def cmd_observation_confidence(args: argparse.Namespace) -> None:
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        obs_id = observation_id(con, args.observation)
        con.execute(
            "UPDATE observation SET confidence=? WHERE id=?",
            (args.confidence, obs_id),
        )
        con.commit()
    print(f"{display_observation(obs_id)} confidence={args.confidence}")


def observation_age(recorded_at: str | None) -> str:
    """Coarse age, so a queue entry from ten minutes ago reads differently from
    one nobody has looked at in three weeks."""
    if not recorded_at:
        return "-"
    try:
        stamp = datetime.datetime.strptime(str(recorded_at)[:19], "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return "-"
    seconds = (
        datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - stamp
    ).total_seconds()
    if seconds < 0:
        return "0m"
    if seconds < 3600:
        return f"{int(seconds // 60)}m"
    if seconds < 86400:
        return f"{int(seconds // 3600)}h"
    return f"{int(seconds // 86400)}d"


def observation_rows(
    con: sqlite3.Connection,
    states: Iterable[str],
    segment: str | None = None,
    asset: str | None = None,
    family: str | None = None,
) -> list[sqlite3.Row]:
    states = tuple(states)
    clauses = [f"o.state IN ({','.join('?' for _ in states)})"]
    params: list[object] = list(states)
    if segment:
        clauses.append("lower(s.name)=lower(?)")
        params.append(segment)
    if asset:
        clauses.append("o.asset_id=?")
        params.append(asset_id(con, asset))
    if family:
        clauses.append("o.family=?")
        params.append(normalize_family(family))
    return con.execute(
        f"""
        SELECT o.id, o.state, o.confidence, o.family, o.title, o.updated_at,
               COALESCE(o.disposition, '') AS disposition,
               COALESCE(o.decided_by, '') AS decided_by,
               COALESCE(o.route, '') AS route,
               COALESCE(o.asset_id, 0) AS asset_id,
               s.name AS segment,
               (SELECT COUNT(*) FROM evidence e WHERE e.observation_id=o.id)
                 AS evidence_count,
               (SELECT fo.finding_id FROM finding_observation fo
                 WHERE fo.observation_id=o.id) AS finding_id
        FROM observation o
        JOIN segment s ON s.id=o.segment_id
        WHERE {' AND '.join(clauses)}
        ORDER BY o.id
        """,
        params,
    ).fetchall()


def format_observation_row(row: sqlite3.Row) -> str:
    asset = f" A{int(row['asset_id'])}" if row["asset_id"] else ""
    finding = (
        f" -> {display_finding(int(row['finding_id']))}" if row["finding_id"] else ""
    )
    reason = f" — {clip_text(row['disposition'], 160)}" if row["disposition"] else ""
    return (
        f"{display_observation(int(row['id']))} {row['state']:<9} "
        f"{row['confidence']:<10} {observation_age(row['updated_at']):>4} "
        f"{row['family']} [{row['segment']}]{asset} evidence={row['evidence_count']}"
        f"{finding} — {clip_text(row['title'], 200)}{reason}"
    )


def cmd_observation_list(args: argparse.Namespace) -> None:
    states = (args.state,) if args.state else OBSERVATION_STATES
    with connect() as con:
        rows = observation_rows(con, states, args.segment, args.asset, args.family)
    print(f"Observations ({len(rows)}, state={args.state or 'any'}):")
    for row in rows[: args.limit]:
        print(f"  {format_observation_row(row)}")
    if not rows:
        print("  none")
    if len(rows) > args.limit:
        print(f"  … {len(rows) - args.limit} more; increase --limit")


def cmd_inbox(args: argparse.Namespace) -> None:
    """The operator's review queue.

    Everything an agent captured and nobody has ruled on yet. This is
    deliberately NOT a doctor warning: an agent cannot decide when an
    open-ended exploration is finished, so `proposed` is normal state to leave
    behind, not drift to clear before stopping."""
    with connect() as con:
        rows = observation_rows(con, ("proposed",), args.segment)
    if args.quiet and not rows:
        return
    print(f"Operator review queue: {len(rows)} observation(s) awaiting a decision")
    for row in rows[: args.limit]:
        print(f"  {format_observation_row(row)}")
    if not rows:
        print("  none — nothing is waiting on the operator")
        return
    if len(rows) > args.limit:
        print(f"  … {len(rows) - args.limit} more; increase --limit")
    if not args.quiet:
        print(
            "\nAccept:  ptctl.py finding create --observation O#### …"
            "  (or finding attach F## --observation O####)\n"
            "Dismiss: ptctl.py observation state O#### dismissed --reason '…'\n"
            "Inspect: ptctl.py context resume O####"
        )


def cmd_observation_evidence(args: argparse.Namespace) -> None:
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        obs_id = observation_id(con, args.observation)
        added = register_evidence(
            con, obs_id, args.evidence, args.kind, args.description
        )
        linked = [
            int(row["finding_id"])
            for row in con.execute(
                "SELECT finding_id FROM finding_observation WHERE observation_id=?",
                (obs_id,),
            )
        ]
        for finding_id in linked:
            sync_finding_markdown(con, finding_id)
        con.commit()
        print(f"{display_observation(obs_id)} evidence_added={added}")


def ensure_observations_available(
    con: sqlite3.Connection, refs: Iterable[str]
) -> list[int]:
    ids = [observation_id(con, ref) for ref in refs]
    if len(ids) != len(set(ids)):
        raise PTError("the same observation was supplied more than once")
    for obs_id in ids:
        observation = con.execute(
            """
            SELECT state,
                   (SELECT COUNT(*) FROM evidence e
                    WHERE e.observation_id=o.id) AS evidence_count
            FROM observation o
            WHERE o.id=?
            """,
            (obs_id,),
        ).fetchone()
        if observation["state"] == "dismissed":
            raise PTError(
                f"{display_observation(obs_id)} was dismissed; reopen it with "
                f"'observation state {display_observation(obs_id)} proposed' "
                "before promoting it"
            )
        if int(observation["evidence_count"]) == 0:
            raise PTError(
                f"{display_observation(obs_id)} has no registered evidence; "
                "use 'observation evidence' before linking it to a finding"
            )
        link = con.execute(
            """
            SELECT fo.finding_id, f.slug
            FROM finding_observation fo
            JOIN finding f ON f.id=fo.finding_id
            WHERE fo.observation_id=?
            """,
            (obs_id,),
        ).fetchone()
        if link:
            raise PTError(
                f"{display_observation(obs_id)} is already linked to "
                f"{display_finding(int(link['finding_id']))} ({link['slug']})"
            )
    return ids


def ensure_observation_segments(
    con: sqlite3.Connection, observation_ids: list[int], expected_segment_id: int
) -> None:
    placeholders = ",".join("?" for _ in observation_ids)
    mismatches = con.execute(
        f"""
        SELECT o.id, s.name
        FROM observation o
        JOIN segment s ON s.id=o.segment_id
        WHERE o.id IN ({placeholders}) AND o.segment_id<>?
        ORDER BY o.id
        """,
        (*observation_ids, expected_segment_id),
    ).fetchall()
    if mismatches:
        detail = ", ".join(
            f"{display_observation(int(row['id']))} ({row['name']})"
            for row in mismatches
        )
        expected = segment_name(con, expected_segment_id)
        raise PTError(
            f"observation segment mismatch: finding segment={expected}, got {detail}"
        )


def related_findings(
    con: sqlite3.Connection, observation_ids: list[int]
) -> list[sqlite3.Row]:
    placeholders = ",".join("?" for _ in observation_ids)
    return con.execute(
        f"""
        SELECT DISTINCT f.id, f.slug, f.group_key
        FROM finding f
        JOIN finding_observation fo ON fo.finding_id=f.id
        JOIN observation existing_o ON existing_o.id=fo.observation_id
        JOIN observation candidate_o
          ON candidate_o.id IN ({placeholders})
         AND candidate_o.segment_id=existing_o.segment_id
         AND lower(candidate_o.family)=lower(existing_o.family)
         AND lower(COALESCE(candidate_o.component, ''))=
             lower(COALESCE(existing_o.component, ''))
         AND lower(COALESCE(candidate_o.boundary, ''))=
             lower(COALESCE(existing_o.boundary, ''))
        WHERE f.lifecycle IN ('draft','confirmed')
        ORDER BY f.id
        """,
        observation_ids,
    ).fetchall()


def cmd_finding_create(args: argparse.Namespace) -> None:
    slug = clean_single_line(args.slug, "slug")
    if not slug or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", slug):
        raise PTError("--slug must be short-kebab-case")
    title = clean_single_line(args.title, "title")
    if not title:
        raise PTError("--title is required")
    group_key = normalize_group_key(args.group_key)
    severity = args.severity.upper()
    cwe = clean_single_line(args.cwe, "CWE")

    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        seg_id = segment_id(con, args.segment)
        obs_ids = ensure_observations_available(con, args.observation)
        ensure_observation_segments(con, obs_ids, seg_id)
        explicit_asset_ids = [asset_id(con, ref) for ref in args.asset]
        duplicate = con.execute(
            """
            SELECT id, slug FROM finding
            WHERE group_key=? AND lifecycle IN ('draft','confirmed')
            """,
            (group_key,),
        ).fetchone()
        if duplicate:
            raise PTError(
                f"group key already belongs to "
                f"{display_finding(int(duplicate['id']))} ({duplicate['slug']}); "
                "attach the observation instead of creating a duplicate"
            )
        related = related_findings(con, obs_ids)
        if related and not args.allow_related:
            candidates = ", ".join(
                f"{display_finding(int(row['id']))} ({row['slug']}, "
                f"group_key={row['group_key'] or '<missing>'})"
                for row in related
            )
            raise PTError(
                "related observation profile already belongs to "
                f"{candidates}; inspect and attach to the canonical finding. "
                "Use --allow-related only after documenting why the root cause "
                "or remediation is genuinely different"
            )
        if con.execute("SELECT 1 FROM finding WHERE slug=?", (slug,)).fetchone():
            raise PTError(f"finding slug '{slug}' already exists")

        findings_dir = ROOT / "findings"
        poc_path = ROOT / "poc" / slug
        writeup_path = findings_dir / f"{slug}.md"
        if writeup_path.exists() or poc_path.exists():
            raise PTError(f"filesystem target already exists for slug '{slug}'")

        cursor = con.execute(
            """
            INSERT INTO finding
              (slug, group_key, title, severity, status, lifecycle, cwe, segment_id)
            VALUES (?, ?, ?, ?, ?, 'confirmed', ?, ?)
            """,
            (slug, group_key, title, severity, args.status, cwe, seg_id),
        )
        finding_id = int(cursor.lastrowid)
        for obs_id in obs_ids:
            con.execute(
                """
                INSERT INTO finding_observation (observation_id, finding_id)
                VALUES (?, ?)
                """,
                (obs_id, finding_id),
            )
            con.execute(
                "UPDATE observation SET state='accepted', decided_by=? WHERE id=?",
                (decided_by(args), obs_id),
            )
        derived_asset_ids = [
            int(row["asset_id"])
            for row in con.execute(
                f"""
                SELECT DISTINCT asset_id
                FROM observation
                WHERE id IN ({','.join('?' for _ in obs_ids)})
                  AND asset_id IS NOT NULL
                """,
                obs_ids,
            )
        ]
        for linked_asset_id in dict.fromkeys(explicit_asset_ids + derived_asset_ids):
            con.execute(
                """
                INSERT OR IGNORE INTO finding_asset (finding_id, asset_id)
                VALUES (?, ?)
                """,
                (finding_id, linked_asset_id),
            )
        row = con.execute("SELECT * FROM finding WHERE id=?", (finding_id,)).fetchone()
        try:
            content = initial_writeup(con, row)
            poc_path.mkdir(parents=True)
            write_atomic(writeup_path, content)
            con.commit()
        except Exception:
            con.rollback()
            if writeup_path.exists():
                writeup_path.unlink()
            try:
                poc_path.rmdir()
            except OSError:
                pass
            raise

        render_report()
        print(
            f"created {display_finding(finding_id)} ({slug}) "
            f"group_key={group_key} observations="
            + ",".join(display_observation(value) for value in obs_ids)
        )


def cmd_finding_attach(args: argparse.Namespace) -> None:
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        finding = finding_row(con, args.finding)
        if finding["lifecycle"] not in ACTIVE_LIFECYCLES:
            raise PTError("observations can only be attached to an active finding")
        if finding["segment_id"] is None:
            raise PTError("active finding has no segment; repair it before attaching")
        obs_ids = ensure_observations_available(con, args.observation)
        ensure_observation_segments(con, obs_ids, int(finding["segment_id"]))
        for obs_id in obs_ids:
            con.execute(
                "INSERT INTO finding_observation (observation_id, finding_id) VALUES (?,?)",
                (obs_id, int(finding["id"])),
            )
            con.execute(
                "UPDATE observation SET state='accepted', decided_by=? WHERE id=?",
                (decided_by(args), obs_id),
            )
            linked_asset = con.execute(
                "SELECT asset_id FROM observation WHERE id=?", (obs_id,)
            ).fetchone()["asset_id"]
            if linked_asset is not None:
                con.execute(
                    """
                    INSERT OR IGNORE INTO finding_asset (finding_id, asset_id)
                    VALUES (?, ?)
                    """,
                    (int(finding["id"]), int(linked_asset)),
                )
        sync_finding_markdown(con, int(finding["id"]))
        con.commit()
        print(
            f"attached {','.join(display_observation(value) for value in obs_ids)} "
            f"to {display_finding(int(finding['id']))}"
        )


def cmd_finding_asset(args: argparse.Namespace) -> None:
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        finding = finding_row(con, args.finding)
        if finding["lifecycle"] not in ACTIVE_LIFECYCLES:
            raise PTError("assets can only be changed on an active finding")
        if not args.add and not args.remove:
            raise PTError("supply at least one --add or --remove asset")
        add_ids = [asset_id(con, ref) for ref in args.add]
        remove_ids = [asset_id(con, ref) for ref in args.remove]
        if set(add_ids) & set(remove_ids):
            raise PTError("the same asset cannot be added and removed together")

        finding_id = int(finding["id"])
        for linked_asset_id in add_ids:
            con.execute(
                """
                INSERT OR IGNORE INTO finding_asset (finding_id, asset_id)
                VALUES (?, ?)
                """,
                (finding_id, linked_asset_id),
            )
        for linked_asset_id in remove_ids:
            required = con.execute(
                """
                SELECT 1
                FROM finding_observation fo
                JOIN observation o ON o.id=fo.observation_id
                WHERE fo.finding_id=? AND o.asset_id=?
                LIMIT 1
                """,
                (finding_id, linked_asset_id),
            ).fetchone()
            if required:
                raise PTError(
                    f"A{linked_asset_id} is referenced by a linked observation "
                    "and cannot be removed"
                )
            con.execute(
                "DELETE FROM finding_asset WHERE finding_id=? AND asset_id=?",
                (finding_id, linked_asset_id),
            )
        sync_finding_markdown(con, finding_id)
        con.commit()
        print(
            f"updated assets for {display_finding(finding_id)}: "
            f"add={','.join(f'A{value}' for value in add_ids) or '-'} "
            f"remove={','.join(f'A{value}' for value in remove_ids) or '-'}"
        )


def cmd_finding_update(args: argparse.Namespace) -> None:
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        finding = finding_row(con, args.finding)
        if finding["lifecycle"] not in ACTIVE_LIFECYCLES:
            raise PTError("only an active finding can be updated")
        updates: dict[str, object] = {}
        if args.title is not None:
            updates["title"] = clean_single_line(args.title, "title")
        if args.severity is not None:
            updates["severity"] = args.severity.upper()
        if args.status is not None:
            updates["status"] = args.status
        if args.cwe is not None:
            updates["cwe"] = clean_single_line(args.cwe, "CWE")
        if args.group_key is not None:
            updates["group_key"] = normalize_group_key(args.group_key)
        if args.segment is not None:
            new_segment_id = segment_id(con, args.segment)
            linked_ids = [
                int(row["observation_id"])
                for row in con.execute(
                    """
                    SELECT observation_id
                    FROM finding_observation
                    WHERE finding_id=?
                    """,
                    (int(finding["id"]),),
                )
            ]
            if linked_ids:
                ensure_observation_segments(con, linked_ids, new_segment_id)
            updates["segment_id"] = new_segment_id
        if not updates:
            raise PTError("no update supplied")
        assignments = ", ".join(f"{column}=?" for column in updates)
        try:
            con.execute(
                f"UPDATE finding SET {assignments} WHERE id=?",
                (*updates.values(), int(finding["id"])),
            )
            sync_finding_markdown(con, int(finding["id"]))
            con.commit()
        except sqlite3.IntegrityError as exc:
            raise PTError(f"finding update violates an invariant: {exc}") from exc
        render_report()
        print(f"updated {display_finding(int(finding['id']))}: {', '.join(updates)}")


def cmd_finding_merge(args: argparse.Namespace) -> None:
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        source = finding_row(con, args.source)
        target = finding_row(con, args.into)
        if int(source["id"]) == int(target["id"]):
            raise PTError("source and target finding are the same")
        if source["lifecycle"] not in ACTIVE_LIFECYCLES:
            raise PTError("source finding is not active")
        if target["lifecycle"] not in ACTIVE_LIFECYCLES:
            raise PTError("target finding is not active")
        if source["segment_id"] != target["segment_id"]:
            raise PTError("findings in different segments cannot be merged")

        source_id = int(source["id"])
        target_id = int(target["id"])
        con.execute(
            "UPDATE finding_observation SET finding_id=? WHERE finding_id=?",
            (target_id, source_id),
        )
        con.execute(
            """
            INSERT OR IGNORE INTO finding_asset (finding_id, asset_id)
            SELECT ?, asset_id FROM finding_asset WHERE finding_id=?
            """,
            (target_id, source_id),
        )
        con.execute("DELETE FROM finding_asset WHERE finding_id=?", (source_id,))
        con.execute(
            """
            UPDATE finding
            SET lifecycle='merged', canonical_finding_id=?
            WHERE id=?
            """,
            (target_id, source_id),
        )
        sync_finding_markdown(con, source_id)
        sync_finding_markdown(con, target_id)
        con.commit()
        render_report()
        print(
            f"merged {display_finding(source_id)} into {display_finding(target_id)}; "
            "source write-up/PoC retained as audit history"
        )


def parse_markdown_metadata(text: str) -> dict[str, str]:
    metadata: dict[str, str] = {}
    for label in REQUIRED_MD_LABELS:
        match = re.search(
            rf"^- \*\*{re.escape(label)}\*\*:\s*(.*)$", text, re.MULTILINE
        )
        if match:
            metadata[label] = match.group(1).strip().strip("`")
    title = re.search(r"^# (.+)$", text, re.MULTILINE)
    if title:
        metadata["Title"] = title.group(1).strip()
    return metadata


def activity_file() -> Path | None:
    matches = []
    for path in ROOT.glob("*.md"):
        try:
            # Use the assets marker, matching render.sh. AGENTS.md legitimately
            # names the findings marker while documenting the rendered index.
            if "<!-- db:render assets -->" in path.read_text(
                encoding="utf-8", errors="replace"
            ):
                matches.append(path)
        except OSError:
            continue
    return matches[0] if len(matches) == 1 else None


PRIORITY_REFERENCE_DOMAINS = (
    "cheatsheetseries.owasp.org",
    "portswigger.net/web-security",
)
MIN_EXTERNAL_REFERENCES = 3


def reference_warnings(text: str, label: str) -> list[str]:
    """Policy for a finding's ## References section: at least
    MIN_EXTERNAL_REFERENCES external links, at least one from a priority domain.
    Returned as warnings (fatal only under `doctor --strict`)."""
    section: list[str] = []
    in_section = False
    for line in text.splitlines():
        if re.match(r"^##\s+References\b", line):
            in_section = True
            continue
        if in_section and re.match(r"^##\s+\S", line):
            break
        if in_section:
            section.append(line)
    urls = [line for line in section if re.search(r"https?://", line)]
    list_items = [line for line in section if re.match(r"\s*[-*]\s+\S", line)]
    non_link = [line for line in list_items if not re.search(r"https?://", line)]
    problems: list[str] = []
    if len(urls) < MIN_EXTERNAL_REFERENCES:
        problems.append(
            f"{label} ## References has {len(urls)} external reference(s); "
            f"at least {MIN_EXTERNAL_REFERENCES} required"
        )
    if non_link:
        problems.append(
            f"{label} ## References has {len(non_link)} reference line(s) "
            "without a link; every reference must be a URL/link"
        )
    if urls and not any(
        domain in line for line in urls for domain in PRIORITY_REFERENCE_DOMAINS
    ):
        problems.append(
            f"{label} ## References must include at least one link from "
            + " or ".join(PRIORITY_REFERENCE_DOMAINS)
        )
    return problems


HTTP_REQUEST_KIND = "http-request"
HTTP_REQUEST_LINE = re.compile(r"^[A-Z]+\s+\S+\s+HTTP/\d", re.MULTILINE)
NO_HTTP_REQUEST_OPTOUT = re.compile(r"<!--\s*no-http-request:\s*\S.*?-->", re.DOTALL)


def http_request_warnings(
    con: sqlite3.Connection, finding_id: int, text: str, label: str
) -> list[str]:
    """A complete HTTP request is mandatory evidence for every active finding, so
    the client has a real, confirmed-working request at patch time. Requires >=1
    evidence of kind 'http-request' whose file has a valid request line, unless
    the write-up carries a `<!-- no-http-request: reason -->` opt-out. Warnings
    here are blocking under --hook and fatal under --strict."""
    if NO_HTTP_REQUEST_OPTOUT.search(text):
        return []
    rows = con.execute(
        """
        SELECT DISTINCT e.path
        FROM finding_observation fo
        JOIN evidence e ON e.observation_id=fo.observation_id
        WHERE fo.finding_id=? AND e.kind=?
        ORDER BY e.path
        """,
        (finding_id, HTTP_REQUEST_KIND),
    ).fetchall()
    if not rows:
        return [
            f"{label} has no HTTP request evidence; a complete HTTP request is "
            "mandatory (register one with kind=http-request, or add "
            "<!-- no-http-request: reason --> to the write-up)"
        ]
    for row in rows:
        src = ROOT / row["path"]
        if src.is_file() and HTTP_REQUEST_LINE.search(
            src.read_text(encoding="utf-8", errors="replace")
        ):
            return []
    return [
        f"{label} HTTP request evidence is incomplete: no registered http-request "
        "file has a valid request line (METHOD path HTTP/x.y)"
    ]


def doctor(con: sqlite3.Connection) -> tuple[list[str], list[str], list[str]]:
    """Defects in the deliverable — never work in progress.

    Everything reported here is something that would ship broken: drift between
    the DB and the write-ups, evidence that moved or changed, an obligation left
    on the client's systems, a finding without a replayable request. An
    observation nobody has ruled on yet is none of those things, so it is a
    notice (see `ptctl.py inbox`) that never blocks and never fails --strict.
    A check that fires on normal work is a check everyone learns to ignore."""
    errors: list[str] = []
    warnings: list[str] = []
    notices: list[str] = []
    rows = con.execute(
        """
        SELECT f.*, COALESCE(s.name, '') AS segment
        FROM finding f
        LEFT JOIN segment s ON s.id=f.segment_id
        ORDER BY f.id
        """
    ).fetchall()
    db_slugs = {row["slug"] for row in rows}
    active_rows = [row for row in rows if row["lifecycle"] in ACTIVE_LIFECYCLES]

    findings_dir = ROOT / "findings"
    file_slugs = {
        path.stem
        for path in findings_dir.glob("*.md")
        if path.name != "_template.md"
    }
    for slug in sorted(file_slugs - db_slugs):
        errors.append(f"orphan write-up findings/{slug}.md has no DB row")
    for row in rows:
        finding_id = int(row["id"])
        label = display_finding(finding_id)
        writeup = ROOT / (
            row["evidence_path"] or f"findings/{row['slug']}.md"
        )
        poc_dir = ROOT / (row["poc_dir"] or f"poc/{row['slug']}/")
        if not writeup.is_file():
            errors.append(f"{label} DB row has no write-up: {writeup.relative_to(ROOT)}")
            continue
        if not poc_dir.is_dir():
            errors.append(f"{label} DB row has no PoC directory: {poc_dir.relative_to(ROOT)}")

        text = writeup.read_text(encoding="utf-8", errors="replace")
        metadata = parse_markdown_metadata(text)
        for required in REQUIRED_MD_LABELS:
            if required not in metadata:
                errors.append(f"{label} write-up missing metadata field '{required}'")
        expected = {
            "Title": row["title"],
            "Vuln_ID": row["slug"],
            "Group key": row["group_key"] or "<missing>",
            "Severity": row["severity"],
            "Status": row["status"],
            "Affected asset(s)": affected_assets(con, finding_id),
            "Related CWE(s)": row["cwe"] or "<fill CWE>",
            "Segment": row["segment"] or "<missing>",
            "Observation(s)": observation_refs(con, finding_id),
        }
        for field, value in expected.items():
            if field in metadata and metadata[field] != value:
                errors.append(
                    f"{label} {field} drift: DB='{value}' Markdown='{metadata[field]}'"
                )
        evidence_match = re.search(
            re.escape(EVIDENCE_START)
            + r"\s*\n(.*?)\n\s*"
            + re.escape(EVIDENCE_END),
            text,
            re.DOTALL,
        )
        if not evidence_match:
            errors.append(f"{label} write-up missing ptctl evidence markers")
        else:
            rendered_evidence = evidence_match.group(1).strip()
            expected_evidence = evidence_markdown(con, finding_id).strip()
            if rendered_evidence != expected_evidence:
                errors.append(f"{label} managed evidence block drift")
        if row["lifecycle"] in ACTIVE_LIFECYCLES:
            warnings.extend(reference_warnings(text, label))
            warnings.extend(http_request_warnings(con, finding_id, text, label))
        if row["lifecycle"] in ACTIVE_LIFECYCLES and not row["group_key"]:
            errors.append(f"{label} active finding has no group_key (legacy row)")
        if row["lifecycle"] in ACTIVE_LIFECYCLES and row["segment_id"] is None:
            errors.append(f"{label} active finding has no segment")

        obs_count = con.execute(
            "SELECT COUNT(*) AS n FROM finding_observation WHERE finding_id=?",
            (finding_id,),
        ).fetchone()["n"]
        evidence_count = con.execute(
            """
            SELECT COUNT(*) AS n
            FROM evidence e
            JOIN finding_observation fo ON fo.observation_id=e.observation_id
            WHERE fo.finding_id=?
            """,
            (finding_id,),
        ).fetchone()["n"]
        if row["lifecycle"] == "confirmed" and obs_count == 0:
            errors.append(f"{label} confirmed finding has no linked observation")
        if row["lifecycle"] == "confirmed" and evidence_count == 0:
            errors.append(f"{label} confirmed finding has no registered evidence")

    for row in con.execute("SELECT * FROM evidence ORDER BY id"):
        path = ROOT / row["path"]
        if not path.is_file():
            errors.append(f"evidence E{int(row['id']):04d} missing file: {row['path']}")
        elif sha256_file(path) != row["sha256"]:
            errors.append(
                f"evidence E{int(row['id']):04d} checksum drift: {row['path']}"
            )

    for row in con.execute(
        """
        SELECT o.id, o.state, COALESCE(o.disposition, '') AS disposition,
               (SELECT COUNT(*) FROM finding_observation fo
                WHERE fo.observation_id=o.id) AS links,
               (SELECT COUNT(*) FROM evidence e
                WHERE e.observation_id=o.id) AS evidence_count
        FROM observation o
        ORDER BY o.id
        """
    ):
        label = display_observation(int(row["id"]))
        if row["state"] == "accepted" and row["links"] != 1:
            errors.append(
                f"{label} state=accepted but the canonical finding link is missing"
            )
        if row["links"] == 1 and row["state"] != "accepted":
            errors.append(
                f"{label} has a canonical finding link but state={row['state']}"
            )
        if row["state"] == "dismissed" and not row["disposition"]:
            warnings.append(f"{label} was dismissed without a recorded reason")
        if row["state"] == "accepted" and row["evidence_count"] == 0:
            warnings.append(f"{label} has no registered evidence")

    for row in con.execute(
        """
        SELECT o.id AS observation_id, o.asset_id, fo.finding_id
        FROM finding_observation fo
        JOIN observation o ON o.id=fo.observation_id
        LEFT JOIN finding_asset fa
          ON fa.finding_id=fo.finding_id AND fa.asset_id=o.asset_id
        WHERE o.asset_id IS NOT NULL AND fa.asset_id IS NULL
        ORDER BY o.id
        """
    ):
        errors.append(
            f"{display_observation(int(row['observation_id']))} asset "
            f"A{int(row['asset_id'])} is not linked to "
            f"{display_finding(int(row['finding_id']))}"
        )

    for row in con.execute(
        """
        SELECT o.id AS observation_id, fo.finding_id,
               os.name AS observation_segment, fs.name AS finding_segment
        FROM finding_observation fo
        JOIN observation o ON o.id=fo.observation_id
        JOIN finding f ON f.id=fo.finding_id
        JOIN segment os ON os.id=o.segment_id
        LEFT JOIN segment fs ON fs.id=f.segment_id
        WHERE f.segment_id IS NULL OR o.segment_id<>f.segment_id
        ORDER BY o.id
        """
    ):
        errors.append(
            f"{display_observation(int(row['observation_id']))} segment "
            f"{row['observation_segment']} differs from "
            f"{display_finding(int(row['finding_id']))} segment "
            f"{row['finding_segment'] or '<missing>'}"
        )

    registered_poc = {
        (ROOT / (row["poc_dir"] or f"poc/{row['slug']}/")).resolve()
        for row in rows
    }
    poc_root = ROOT / "poc"
    if poc_root.is_dir():
        for path in sorted(item for item in poc_root.iterdir() if item.is_dir()):
            if path.resolve() not in registered_poc:
                referenced = con.execute(
                    "SELECT 1 FROM evidence WHERE path LIKE ? LIMIT 1",
                    (f"{path.relative_to(ROOT).as_posix()}/%",),
                ).fetchone()
                if not referenced:
                    warnings.append(
                        f"unregistered PoC directory: {path.relative_to(ROOT)}"
                    )

    total_assets = con.execute("SELECT COUNT(*) AS n FROM asset").fetchone()["n"]
    if total_assets:
        for row in active_rows:
            links = con.execute(
                "SELECT COUNT(*) AS n FROM finding_asset WHERE finding_id=?",
                (int(row["id"]),),
            ).fetchone()["n"]
            if links == 0:
                warnings.append(
                    f"{display_finding(int(row['id']))} has no finding_asset link"
                )

    activity = activity_file()
    if activity is None:
        errors.append("could not identify exactly one root activity Markdown file")
    else:
        text = activity.read_text(encoding="utf-8", errors="replace")
        index: dict[int, tuple[str, str, str]] = {}
        pattern = re.compile(
            r"^\|\s*F(\d+)\s*\|\s*([A-Z]+)\s*\|.*?"
            r"\]\(([^)]+)\)\s*\|\s*([^|]+)\|",
            re.MULTILINE,
        )
        for match in pattern.finditer(text):
            index[int(match.group(1))] = (
                match.group(2).strip(),
                match.group(3).strip(),
                match.group(4).strip(),
            )
        expected_ids = {
            int(row["id"]) for row in rows if row["lifecycle"] == "confirmed"
        }
        if set(index) != expected_ids:
            missing = sorted(expected_ids - set(index))
            extra = sorted(set(index) - expected_ids)
            if missing:
                errors.append(
                    "rendered index missing "
                    + ", ".join(display_finding(value) for value in missing)
                )
            if extra:
                errors.append(
                    "rendered index contains inactive "
                    + ", ".join(display_finding(value) for value in extra)
                )
        for row in active_rows:
            finding_id = int(row["id"])
            if row["lifecycle"] != "confirmed" or finding_id not in index:
                continue
            severity, link, status = index[finding_id]
            expected_link = row["evidence_path"] or f"findings/{row['slug']}.md"
            if severity != row["severity"]:
                errors.append(
                    f"{display_finding(finding_id)} index severity drift: "
                    f"DB={row['severity']} index={severity}"
                )
            if link != expected_link:
                errors.append(
                    f"{display_finding(finding_id)} index link drift: "
                    f"DB={expected_link} index={link}"
                )
            if status != row["status"]:
                errors.append(
                    f"{display_finding(finding_id)} index status drift: "
                    f"DB={row['status']} index={status}"
                )

    open_cleanup = con.execute(
        "SELECT id, what FROM cleanup WHERE state='open' ORDER BY id"
    ).fetchall()
    if open_cleanup:
        preview = ", ".join(
            display_cleanup(int(row["id"])) for row in open_cleanup[:10]
        )
        suffix = "…" if len(open_cleanup) > 10 else ""
        warnings.append(
            f"{len(open_cleanup)} cleanup obligation(s) still open "
            f"({preview}{suffix}); undo them on the target, then "
            "`ptctl.py cleanup done C##`"
        )

    journal = ROOT / "journal.md"
    if journal.is_file():
        unreferenced: list[int] = []
        ref_pattern = re.compile(r"(?:\[?(?:O\d{4}|F\d{2,})\]?)", re.IGNORECASE)
        for number, line in enumerate(
            journal.read_text(encoding="utf-8", errors="replace").splitlines(), 1
        ):
            if "#observation" in line and not ref_pattern.search(line):
                unreferenced.append(number)
        if unreferenced:
            preview = ", ".join(str(value) for value in unreferenced[:10])
            suffix = "…" if len(unreferenced) > 10 else ""
            warnings.append(
                f"journal has {len(unreferenced)} #observation entries without "
                f"O/F reference (lines {preview}{suffix})"
            )

    queued = con.execute(
        "SELECT COUNT(*) AS n FROM observation WHERE state='proposed'"
    ).fetchone()["n"]
    if queued:
        notices.append(
            f"{queued} observation(s) awaiting operator review "
            "(`ptctl.py inbox`) — a queue, not a defect"
        )

    return errors, warnings, notices


def cmd_poc_sync(args: argparse.Namespace) -> None:
    with connect() as con:
        if args.finding:
            findings = [finding_row(con, args.finding)]
        else:
            findings = con.execute(
                "SELECT * FROM finding "
                "WHERE lifecycle IN ('draft','confirmed') ORDER BY id"
            ).fetchall()
        copied = updated = skipped = 0
        for row in findings:
            slug = row["slug"]
            poc_dir = ROOT / (row["poc_dir"] or f"poc/{slug}/")
            poc_dir.mkdir(parents=True, exist_ok=True)
            evidence = con.execute(
                """
                SELECT DISTINCT e.path
                FROM finding_observation fo
                JOIN evidence e ON e.observation_id=fo.observation_id
                WHERE fo.finding_id=? AND e.kind='poc'
                ORDER BY e.path
                """,
                (int(row["id"]),),
            ).fetchall()
            # basename -> source path already materialized this run, so a second
            # source sharing a basename is disambiguated instead of overwriting.
            claimed: "dict[str, str]" = {}
            for record in evidence:
                rel = record["path"]
                src = ROOT / rel
                if not src.is_file():
                    continue  # evidence missing on disk; doctor covers that drift
                name = Path(rel).name
                if claimed.get(name, rel) != rel:
                    name = f"{Path(rel).parent.name}__{name}"
                claimed[name] = rel
                dest = poc_dir / name
                if dest.exists() and sha256_file(dest) == sha256_file(src):
                    skipped += 1
                    continue
                existed = dest.exists()
                shutil.copy2(src, dest)
                if existed:
                    updated += 1
                else:
                    copied += 1
        print(f"poc sync: {copied} copied, {updated} updated, {skipped} unchanged")


def cmd_doctor(args: argparse.Namespace) -> None:
    with connect() as con:
        errors, warnings, notices = doctor(con)
    if not args.quiet or errors or warnings or notices:
        print(f"ptctl doctor: {len(errors)} error(s), {len(warnings)} warning(s)")
        for message in errors:
            print(f"ERROR: {message}")
        for message in warnings:
            print(f"WARN: {message}")
        for message in notices:
            print(f"NOTE: {message}")
    # Notices never affect the exit code, including under --strict: the report
    # freeze gates on the deliverable, not on how much the operator has triaged.
    if errors or (args.strict and warnings):
        raise SystemExit(1)


def cmd_board(args: argparse.Namespace) -> None:
    with connect() as con:
        print("--- PT finding board ---")
        findings = con.execute(
            """
            SELECT f.id, f.severity, f.title, f.group_key, f.status,
                   COUNT(fo.observation_id) AS occurrences
            FROM finding f
            LEFT JOIN finding_observation fo ON fo.finding_id=f.id
            WHERE f.lifecycle='confirmed'
            GROUP BY f.id
            ORDER BY CASE f.severity
                       WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2
                       WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 4 ELSE 5
                     END, f.id
            LIMIT ?
            """,
            (args.limit,),
        ).fetchall()
        if findings:
            print("Confirmed findings:")
            for row in findings:
                key = row["group_key"] or "<missing-group-key>"
                print(
                    f"  {display_finding(int(row['id']))} {row['severity']:<13} "
                    f"[{key}] occurrences={row['occurrences']} — {row['title']}"
                )
        else:
            print("Confirmed findings: none")

        observations = observation_rows(con, ("proposed",))
        if observations:
            print("Awaiting operator review:")
            for row in observations[: args.limit]:
                print(f"  {format_observation_row(row)}")
            if len(observations) > args.limit:
                print(f"  … {len(observations) - args.limit} more; increase --limit")
        else:
            print("Awaiting operator review: none")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ptctl.py",
        description="Idempotent observation/finding registry for this engagement",
    )
    top = parser.add_subparsers(dest="entity", required=True)

    observation = top.add_parser(
        "observation", help="capture what was seen; the operator rules on it later"
    )
    observation_commands = observation.add_subparsers(dest="command", required=True)

    add = observation_commands.add_parser("add")
    add.add_argument("--title", required=True)
    add.add_argument("--family", required=True)
    add.add_argument("--segment", required=True)
    add.add_argument("--asset", help="asset reference, for example A1")
    add.add_argument("--component")
    add.add_argument("--boundary")
    add.add_argument("--method")
    add.add_argument("--route")
    add.add_argument("--selector")
    add.add_argument("--attacker-role")
    add.add_argument("--target-role")
    add.add_argument("--source")
    add.add_argument("--notes")
    add.add_argument(
        "--confidence",
        choices=OBSERVATION_CONFIDENCE,
        default="suspected",
        help="'reproduced' only if you actually reproduced it in this session",
    )
    add.add_argument(
        "--from-http",
        metavar="FILE",
        help="saved raw HTTP request: derives --method/--route/--selector and "
        "registers the file as http-request evidence",
    )
    add.add_argument("--fingerprint")
    add.add_argument("--evidence", action="append", default=[])
    add.add_argument("--kind")
    add.add_argument("--description")
    add.set_defaults(func=cmd_observation_add)

    observation_list = observation_commands.add_parser(
        "list", help="read the registry back, dismissals and their reasons included"
    )
    observation_list.add_argument("--state", choices=OBSERVATION_STATES)
    observation_list.add_argument("--segment")
    observation_list.add_argument("--asset", help="A1")
    observation_list.add_argument("--family")
    observation_list.add_argument("--limit", type=positive_int, default=40)
    observation_list.set_defaults(func=cmd_observation_list)

    confidence = observation_commands.add_parser(
        "confidence", help="record whether the behaviour was actually reproduced"
    )
    confidence.add_argument("observation", help="O0001")
    confidence.add_argument("confidence", choices=OBSERVATION_CONFIDENCE)
    confidence.set_defaults(func=cmd_observation_confidence)

    state = observation_commands.add_parser("state")
    state.add_argument("observation")
    state.add_argument("state", choices=OBSERVATION_STATES)
    state.add_argument("--reason")
    state.add_argument(
        "--by", help="who ruled on it; defaults to $PT_OPERATOR when set"
    )
    state.set_defaults(func=cmd_observation_state)

    evidence = observation_commands.add_parser("evidence")
    evidence.add_argument("observation")
    evidence.add_argument("--evidence", action="append", required=True)
    evidence.add_argument("--kind")
    evidence.add_argument("--description")
    evidence.set_defaults(func=cmd_observation_evidence)

    finding = top.add_parser("finding")
    finding_commands = finding.add_subparsers(dest="command", required=True)

    create = finding_commands.add_parser("create")
    create.add_argument("--slug", required=True)
    create.add_argument("--group-key", required=True)
    create.add_argument("--title", required=True)
    create.add_argument("--severity", required=True, choices=SEVERITIES)
    create.add_argument("--status", default="open", choices=STATUSES)
    create.add_argument("--cwe")
    create.add_argument("--segment", required=True)
    create.add_argument(
        "--allow-related",
        action="store_true",
        help="override the related-profile guard after a documented review",
    )
    create.add_argument(
        "--asset", action="append", default=[], help="additional affected asset"
    )
    create.add_argument("--observation", action="append", required=True)
    create.add_argument(
        "--by", help="who accepted it; defaults to $PT_OPERATOR when set"
    )
    create.set_defaults(func=cmd_finding_create)

    attach = finding_commands.add_parser("attach")
    attach.add_argument("finding")
    attach.add_argument("--observation", action="append", required=True)
    attach.add_argument(
        "--by", help="who accepted it; defaults to $PT_OPERATOR when set"
    )
    attach.set_defaults(func=cmd_finding_attach)

    finding_asset = finding_commands.add_parser("asset")
    finding_asset.add_argument("finding")
    finding_asset.add_argument("--add", action="append", default=[])
    finding_asset.add_argument("--remove", action="append", default=[])
    finding_asset.set_defaults(func=cmd_finding_asset)

    update = finding_commands.add_parser("update")
    update.add_argument("finding")
    update.add_argument("--title")
    update.add_argument("--severity", choices=SEVERITIES)
    update.add_argument("--status", choices=STATUSES)
    update.add_argument("--cwe")
    update.add_argument("--segment")
    update.add_argument("--group-key")
    update.set_defaults(func=cmd_finding_update)

    merge = finding_commands.add_parser("merge")
    merge.add_argument("source")
    merge.add_argument("--into", required=True)
    merge.set_defaults(func=cmd_finding_merge)

    poc = top.add_parser("poc")
    poc_commands = poc.add_subparsers(dest="command", required=True)
    poc_sync = poc_commands.add_parser("sync")
    poc_sync.add_argument(
        "finding",
        nargs="?",
        help="sync only this finding (F-id or slug); default: all findings",
    )
    poc_sync.set_defaults(func=cmd_poc_sync)

    inbox = top.add_parser(
        "inbox",
        help="observations captured by agents and still awaiting an operator decision",
    )
    inbox.add_argument("--segment")
    inbox.add_argument("--limit", type=positive_int, default=25)
    inbox.add_argument(
        "--quiet", action="store_true", help="print nothing when the queue is empty"
    )
    inbox.set_defaults(func=cmd_inbox)

    doctor_parser = top.add_parser("doctor")
    doctor_parser.add_argument("--strict", action="store_true")
    doctor_parser.add_argument("--quiet", action="store_true")
    doctor_parser.set_defaults(func=cmd_doctor)

    board = top.add_parser("board")
    board.add_argument("--limit", type=int, default=30)
    board.set_defaults(func=cmd_board)

    context = top.add_parser(
        "context",
        help="load bounded engagement context using progressive disclosure",
    )
    context_commands = context.add_subparsers(dest="command", required=True)

    context_boot = context_commands.add_parser(
        "boot", help="render the small context used at session start"
    )
    context_boot.add_argument(
        "--max-chars", type=positive_int, default=DEFAULT_BOOT_CHARS
    )
    context_boot.add_argument("--task-limit", type=positive_int, default=8)
    context_boot.set_defaults(func=cmd_context_boot)

    context_explain = context_commands.add_parser(
        "explain", help="show exactly what boot context includes and excludes"
    )
    context_explain.add_argument(
        "--max-chars", type=positive_int, default=DEFAULT_BOOT_CHARS
    )
    context_explain.add_argument("--task-limit", type=positive_int, default=8)
    context_explain.set_defaults(func=cmd_context_explain)

    context_pending = context_commands.add_parser(
        "pending", help="show open TODO items without completed task history"
    )
    context_pending.add_argument("--segment")
    context_pending.add_argument("--limit", type=positive_int, default=30)
    context_pending.set_defaults(func=cmd_context_pending)

    context_focus = context_commands.add_parser(
        "focus",
        help="orient on a topic without loading prior prose or evidence bodies",
    )
    context_focus.add_argument("--topic", required=True)
    context_focus.add_argument("--segment")
    context_focus.add_argument("--limit", type=positive_int, default=12)
    context_focus.add_argument(
        "--max-chars", type=positive_int, default=DEFAULT_DETAIL_CHARS
    )
    context_focus.set_defaults(func=cmd_context_focus)

    context_history = context_commands.add_parser(
        "history", help="explicitly load prior conclusions and journal matches"
    )
    context_history.add_argument("--topic", required=True)
    context_history.add_argument("--segment")
    context_history.add_argument("--limit", type=positive_int, default=12)
    context_history.add_argument(
        "--max-chars", type=positive_int, default=DEFAULT_DETAIL_CHARS
    )
    context_history.set_defaults(func=cmd_context_history)

    context_resume = context_commands.add_parser(
        "resume", help="load the dossier for one canonical F## or O#### reference"
    )
    context_resume.add_argument("reference")
    context_resume.add_argument(
        "--max-chars", type=positive_int, default=DEFAULT_DETAIL_CHARS
    )
    context_resume.set_defaults(func=cmd_context_resume)

    cleanup = top.add_parser(
        "cleanup", help="register and resolve what testing left on the target"
    )
    cleanup_commands = cleanup.add_subparsers(dest="command", required=True)

    cleanup_add = cleanup_commands.add_parser(
        "add", help="record an obligation to undo something on the target"
    )
    cleanup_add.add_argument("--what", required=True)
    cleanup_add.add_argument("--location", help="host, URL, or free-text location")
    cleanup_add.add_argument("--asset", help="A1 — links the obligation to an asset")
    cleanup_add.add_argument("--owner", help="who created it (agent or operator)")
    cleanup_add.add_argument("--note")
    cleanup_add.set_defaults(func=cmd_cleanup_add)

    cleanup_done = cleanup_commands.add_parser(
        "done", help="mark one obligation resolved"
    )
    cleanup_done.add_argument("reference", help="C01 or numeric id")
    cleanup_done.add_argument("--note")
    cleanup_done.set_defaults(func=cmd_cleanup_done)

    cleanup_list = cleanup_commands.add_parser(
        "list", help="list open obligations (--all includes resolved ones)"
    )
    cleanup_list.add_argument("--all", action="store_true")
    cleanup_list.set_defaults(func=cmd_cleanup_list)

    coverage = top.add_parser(
        "coverage", help="log what was actually tried, tries that found nothing included"
    )
    coverage_commands = coverage.add_subparsers(dest="command", required=True)

    coverage_add = coverage_commands.add_parser(
        "add", help="log one attempt against a target: what you tried, in words"
    )
    coverage_add.add_argument("--asset", help="A1")
    coverage_add.add_argument("--segment")
    coverage_add.add_argument(
        "--class",
        dest="test_class",
        required=True,
        help="test class; same vocabulary as observation --family (bola, xss, …)",
    )
    coverage_add.add_argument(
        "--note", help="what was actually tried, in words (required)"
    )
    coverage_add.add_argument("--owner")
    coverage_add.set_defaults(func=cmd_coverage_add)

    coverage_list = coverage_commands.add_parser(
        "list", help="every recorded attempt per target and test class"
    )
    coverage_list.add_argument("--segment")
    coverage_list.add_argument(
        "--limit", type=positive_int, default=5, help="attempts shown per pair"
    )
    coverage_list.set_defaults(func=cmd_coverage_list)

    coverage_gaps = coverage_commands.add_parser(
        "gaps", help="assets nobody has recorded any work against"
    )
    coverage_gaps.add_argument("--segment")
    coverage_gaps.add_argument("--limit", type=positive_int, default=20)
    coverage_gaps.set_defaults(func=cmd_coverage_gaps)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
    except PTError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except sqlite3.IntegrityError as exc:
        print(f"ERROR: database invariant failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
