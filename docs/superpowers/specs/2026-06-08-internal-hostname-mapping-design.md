# Internal hostname↔IP mapping (DHCP-stable host identity)

**Date:** 2026-06-08
**Scope:** `org/templates/db/` + `org/templates/AGENT.md` (engagement scaffolding only — the recon pipeline under `recon/` does not touch `engagement.db` and is unaffected).
**Applies to:** new engagements only (DBs created by `org/newPT.sh`). In-flight engagement DBs are intentionally left on the old schema — no migration script.

## Problem

During internal NPTs hosts are identified by IP, but `db/engagement.db` keys everything on a single
`asset.host` column with `UNIQUE(host, port)`. When DHCP reassigns an IP, the "identity" of every port
row silently changes, and all the host-centric retrieval paths break:

- `host-dossier.sql` filters `WHERE a.host = :host`.
- The journal host index is the inline tag `@<host>`.
- `whatweknow.sh` greps `journal.md` and `scans/` for the single host token.
- Raw `scans/` output is labelled by **IP** (nmap/naabu scan addresses), so output captured under an old
  IP becomes unreachable once the IP changes.

The operator wants a stable, human-readable ("parlante") name per machine that does not change under DHCP,
and the ability to map that name to the IP(s) it has held over time.

## Decisions (locked during brainstorming)

1. **Stable anchor = hostname/DNS/NetBIOS name.** The name is the identity; the IP is a mutable attribute.
2. **Full machine entity.** Separate the logical machine from the per-port service rather than bolting
   columns onto `asset` or adding a side lookup table.
3. **Full IP history.** A lease ledger records every IP a machine has held — this is what lets a named
   host's dossier fold in scan artifacts captured under previous IPs.
4. **Provisional name = IP.** `host.name` is always set; at IP-first discovery it is the IP, renamed in
   place once DNS resolves. The original IP is preserved in the ledger, so nothing is lost.
5. **Manual population**, consistent with the existing `asset`/`credential`/`finding` workflow. An
   auto-ingest helper (reverse DNS / nbtscan / `nmap -sn` / ARP) is explicitly **phase 2**, not built here.

## Data model

### New table `host` — the logical machine (stable identity)

```sql
CREATE TABLE IF NOT EXISTS host (
  id          INTEGER PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,   -- stable speaking name; = IP at first discovery, renamed on DNS resolution
  dns         TEXT,                   -- FQDN if richer than name (e.g. dc01.corp.local) — optional
  mac         TEXT,                   -- layer-2 anchor, DHCP-immune — optional (unknown off-segment)
  notes       TEXT,
  first_seen  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

`last_seen` is bumped by an `AFTER UPDATE` trigger that mirrors the existing `asset_touch_last_seen` trigger.

### New table `host_ip` — the IP lease ledger (defeats DHCP)

```sql
CREATE TABLE IF NOT EXISTS host_ip (
  id          INTEGER PRIMARY KEY,
  host_id     INTEGER NOT NULL REFERENCES host(id) ON DELETE CASCADE,
  ip          TEXT NOT NULL,
  current     INTEGER NOT NULL DEFAULT 1 CHECK (current IN (0, 1)),
  first_seen  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (host_id, ip)                 -- a recurring IP just flips current back on
);
CREATE INDEX IF NOT EXISTS idx_host_ip_ip ON host_ip(ip);
-- at most one current IP per machine, and at most one machine currently owning a given IP:
CREATE UNIQUE INDEX IF NOT EXISTS idx_host_ip_one_current ON host_ip(host_id) WHERE current = 1;
CREATE UNIQUE INDEX IF NOT EXISTS idx_host_ip_one_owner   ON host_ip(ip)      WHERE current = 1;
```

Rationale for not making `ip` globally unique: under DHCP the same IP is reused by different machines over
time, so uniqueness is per `(host_id, ip)`; the two partial indexes enforce that only one *current* owner of
an IP exists at any moment and that a machine has only one current IP — these catch operator mistakes.

### `asset` — now a pure per-port service

- Drop the `host` column.
- Add `host_id INTEGER NOT NULL REFERENCES host(id) ON DELETE CASCADE`.
- `UNIQUE(host, port)` → `UNIQUE(host_id, port)`.
- `idx_asset_host` (on `host`) → `idx_asset_host_id` (on `host_id`). Keep `idx_asset_access`.
- Keep `asset_touch_last_seen` unchanged.

### Segment membership moves to the machine

- `asset_segment(asset_id, segment_id)` → `host_segment(host_id, segment_id)`.
- A segment is a network location — a property of the machine, not of each port. This also removes the
  per-port duplication of segment links.

### Unchanged

- `credential_asset` and `finding_asset` still reference `asset.id`. A credential authenticates against a
  specific *service* (SMB/RDP/HTTP) and a finding touches a specific *service* — port-level granularity is
  correct. `finding.segment_id` still references `segment(id)` directly.
- `finding_default_paths` trigger unchanged.

### Generality

The model is uniform across engagement types. For web/external (no DHCP) the operator creates a `host` with
`name` = domain or IP and hangs assets off it; `host_ip` optionally records resolved IPs. The old
"`host` = IP for external/internal, hostname for web" rule is replaced by "`host.name` = the canonical name
(hostname when known, else IP); IPs live in `host_ip`."

## Operator workflow (documented in AGENT.md)

```bash
# 1. IP-first discovery — machine named provisionally after its IP.
sqlite3 db/engagement.db "INSERT INTO host (name) VALUES ('10.0.0.5');"
sqlite3 db/engagement.db "INSERT INTO host_ip (host_id, ip) VALUES (last_insert_rowid(), '10.0.0.5');"

