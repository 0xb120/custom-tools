#!/usr/bin/env python3
"""Transactional finding/observation registry for a PT engagement workspace."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parent
DB_PATH = SCRIPT_DIR / "engagement.db"
CONTEXT_DIR = ROOT / ".context"
HANDOFF_PATH = CONTEXT_DIR / "handoff.md"
SESSION_STATE_PATH = CONTEXT_DIR / "state.json"
ACTIVE_SESSION_PATH = CONTEXT_DIR / "active.json"
SESSION_STATE_VERSION = 1
DEFAULT_BOOT_CHARS = 16000
DEFAULT_DETAIL_CHARS = 24000
SESSION_OUTCOMES = ("captured", "no-finding", "mixed", "administrative")
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
    untriaged = sum(
        observation_counts.get(state, 0)
        for state in ("new", "validating", "confirmed", "inconclusive")
    )
    lines = [
        f"- Active findings: {active_findings}",
        f"- Merged/rejected findings: "
        f"{finding_counts.get('merged', 0) + finding_counts.get('rejected', 0)}",
        f"- Untriaged observations: {untriaged}",
        f"- Linked observations: {observation_counts.get('linked', 0)}",
        f"- Inventory: {hosts} host(s), {assets} asset(s)",
    ]
    if observation_counts.get("new", 0):
        lines.append(
            f"- ACTION REQUIRED: {observation_counts['new']} observation(s) "
            "still in transient state=new"
        )
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


def build_bounded_context(
    sections: list[tuple[str, str, int]], max_chars: int
) -> str:
    if max_chars < 4000:
        raise PTError("--max-chars must be at least 4000")
    output = ["PT CONTEXT BOOT — progressive disclosure"]
    reserve = 700
    for title, body, section_cap in sections:
        if not body.strip():
            continue
        prefix = f"\n\n--- {title} ---\n"
        available = max_chars - len("".join(output)) - len(prefix) - reserve
        if available <= 100:
            break
        output.extend((prefix, clip_text(body, min(section_cap, available))))
    manifest = (
        "\n\n--- Context policy ---\n"
        "Loaded now: hard rules, scope, handoff, registry counts, compact open tasks.\n"
        "Not loaded: journal prose, finding write-ups, evidence bodies, scans, "
        "completed TODO history.\n"
        "After the human chooses a target, form an independent test plan first; "
        "then use `context focus`, `context history`, or `context resume`."
    )
    result = "".join(output)
    if len(result) + len(manifest) <= max_chars:
        result += manifest
    else:
        result = clip_text(result, max_chars - len(manifest)) + manifest
    return clip_text(result, max_chars)


def boot_context(
    con: sqlite3.Connection, max_chars: int, include_rules: bool, task_limit: int
) -> str:
    sections: list[tuple[str, str, int]] = []
    if include_rules:
        sections.append(
            (
                "Hard engagement rules (Claude native bridge)",
                read_text(ROOT / "AGENTS.md"),
                9400,
            )
        )
    else:
        sections.append(("Engagement", engagement_identity(), 1000))
    sections.extend(
        (
            ("Scope boundaries", scope_summary(), 1600),
            (
                "Current handoff",
                handoff_boot_context(con),
                1800,
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
                include_rules=args.include_rules,
                task_limit=args.task_limit,
            )
        )


def cmd_context_explain(args: argparse.Namespace) -> None:
    with connect() as con:
        rendered = boot_context(
            con,
            max_chars=args.max_chars,
            include_rules=args.include_rules,
            task_limit=args.task_limit,
        )
        counts = con.execute(
            """
            SELECT
              (SELECT COUNT(*) FROM finding) AS findings,
              (SELECT COUNT(*) FROM observation) AS observations,
              (SELECT COUNT(*) FROM evidence) AS evidence
            """
        ).fetchone()
    print(f"Direct boot context: {len(rendered)} chars (budget={args.max_chars})")
    print("Sources:")
    print(
        f"- AGENTS.md: "
        f"{'included for Claude' if args.include_rules else 'excluded here (native in Codex)'} "
        f"({file_size(ROOT / 'AGENTS.md')} bytes)"
    )
    print(f"- scope.txt: summarized ({file_size(ROOT / 'scope.txt')} bytes)")
    print(
        f"- out-of-scope.txt: summarized "
        f"({file_size(ROOT / 'out-of-scope.txt')} bytes)"
    )
    print(f"- .context/handoff.md: included ({file_size(HANDOFF_PATH)} bytes)")
    print(
        f"- .context/state.json: delta metadata only "
        f"({file_size(SESSION_STATE_PATH)} bytes)"
    )
    print(
        f"- .context/active.json: "
        f"{'active marker only' if ACTIVE_SESSION_PATH.is_file() else 'no active session'}"
    )
    print(f"- TODO.md: open titles only ({len(open_tasks())} open)")
    print(
        f"- registry: counts only ({counts['findings']} findings, "
        f"{counts['observations']} observations, {counts['evidence']} evidence)"
    )
    print("Excluded:")
    print("- journal.md prose")
    print("- finding write-ups and report prose")
    print("- evidence contents, scans, and Burp history")
    print("- completed TODO history")


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
        SELECT o.id, o.state, o.family, o.title, COALESCE(o.component, '') AS component,
               COALESCE(o.boundary, '') AS boundary, COALESCE(o.method, '') AS method,
               COALESCE(o.route, '') AS route, s.name AS segment
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
        f"- {display_observation(int(row['id']))} {row['state']} "
        f"{row['family']} [{row['segment']}] — {row['title']}"
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
        f"- state: {row['state']}",
        f"- family/segment: {row['family']} / {row['segment']}",
        f"- component/boundary: {row['component'] or '-'} / {row['boundary'] or '-'}",
        f"- request identity: {row['method'] or '-'} {row['route'] or '-'} "
        f"selector={row['selector'] or '-'}",
        f"- roles: {row['attacker_role'] or '-'} -> {row['target_role'] or '-'}",
        f"- source: {row['source'] or '-'}",
        f"- notes/disposition: {row['notes'] or '-'} / {row['disposition'] or '-'}",
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


def bullet_section(title: str, values: list[str]) -> str:
    lines = [f"## {title}"]
    lines.extend(f"- {clean_single_line(value, title) or '<empty>'}" for value in values)
    if not values:
        lines.append("- None")
    return "\n".join(lines)


def artifact_manifest(
    baseline: dict[str, object] | None = None,
) -> dict[str, dict[str, int | str]]:
    manifest: dict[str, dict[str, int | str]] = {}
    errors: list[str] = []
    previous = baseline or {}

    def record(path: Path) -> None:
        try:
            metadata = path.lstat()
        except OSError as exc:
            errors.append(f"{path.relative_to(ROOT)}: {exc}")
            return
        relative = path.relative_to(ROOT).as_posix()
        kind = "symlink" if path.is_symlink() else "file"
        old = previous.get(relative)
        reusable = (
            isinstance(old, dict)
            and old.get("kind") == kind
            and old.get("size") == int(metadata.st_size)
            and old.get("mtime_ns") == int(metadata.st_mtime_ns)
            and old.get("ctime_ns") == int(metadata.st_ctime_ns)
            and isinstance(old.get("sha256"), str)
        )
        try:
            if reusable:
                digest = str(old["sha256"])
            elif kind == "symlink":
                digest = hashlib.sha256(os.readlink(path).encode()).hexdigest()
            else:
                digest = sha256_file(path)
        except OSError as exc:
            errors.append(f"{relative}: {exc}")
            return
        manifest[relative] = {
            "kind": kind,
            "size": int(metadata.st_size),
            "mtime_ns": int(metadata.st_mtime_ns),
            "ctime_ns": int(metadata.st_ctime_ns),
            "sha256": digest,
        }

    def walk_error(exc: OSError) -> None:
        errors.append(str(exc))

    for root_name in ("scans", "poc"):
        artifact_root = ROOT / root_name
        if not artifact_root.is_dir():
            continue
        for directory, dirnames, filenames in os.walk(
            artifact_root, followlinks=False, onerror=walk_error
        ):
            directory_path = Path(directory)
            kept_dirs = []
            for dirname in sorted(dirnames):
                path = directory_path / dirname
                if path.is_symlink():
                    record(path)
                else:
                    kept_dirs.append(dirname)
            dirnames[:] = kept_dirs
            for filename in sorted(filenames):
                record(directory_path / filename)
    if errors:
        raise PTError(
            "cannot inspect the session artifact tree:\n- " + "\n- ".join(errors[:10])
        )
    return dict(sorted(manifest.items()))


def database_digest(con: sqlite3.Connection) -> str:
    digest = hashlib.sha256()
    for statement in con.iterdump():
        digest.update(statement.encode("utf-8", errors="replace"))
        digest.update(b"\n")
    return digest.hexdigest()


def row_digest(row: sqlite3.Row) -> str:
    payload = json.dumps(
        {key: row[key] for key in row.keys()},
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    )
    return hashlib.sha256(payload.encode()).hexdigest()


def registry_snapshot(con: sqlite3.Connection) -> dict[str, object]:
    observations = {
        str(row["id"]): row_digest(row)
        for row in con.execute("SELECT * FROM observation ORDER BY id")
    }
    findings = {
        str(row["id"]): row_digest(row)
        for row in con.execute("SELECT * FROM finding ORDER BY id")
    }
    evidence = {
        str(row["id"]): {
            "observation_id": int(row["observation_id"]),
            "finding_id": (
                int(row["finding_id"]) if row["finding_id"] is not None else None
            ),
            "path": str(row["path"]),
            "sha256": str(row["sha256"]),
        }
        for row in con.execute(
            """
            SELECT e.id, e.observation_id, e.path, e.sha256, fo.finding_id
            FROM evidence e
            LEFT JOIN finding_observation fo
              ON fo.observation_id=e.observation_id
            ORDER BY e.id
            """
        )
    }
    return {
        "database_sha256": database_digest(con),
        "observations": observations,
        "findings": findings,
        "evidence": evidence,
    }


def build_session_state(
    con: sqlite3.Connection,
    recorded_at: str | None = None,
    baseline: dict[str, object] | None = None,
) -> dict[str, object]:
    previous_artifacts: dict[str, object] | None = None
    if baseline is not None:
        artifacts = baseline.get("artifacts")
        if isinstance(artifacts, dict):
            previous_artifacts = artifacts
    return {
        "version": SESSION_STATE_VERSION,
        "recorded_at": recorded_at
        or datetime.now().astimezone().isoformat(timespec="seconds"),
        "artifacts": artifact_manifest(previous_artifacts),
        "registry": registry_snapshot(con),
    }


def load_session_state() -> dict[str, object] | None:
    if not SESSION_STATE_PATH.is_file():
        return None
    try:
        state = json.loads(read_text(SESSION_STATE_PATH))
    except json.JSONDecodeError as exc:
        raise PTError(f"{SESSION_STATE_PATH.relative_to(ROOT)} is invalid JSON: {exc}")
    if not isinstance(state, dict) or state.get("version") != SESSION_STATE_VERSION:
        raise PTError(
            f"{SESSION_STATE_PATH.relative_to(ROOT)} has an unsupported state version"
        )
    if not isinstance(state.get("artifacts"), dict) or not isinstance(
        state.get("registry"), dict
    ):
        raise PTError(
            f"{SESSION_STATE_PATH.relative_to(ROOT)} is missing artifacts/registry"
        )
    return state


def load_active_session() -> dict[str, object] | None:
    if not ACTIVE_SESSION_PATH.is_file():
        return None
    try:
        active = json.loads(read_text(ACTIVE_SESSION_PATH))
    except json.JSONDecodeError as exc:
        raise PTError(f"{ACTIVE_SESSION_PATH.relative_to(ROOT)} is invalid JSON: {exc}")
    if not isinstance(active, dict) or not active.get("started_at"):
        raise PTError(f"{ACTIVE_SESSION_PATH.relative_to(ROOT)} is invalid")
    return active


def cmd_session_start(args: argparse.Namespace) -> None:
    existing = load_active_session()
    if existing:
        if not args.quiet:
            print(
                "session already active since "
                f"{existing['started_at']} "
                f"(client={existing.get('client', 'unknown')})"
            )
        return
    client = clean_single_line(args.client, "client") or "manual"
    active = {
        "version": 1,
        "started_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "client": client,
    }
    write_atomic(
        ACTIVE_SESSION_PATH,
        json.dumps(active, indent=2, sort_keys=True) + "\n",
    )
    if not args.quiet:
        print(f"session started ({client})")


def artifact_delta(
    baseline: dict[str, object] | None,
    current: dict[str, dict[str, int | str]],
) -> dict[str, list[str]]:
    if baseline is None:
        handoff_mtime = (
            HANDOFF_PATH.stat().st_mtime_ns if HANDOFF_PATH.is_file() else -1
        )
        return {
            "added": sorted(
                path
                for path, metadata in current.items()
                if int(metadata["mtime_ns"]) > handoff_mtime
            ),
            "modified": [],
            "deleted": [],
        }
    previous = baseline["artifacts"]
    assert isinstance(previous, dict)

    def identity(metadata: object) -> tuple[object, object, object]:
        if not isinstance(metadata, dict):
            return (None, None, None)
        return (
            metadata.get("kind"),
            metadata.get("size"),
            metadata.get("sha256"),
        )

    return {
        "added": sorted(set(current) - set(previous)),
        "modified": sorted(
            path
            for path in set(current) & set(previous)
            if identity(current[path]) != identity(previous[path])
        ),
        "deleted": sorted(set(previous) - set(current)),
    }


def registry_delta_refs(
    baseline: dict[str, object] | None, current: dict[str, object]
) -> list[str]:
    if baseline is None:
        previous: dict[str, object] = {
            "observations": {},
            "findings": {},
            "evidence": {},
        }
    else:
        registry = baseline["registry"]
        assert isinstance(registry, dict)
        previous = registry
    refs: set[str] = set()

    for entity, formatter in (
        ("observations", display_observation),
        ("findings", display_finding),
    ):
        old_rows = previous.get(entity, {})
        new_rows = current.get(entity, {})
        if not isinstance(old_rows, dict) or not isinstance(new_rows, dict):
            raise PTError(
                f"{SESSION_STATE_PATH.relative_to(ROOT)} has invalid registry.{entity}"
            )
        for row_id in set(old_rows) | set(new_rows):
            if old_rows.get(row_id) != new_rows.get(row_id):
                refs.add(formatter(int(row_id)))

    old_evidence = previous.get("evidence", {})
    new_evidence = current.get("evidence", {})
    if not isinstance(old_evidence, dict) or not isinstance(new_evidence, dict):
        raise PTError(
            f"{SESSION_STATE_PATH.relative_to(ROOT)} has invalid registry.evidence"
        )
    for evidence_id in set(old_evidence) | set(new_evidence):
        if old_evidence.get(evidence_id) == new_evidence.get(evidence_id):
            continue
        row = new_evidence.get(evidence_id) or old_evidence.get(evidence_id)
        if not isinstance(row, dict):
            continue
        if row.get("observation_id") is not None:
            refs.add(display_observation(int(row["observation_id"])))
        if row.get("finding_id") is not None:
            refs.add(display_finding(int(row["finding_id"])))
    return sorted(
        refs,
        key=lambda ref: (ref[0], int(ref[1:])),
    )


def database_changed(
    baseline: dict[str, object] | None, current: dict[str, object]
) -> bool:
    if baseline is None:
        return False
    previous = baseline["registry"]
    assert isinstance(previous, dict)
    old_digest = previous.get("database_sha256")
    new_digest = current.get("database_sha256")
    return bool(old_digest and new_digest and old_digest != new_digest)


def collect_session_delta(
    con: sqlite3.Connection,
) -> tuple[dict[str, object] | None, dict[str, object], dict[str, object]]:
    baseline = load_session_state()
    current = build_session_state(con, baseline=baseline)
    artifacts = current["artifacts"]
    registry = current["registry"]
    assert isinstance(artifacts, dict)
    assert isinstance(registry, dict)
    delta: dict[str, object] = {
        "artifacts": artifact_delta(baseline, artifacts),
        "registry_refs": registry_delta_refs(baseline, registry),
        "database_changed": database_changed(baseline, registry),
        "active_session": load_active_session(),
        "baseline": (
            baseline.get("recorded_at") if baseline else "legacy handoff mtime"
        ),
    }
    return baseline, current, delta


def has_artifact_delta(delta: dict[str, object]) -> bool:
    artifacts = delta["artifacts"]
    assert isinstance(artifacts, dict)
    return any(bool(artifacts[name]) for name in ("added", "modified", "deleted"))


def delta_count_summary(delta: dict[str, object]) -> str:
    artifacts = delta["artifacts"]
    assert isinstance(artifacts, dict)
    return (
        f"+{len(artifacts['added'])} added, "
        f"~{len(artifacts['modified'])} modified, "
        f"-{len(artifacts['deleted'])} deleted"
    )


def canonical_references(values: Iterable[str]) -> list[str]:
    refs: set[str] = set()
    for value in values:
        for prefix, number in re.findall(r"\b([FfOo])(\d+)\b", value):
            item_id = int(number)
            refs.add(
                display_finding(item_id)
                if prefix.lower() == "f"
                else display_observation(item_id)
            )
    return sorted(refs, key=lambda ref: (ref[0], int(ref[1:])))


def validate_canonical_references(
    con: sqlite3.Connection, refs: Iterable[str]
) -> None:
    for ref in refs:
        if ref.startswith("F"):
            finding_row(con, ref)
        else:
            observation_id(con, ref)


def validate_capture_gate(
    con: sqlite3.Connection, args: argparse.Namespace, delta: dict[str, object]
) -> tuple[str | None, str | None, list[str]]:
    outcome = args.outcome
    assessment = clean_single_line(args.assessment, "assessment")
    refs = canonical_references(args.reference)
    validate_canonical_references(con, refs)
    gate_required = has_artifact_delta(delta)
    active_session = delta["active_session"]

    if (gate_required or active_session) and not outcome:
        trigger = (
            "scans/poc changed since the last handoff "
            f"({delta_count_summary(delta)})"
            if gate_required
            else "the active PT session requires an explicit outcome"
        )
        raise PTError(
            f"capture gate: {trigger}. Run `ptctl.py session delta`, then "
            "close with `--outcome captured --reference O####|F##`, "
            "`--outcome no-finding --assessment '…'`, `--outcome mixed ...`, "
            "or `--outcome administrative --assessment '…'`"
        )
    if assessment and not outcome:
        raise PTError("--assessment requires --outcome")
    if outcome in {"captured", "mixed"}:
        if not refs:
            raise PTError(
                f"--outcome {outcome} requires a canonical O####/F## --reference"
            )
        changed_refs = set(delta["registry_refs"])
        if not changed_refs.intersection(refs):
            changed = ", ".join(delta["registry_refs"]) or "<none>"
            raise PTError(
                "capture gate: supplied references were not created or updated "
                f"since the last handoff; session registry delta is {changed}"
            )
    if outcome in {"no-finding", "mixed", "administrative"} and not assessment:
        raise PTError(f"--outcome {outcome} requires --assessment")
    return outcome, assessment, refs


def format_artifact_delta(delta: dict[str, object], limit: int) -> str:
    artifacts = delta["artifacts"]
    assert isinstance(artifacts, dict)
    lines = [
        f"Session artifact delta since {delta['baseline']}:",
        f"- {delta_count_summary(delta)}",
    ]
    remaining = limit
    for name, marker in (("added", "+"), ("modified", "~"), ("deleted", "-")):
        for path in artifacts[name]:
            if remaining <= 0:
                break
            lines.append(f"{marker} {path}")
            remaining -= 1
    total = sum(len(artifacts[name]) for name in ("added", "modified", "deleted"))
    if total > limit:
        lines.append(f"… {total - limit} more path(s); increase --limit")
    registry_refs = delta["registry_refs"]
    lines.append(
        "- Registry delta: "
        + (", ".join(registry_refs) if registry_refs else "<none>")
    )
    lines.append(
        f"- Database state: {'changed' if delta['database_changed'] else 'unchanged'}"
    )
    lines.append(
        "- Capture gate: "
        + (
            "REQUIRED"
            if has_artifact_delta(delta)
            else (
                "SESSION OUTCOME REQUIRED"
                if delta["active_session"]
                else "not required"
            )
        )
    )
    return "\n".join(lines)


def cmd_session_delta(args: argparse.Namespace) -> None:
    with connect() as con:
        _, _, delta = collect_session_delta(con)
    if args.json:
        print(json.dumps(delta, indent=2, sort_keys=True))
    else:
        print(format_artifact_delta(delta, args.limit))


def cmd_session_close(args: argparse.Namespace) -> None:
    focus = clean_single_line(args.focus, "focus")
    if not focus:
        raise PTError("--focus is required")
    updated = datetime.now().astimezone().isoformat(timespec="seconds")
    with connect() as con:
        _, current_state, delta = collect_session_delta(con)
        outcome, assessment, refs = validate_capture_gate(con, args, delta)
    assessment_values = [
        f"Outcome: {outcome or 'not-required'}",
        f"Artifact delta: {delta_count_summary(delta)}",
    ]
    if assessment:
        assessment_values.append(f"Assessment: {assessment}")
    if refs:
        assessment_values.append(f"Validated references: {', '.join(refs)}")
    content = "\n\n".join(
        (
            "# Current handoff",
            f"- **Updated**: {updated}\n- **Last focus**: {focus}",
            bullet_section("Session assessment", assessment_values),
            bullet_section("Completed this session", args.completed),
            bullet_section("Live state / do not disturb", args.live_state),
            bullet_section("Blockers", args.blocker),
            bullet_section("Cleanup obligations", args.cleanup),
            bullet_section("Suggested next work", args.next),
            bullet_section("Canonical pointers", args.reference),
        )
    )
    if len(content) > args.max_chars:
        raise PTError(
            f"handoff is {len(content)} chars; reduce it below --max-chars={args.max_chars}"
        )
    write_atomic(HANDOFF_PATH, content + "\n")
    current_state["recorded_at"] = updated
    write_atomic(
        SESSION_STATE_PATH,
        json.dumps(current_state, indent=2, sort_keys=True) + "\n",
    )
    ACTIVE_SESSION_PATH.unlink(missing_ok=True)
    print(f"updated {HANDOFF_PATH.relative_to(ROOT)} ({len(content)} chars)")


def canonical_mutation_paths() -> list[Path]:
    paths = [
        ROOT / "TODO.md",
        ROOT / "journal.md",
    ]
    if not SESSION_STATE_PATH.is_file():
        paths.extend((DB_PATH, DB_PATH.with_name(DB_PATH.name + "-wal")))
    activity = activity_file()
    if activity:
        paths.append(activity)
    findings_dir = ROOT / "findings"
    if findings_dir.is_dir():
        paths.extend(
            path for path in findings_dir.glob("*.md") if path.name != "_template.md"
        )
    return [path for path in paths if path.exists()]


def canonical_changes_since_handoff() -> list[Path]:
    if not HANDOFF_PATH.is_file():
        return canonical_mutation_paths()
    handoff_mtime = HANDOFF_PATH.stat().st_mtime_ns
    return [
        path
        for path in canonical_mutation_paths()
        if path.stat().st_mtime_ns > handoff_mtime
    ]


def handoff_boot_context(con: sqlite3.Connection) -> str:
    handoff = read_text(HANDOFF_PATH)
    if not handoff:
        return "- No handoff exists; initialize it with `ptctl.py session close`"
    _, _, delta = collect_session_delta(con)
    canonical_changes = canonical_changes_since_handoff()
    active_session = delta["active_session"]
    active_notice = ""
    if isinstance(active_session, dict):
        active_notice = (
            f"- **Session**: active since {active_session['started_at']}; "
            "an explicit outcome is required before Stop.\n"
        )
    if (
        not canonical_changes
        and not has_artifact_delta(delta)
        and not delta["database_changed"]
    ):
        return "- **Freshness**: current\n" + active_notice + "\n" + handoff
    warnings = [
        "- **Freshness**: STALE — treat the handoff below as historical, not truth.",
    ]
    if canonical_changes:
        warnings.append(
            "- Canonical changes: "
            + ", ".join(path.relative_to(ROOT).as_posix() for path in canonical_changes)
        )
    if has_artifact_delta(delta):
        warnings.append(
            f"- Artifact delta: {delta_count_summary(delta)}; capture gate pending."
        )
    if delta["database_changed"]:
        warnings.append("- Structured database state changed after the handoff.")
    warnings.append("- Run `python3 db/ptctl.py session delta` before continuing.")
    return "\n".join(warnings) + "\n" + active_notice + "\n" + handoff


def cmd_session_check(args: argparse.Namespace) -> None:
    if not HANDOFF_PATH.is_file():
        print(
            "session handoff missing: run `python3 db/ptctl.py session close "
            "--focus '…'`"
        )
        raise SystemExit(1)
    with connect() as con:
        _, _, delta = collect_session_delta(con)
    stale = canonical_changes_since_handoff()
    active_session = delta["active_session"]
    if (
        stale
        or has_artifact_delta(delta)
        or delta["database_changed"]
        or active_session
    ):
        if not args.quiet:
            if stale or has_artifact_delta(delta) or delta["database_changed"]:
                print("session handoff is stale")
            else:
                print("session capture gate is unresolved")
            if isinstance(active_session, dict):
                print(
                    "Active session has no closing outcome "
                    f"(started {active_session['started_at']})."
                )
            if stale:
                print("Canonical sources changed after handoff:")
                for path in stale:
                    print(f"- {path.relative_to(ROOT)}")
            if has_artifact_delta(delta):
                print(format_artifact_delta(delta, 20))
            elif delta["database_changed"]:
                print("Structured database state changed after handoff.")
            print(
                "run `python3 db/ptctl.py session close --focus '…' "
                "--completed '…' --next '…'` and resolve any capture gate"
            )
        raise SystemExit(1)
    if not args.quiet:
        print("session handoff is current")


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
    problems: list[str] = []
    if len(urls) < MIN_EXTERNAL_REFERENCES:
        problems.append(
            f"{label} ## References has {len(urls)} external reference(s); "
            f"at least {MIN_EXTERNAL_REFERENCES} required"
        )
    if urls and not any(
        domain in line for line in urls for domain in PRIORITY_REFERENCE_DOMAINS
    ):
        problems.append(
            f"{label} ## References must include at least one link from "
            + " or ".join(PRIORITY_REFERENCE_DOMAINS)
        )
    return problems


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
        if row["lifecycle"] in ACTIVE_LIFECYCLES:
            warnings.extend(reference_warnings(text, label))
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

    poc = top.add_parser("poc")
    poc_commands = poc.add_subparsers(dest="command", required=True)
    poc_sync = poc_commands.add_parser("sync")
    poc_sync.add_argument(
        "finding",
        nargs="?",
        help="sync only this finding (F-id or slug); default: all findings",
    )
    poc_sync.set_defaults(func=cmd_poc_sync)

    doctor_parser = top.add_parser("doctor")
    doctor_parser.add_argument("--strict", action="store_true")
    doctor_parser.add_argument("--quiet", action="store_true")
    doctor_parser.add_argument("--hook", action="store_true", help=argparse.SUPPRESS)
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
    context_boot.add_argument(
        "--include-rules",
        action="store_true",
        help="include AGENTS.md for clients that do not load it natively",
    )
    context_boot.add_argument("--task-limit", type=positive_int, default=8)
    context_boot.set_defaults(func=cmd_context_boot)

    context_explain = context_commands.add_parser(
        "explain", help="show exactly what boot context includes and excludes"
    )
    context_explain.add_argument(
        "--max-chars", type=positive_int, default=DEFAULT_BOOT_CHARS
    )
    context_explain.add_argument("--include-rules", action="store_true")
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

    session = top.add_parser(
        "session", help="maintain the compact cross-session handoff"
    )
    session_commands = session.add_subparsers(dest="command", required=True)

    session_start = session_commands.add_parser(
        "start", help="open the PT session capture gate"
    )
    session_start.add_argument("--client", default="manual")
    session_start.add_argument("--quiet", action="store_true")
    session_start.set_defaults(func=cmd_session_start)

    session_close = session_commands.add_parser(
        "close", help="write the structured handoff after meaningful work"
    )
    session_close.add_argument("--focus", required=True)
    session_close.add_argument("--completed", action="append", default=[])
    session_close.add_argument("--live-state", action="append", default=[])
    session_close.add_argument("--blocker", action="append", default=[])
    session_close.add_argument("--cleanup", action="append", default=[])
    session_close.add_argument("--next", action="append", default=[])
    session_close.add_argument("--reference", action="append", default=[])
    session_close.add_argument("--outcome", choices=SESSION_OUTCOMES)
    session_close.add_argument(
        "--assessment",
        help="required rationale for no-finding, mixed, or administrative outcomes",
    )
    session_close.add_argument("--max-chars", type=positive_int, default=1800)
    session_close.set_defaults(func=cmd_session_close)

    session_delta = session_commands.add_parser(
        "delta", help="show scans/poc and registry changes since the last handoff"
    )
    session_delta.add_argument("--limit", type=positive_int, default=40)
    session_delta.add_argument("--json", action="store_true")
    session_delta.set_defaults(func=cmd_session_delta)

    session_check = session_commands.add_parser(
        "check",
        help="fail when canonical work or scans/poc changed after the last handoff",
    )
    session_check.add_argument("--quiet", action="store_true")
    session_check.set_defaults(func=cmd_session_check)
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
