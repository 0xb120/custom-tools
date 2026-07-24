#!/usr/bin/env python3
"""Transactional finding/observation registry for a PT engagement workspace."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
DB_PATH = SCRIPT_DIR / "engagement.db"
SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL")
STATUSES = ("open", "fixed", "non-reproducible")
OBSERVATION_STATES = (
    "new",
    "validating",
    "confirmed",
    "linked",
    "rejected",
    "inconclusive",
    "duplicate",
)
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
        lines.append(
            f"- `{row['path']}` ({row['kind']}, "
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


def cmd_observation_add(args: argparse.Namespace) -> None:
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        seg_id = segment_id(con, args.segment)
        args.asset_id = asset_id(con, args.asset) if args.asset else None
        family = normalize_family(args.family)
        args.family = family
        fingerprint = args.fingerprint or observation_fingerprint(args, seg_id)
        existing = con.execute(
            "SELECT id, state FROM observation WHERE fingerprint=?", (fingerprint,)
        ).fetchone()
        if existing:
            obs_id = int(existing["id"])
            added = register_evidence(
                con, obs_id, args.evidence, args.kind, args.description
            )
            for row in con.execute(
                "SELECT finding_id FROM finding_observation WHERE observation_id=?",
                (obs_id,),
            ):
                sync_finding_markdown(con, int(row["finding_id"]))
            con.commit()
            print(
                f"{display_observation(obs_id)} already exists "
                f"(state={existing['state']}, evidence_added={added})"
            )
            return

        title = clean_single_line(args.title, "title")
        if not title:
            raise PTError("--title is required")
        cursor = con.execute(
            """
            INSERT INTO observation
              (fingerprint, state, family, title, segment_id, asset_id,
               component, boundary, method, route, selector, attacker_role,
               target_role, source, notes)
            VALUES (?, 'new', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                fingerprint,
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
        added = register_evidence(
            con, obs_id, args.evidence, args.kind, args.description
        )
        con.commit()
        print(
            f"created {display_observation(obs_id)} "
            f"(fingerprint={fingerprint[:12]}, evidence={added})"
        )


def cmd_observation_state(args: argparse.Namespace) -> None:
    with connect() as con:
        con.execute("BEGIN IMMEDIATE")
        obs_id = observation_id(con, args.observation)
        link = con.execute(
            "SELECT finding_id FROM finding_observation WHERE observation_id=?",
            (obs_id,),
        ).fetchone()
        if link and args.state != "linked":
            raise PTError(
                f"{display_observation(obs_id)} is linked to "
                f"{display_finding(int(link['finding_id']))}; "
                "its state is managed by that canonical link"
            )
        if not link and args.state == "linked":
            raise PTError(
                "state=linked can only be set by 'finding create' or 'finding attach'"
            )
        disposition = clean_single_line(args.reason, "reason")
        if args.state in {"rejected", "inconclusive", "duplicate"} and not disposition:
            raise PTError(f"--reason is required when state={args.state}")
        con.execute(
            "UPDATE observation SET state=?, disposition=? WHERE id=?",
            (args.state, disposition, obs_id),
        )
        con.commit()
        print(f"{display_observation(obs_id)} state={args.state}")


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
        if observation["state"] in {"rejected", "inconclusive", "duplicate"}:
            raise PTError(
                f"{display_observation(obs_id)} cannot be promoted from "
                f"state={observation['state']}"
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
                "UPDATE observation SET state='linked' WHERE id=?", (obs_id,)
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
                "UPDATE observation SET state='linked' WHERE id=?", (obs_id,)
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


def doctor(con: sqlite3.Connection) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
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
        if row["lifecycle"] in ACTIVE_LIFECYCLES and not row["group_key"]:
            errors.append(f"{label} active finding has no group_key (legacy/untriaged)")
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
        SELECT o.id, o.state,
               (SELECT COUNT(*) FROM finding_observation fo
                WHERE fo.observation_id=o.id) AS links,
               (SELECT COUNT(*) FROM evidence e
                WHERE e.observation_id=o.id) AS evidence_count
        FROM observation o
        ORDER BY o.id
        """
    ):
        label = display_observation(int(row["id"]))
        if row["state"] == "confirmed" and row["links"] == 0:
            errors.append(f"{label} is confirmed but not linked to a finding")
        if row["state"] == "linked" and row["links"] != 1:
            errors.append(f"{label} state=linked but canonical finding link is missing")
        if row["links"] == 1 and row["state"] != "linked":
            errors.append(
                f"{label} has a canonical finding link but state={row['state']}"
            )
        if row["state"] in {"new", "validating", "inconclusive"}:
            warnings.append(f"{label} remains untriaged (state={row['state']})")
        if row["state"] in {"confirmed", "linked"} and row["evidence_count"] == 0:
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

    return errors, warnings


def cmd_doctor(args: argparse.Namespace) -> None:
    with connect() as con:
        errors, warnings = doctor(con)
    hook_blocked = args.hook and any(
        "remains untriaged (state=new)" in message
        or (
            message.startswith("journal has ")
            and "#observation entries without O/F reference" in message
        )
        for message in warnings
    )
    if not args.quiet or errors or warnings:
        print(f"ptctl doctor: {len(errors)} error(s), {len(warnings)} warning(s)")
        for message in errors:
            print(f"ERROR: {message}")
        for message in warnings:
            print(f"WARN: {message}")
    if errors or (args.strict and warnings) or hook_blocked:
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

        observations = con.execute(
            """
            SELECT o.id, o.state, o.family, o.title, s.name AS segment
            FROM observation o
            JOIN segment s ON s.id=o.segment_id
            WHERE o.state IN ('new','validating','confirmed','inconclusive')
            ORDER BY o.id
            LIMIT ?
            """,
            (args.limit,),
        ).fetchall()
        if observations:
            print("Untriaged observations:")
            for row in observations:
                print(
                    f"  {display_observation(int(row['id']))} "
                    f"{row['state']:<12} {row['family']} [{row['segment']}] — "
                    f"{row['title']}"
                )
        else:
            print("Untriaged observations: none")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ptctl.py",
        description="Idempotent observation/finding registry for this engagement",
    )
    top = parser.add_subparsers(dest="entity", required=True)

    observation = top.add_parser("observation")
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
    add.add_argument("--fingerprint")
    add.add_argument("--evidence", action="append", default=[])
    add.add_argument("--kind")
    add.add_argument("--description")
    add.set_defaults(func=cmd_observation_add)

    state = observation_commands.add_parser("state")
    state.add_argument("observation")
    state.add_argument("state", choices=OBSERVATION_STATES)
    state.add_argument("--reason")
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
    create.set_defaults(func=cmd_finding_create)

    attach = finding_commands.add_parser("attach")
    attach.add_argument("finding")
    attach.add_argument("--observation", action="append", required=True)
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

    doctor_parser = top.add_parser("doctor")
    doctor_parser.add_argument("--strict", action="store_true")
    doctor_parser.add_argument("--quiet", action="store_true")
    doctor_parser.add_argument("--hook", action="store_true", help=argparse.SUPPRESS)
    doctor_parser.set_defaults(func=cmd_doctor)

    board = top.add_parser("board")
    board.add_argument("--limit", type=int, default=30)
    board.set_defaults(func=cmd_board)
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