# 2. DNS resolves later — rename in place; identity (host_id) is preserved.
sqlite3 db/engagement.db "UPDATE host SET name='DC01', dns='dc01.corp.local', mac='00:11:22:33:44:55'
  WHERE name='10.0.0.5';"

# 3. DHCP moves the machine — retire the old lease, record the new one.
sqlite3 db/engagement.db "UPDATE host_ip SET current=0 WHERE ip='10.0.0.5' AND current=1;"
sqlite3 db/engagement.db "INSERT INTO host_ip (host_id, ip)
  VALUES ((SELECT id FROM host WHERE name='DC01'), '10.0.0.9')
  ON CONFLICT(host_id, ip) DO UPDATE SET current=1, last_seen=CURRENT_TIMESTAMP;"

# 4. Services hang off the machine.
sqlite3 db/engagement.db "INSERT INTO asset (host_id, port, protocol, tls, version, technologies)
  VALUES ((SELECT id FROM host WHERE name='DC01'), 445, 'smb', 0, 'Windows Server 2019', 'smb');"
sqlite3 db/engagement.db "INSERT INTO host_segment (host_id, segment_id)
  VALUES ((SELECT id FROM host WHERE name='DC01'), (SELECT id FROM segment WHERE name='server'));"

# 5. Credentials / findings still link to the service (asset).
#    (unchanged from current AGENT.md snippets, except the asset is selected by host name + port:)
#      ... WHERE a.host_id = (SELECT id FROM host WHERE name='DC01') AND a.port=445
```

## `whatweknow.sh` — the payoff

`bash db/whatweknow.sh <name-or-ip>`:

1. Resolve the argument to a `host_id` by matching `host.name`, `host.dns`, or any `host_ip.ip`.
2. Build the **token set** = `{ host.name, host.dns, every host_ip.ip (current + historical) }`.
3. Print the DB dossier via the rewritten `host-dossier.sql` (identity + full IP history + per-port assets +
   segments + creds + findings).
4. Journal: grep `@<token>` for **every** token in the set.
5. `scans/`: grep **every** token — so an nmap run captured under `10.0.0.5` yesterday surfaces under `DC01`
   today.

**Security:** the existing single-host charset guard (`*[!A-Za-z0-9.:_-]*` reject) is preserved and applied
to **every** token pulled from the DB before it reaches `grep`/SQLite `.param`. Tokens are operator-entered
but still validated — closes the quote-injection hole exactly as today. A token failing the guard is skipped
with a warning rather than aborting the whole dossier.

## Rendering & queries

### `render.sh`

- **New `<!-- db:render hosts -->` block** in `<activity>.md` — the name↔IP map itself:
  `name | dns | mac | current IP | past IPs | segment`. The "speaking-name table" the operator wanted,
  visible at a glance. (Requires adding the matching marker pair to `templates/activity.md`.)
- **`assets` block** rewritten: join `asset → host → host_segment → segment`; columns
  `name | current IP | port | protocol | tls | version | technologies | access`. "current IP" comes from
  `host_ip WHERE current=1`. Still one sub-table per segment.
- **`credentials` block** rewritten: join `credential_asset → asset → host`; show machine `name` and current
  IP instead of the old `a.host`.

### `db/queries/`

- `host-dossier.sql` — rewritten (accepts name or any IP; resolves `host_id`; sections: identity, IP history,
  assets, segments, credentials, findings).
- `assets-by-segment.sql` — join via `host_segment` (`asset → host → host_segment → segment`).
- `assets-no-access.sql` — join via `host`/`host_segment`; display `host.name` + current IP instead of
  `a.host`.
- `creds-multi-host.sql` — `GROUP_CONCAT` over `host.name || ':' || a.port` instead of `a.host || ':' ...`.
- `findings-open.sql` — **unchanged** (joins `finding.segment_id` directly, no `asset.host`).
- Optional new `hosts.sql` — the name↔IP map as a standalone query (mirrors the new render block).

## Docs & scaffolding

### `AGENT.md`

- Rewrite § Asset tracking: host-first INSERT flow (snippets above); replace the `host` column-semantics
  bullet with `host.name` / `host_ip` semantics; document the DHCP IP-change flow.
- § Engagement database: update the "Common writes" snippets and the "What lives where" table (asset
  inventory now `host` + `asset` + `host_segment`; add the host/name↔IP map row).
- § Working journal: tag entries with `@<stable-name>` (fall back to `@<ip>` when the name is unknown — still
  discoverable because `whatweknow.sh` expands the token set).
- Update the queries table and the `whatweknow.sh` description.

### `newPT.sh`

- **No logic change.** It already copies `schema.sql`, `render.sh`, `whatweknow.sh`, and `queries/*.sql`, then
  runs the schema on a fresh DB. New query files ride the existing `queries/*.sql` glob.

### `templates/activity.md`

- Add the `<!-- db:render hosts -->` / `<!-- /db:render hosts -->` marker pair where the host map should
  render (above or alongside the asset inventory).

## Out of scope (phase 2)

- Auto-ingest helper that populates `host` / `host_ip` from recon output (reverse DNS, nbtscan, `nmap -sn`,
  ARP tables). Formats vary per tool and per environment; deferred deliberately.
- Migration of in-flight engagement DBs to the new schema.

## Affected files (summary)

| File | Change |
|------|--------|
| `org/templates/db/schema.sql` | add `host`, `host_ip` (+ indexes, trigger); rework `asset` (`host_id`); `asset_segment` → `host_segment` |
| `org/templates/db/render.sh` | new `hosts` block; rewrite `assets` + `credentials` joins |
| `org/templates/db/whatweknow.sh` | resolve name/IP → token set; grep all tokens; per-token charset guard |
| `org/templates/db/queries/host-dossier.sql` | rewrite for the new schema |
| `org/templates/db/queries/assets-by-segment.sql` | join via `host_segment` |
| `org/templates/db/queries/assets-no-access.sql` | join via `host`/`host_segment`; show name + IP |
| `org/templates/db/queries/creds-multi-host.sql` | `GROUP_CONCAT` over `host.name` |
| `org/templates/db/queries/hosts.sql` | **new** (optional) — name↔IP map query |
| `org/templates/AGENT.md` | rewrite asset-tracking / DB / journal sections + queries table |
| `org/templates/activity.md` | add `db:render hosts` marker pair |
| `org/templates/db/queries/findings-open.sql` | unchanged |
| `org/newPT.sh` | unchanged (existing globs cover new files) |
