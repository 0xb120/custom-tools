# Penetration Test Playbook

This is an on-demand reference. It is intentionally excluded from session boot context; consult only the relevant section when needed. Hard engagement rules remain in `AGENTS.md`.

## Finding write-up requirements

Each `findings/<slug>.md` must retain the template sections for Vuln_ID, group key, title, severity, status, affected assets, CWE, segment, observation IDs, impact summary, description, reproduction steps, managed evidence, remediation, and references. `ptctl.py` owns managed metadata and evidence blocks; the tester owns the narrative sections.

The `## References` section is mandatory: at least 3 external references, every one a link (URL), with at least one from `cheatsheetseries.owasp.org` or `portswigger.net/web-security` (prefer the vulnerability-class cheat sheet and the matching Web Security Academy topic, then vendor/CVE/standards/research links). `doctor` flags a shortfall as a warning; `doctor --strict` fails on it, so resolve it before packaging.

The managed evidence block renders each registered path as a navigable Markdown link relative to the write-up (`[scans/…](../scans/…)`); `ptctl.py` maintains it, so never hand-edit the paths.

The activity-level findings index is rendered from the DB. IDs are `F##`, never reused; active rows are severity-sorted and link to the write-up.

## Severity scale

- **CRITICAL** — reliable compromise of the target or broad confidentiality/integrity loss, commonly remotely exploitable with limited prerequisites. Resolution is urgent.
- **HIGH** — significant confidentiality or integrity compromise, usually with meaningful constraints such as an authenticated or privileged prerequisite.
- **MEDIUM** — limited non-critical data exposure or constrained integrity impact, with prerequisites that materially reduce likely exploitation.
- **LOW** — slight or heavily constrained security impact, or information that meaningfully assists a stronger attack.
- **INFORMATIONAL** — no direct confidentiality, integrity, or availability compromise; a hardening or security-practice issue.

Choose the level from assessed impact and exploitability in this engagement, not from CVSS alone.

## Engagement database

`db/engagement.db` is canonical for the host map, asset inventory, verified credentials, observations, evidence metadata, and finding metadata. Inventory tables may be maintained with SQLite; observations and findings must use `db/ptctl.py`.

Host identity is stable across addresses:

- `host` is the machine identity; its provisional name may initially be an IP.
- `host_ip` keeps current and historical addresses.
- `host_segment` assigns report/network segments to the machine.
- `asset` is a service on the host and is unique by host and port.
- `credential_asset` records where a credential actually authenticated.

**Common writes** (operator and agent run these as needed):

```bash
# Define segments first.
sqlite3 db/engagement.db "INSERT INTO segment (name, description) VALUES
  ('server', 'on-prem servers'),
  ('pc',     'workstations');"

# Register a machine. The IP is a provisional name until DNS/NetBIOS resolves.
sqlite3 db/engagement.db "INSERT INTO host (name) VALUES ('10.0.0.5');"
sqlite3 db/engagement.db "INSERT INTO host_ip (host_id, ip)
  VALUES ((SELECT id FROM host WHERE name='10.0.0.5'), '10.0.0.5');"
sqlite3 db/engagement.db "UPDATE host SET name='DC01', dns='dc01.corp.local', mac='00:11:22:33:44:55'
  WHERE name='10.0.0.5';"
sqlite3 db/engagement.db "INSERT INTO host_segment (host_id, segment_id)
  VALUES ((SELECT id FROM host WHERE name='DC01'), (SELECT id FROM segment WHERE name='server'));"

# DHCP moved the machine: retire the old lease and add the current address.
sqlite3 db/engagement.db "UPDATE host_ip SET current=0 WHERE ip='10.0.0.5' AND current=1;"
sqlite3 db/engagement.db "INSERT INTO host_ip (host_id, ip)
  VALUES ((SELECT id FROM host WHERE name='DC01'), '10.0.0.9')
  ON CONFLICT(host_id, ip) DO UPDATE SET current=1, last_seen=CURRENT_TIMESTAMP;"

# Add a service.
sqlite3 db/engagement.db "INSERT INTO asset
  (host_id, port, protocol, tls, version, technologies)
  VALUES ((SELECT id FROM host WHERE name='DC01'), 445, 'smb', 0, 'Windows Server 2019', 'smb');"

# Record a verified credential and its access level in one sqlite3 connection.
sqlite3 db/engagement.db "
  INSERT INTO credential (username, secret, secret_type, role, source, source_path)
    VALUES ('admin', 'P@ssw0rd', 'password', 'admin', 'sprayed', 'wl/passwords.txt');
  INSERT INTO credential_asset (credential_id, asset_id, verified_at)
    VALUES (last_insert_rowid(),
            (SELECT id FROM asset WHERE host_id=(SELECT id FROM host WHERE name='DC01') AND port=445),
            CURRENT_TIMESTAMP);"
sqlite3 db/engagement.db "UPDATE asset SET access='admin'
  WHERE host_id=(SELECT id FROM host WHERE name='DC01') AND port=445;"

# Render inventory and credential tables after raw DB writes.
bash db/render.sh
```

**Common reads** — saved snippets under `db/queries/`:

| Query | Purpose |
|---|---|
| `assets-no-access.sql` | Services with no access yet |
| `assets-by-segment.sql` | Asset counts per segment |
| `creds-multi-host.sql` | Credentials verified on multiple assets |
| `findings-open.sql` | Open findings, severity sorted |
| `hosts.sql` | Names, current/past IPs, and segments |
| `host-dossier.sql` | Everything structured about one machine |

Run with `sqlite3 db/engagement.db < db/queries/<name>.sql`. Use `bash db/whatweknow.sh <name-or-ip>` only when you intentionally want the DB dossier plus related journal and scan material.

## Storage and naming

- Segment and finding slugs use short kebab-case.
- Screenshots use `<finding-slug>_NN.png`.
- Raw HTTP pairs use `req_NN.http` and `res_NN.http`.
- Reproduction scripts go under `poc/<finding-slug>/`, include a usage banner, and are executable. Evidence registered with `--kind poc` (stored under `scans/`) is materialized into the matching `poc/<finding-slug>/` by `db/ptctl.py poc sync` (run it before packaging; it copies, never prunes, so hand-written repro scripts are preserved).
- Organize `scans/<segment>/` consistently by tool, date, or a deliberate flat layout.
- Client-provided secrets stay in `attachments/`; discovered identities and secrets stay in `wl/`, one append-only/deduplicated file per type.

Recommended discovered-secret files are `wl/usernames.txt`, `wl/passwords.txt`, and algorithm-specific `wl/hashes-<type>.txt`. Insert a DB credential and link it to the asset immediately when it authenticates.

## Reporting checks

Run `python3 db/ptctl.py doctor` during testing and before handoff. Use `--strict` at reporting freeze. It checks DB/Markdown drift, missing artifacts, evidence integrity, and unresolved observation state.

Use `python3 db/ptctl.py board` when a full canonical registry view is intentionally needed. Do not put full board output into automatic session context.

## Session delta outcomes

Inspect filesystem work that occurred after the previous handoff with:

```bash
python3 db/ptctl.py session delta
```

SessionStart opens an active marker, so every interactive PT session requires a closing outcome. Changes under `scans/` or `poc/` additionally activate the artifact capture gate:

```bash
# Security-relevant artifact captured canonically in this session.
python3 db/ptctl.py session close --focus 'orders authorization' \
  --outcome captured --reference O0007

# Tests produced output but no security issue.
python3 db/ptctl.py session close --focus 'orders authorization' \
  --outcome no-finding \
  --assessment 'cross-tenant read/write/delete all returned 403'

# Some artifacts became observations and the remaining tests were negative.
python3 db/ptctl.py session close --focus 'orders authorization' \
  --outcome mixed --reference F03 \
  --assessment 'read was vulnerable; write and delete remained forbidden'

# File-only maintenance unrelated to testing.
python3 db/ptctl.py session close --focus 'artifact cleanup' \
  --outcome administrative \
  --assessment 'renamed imported client documentation'
```

The state file under `.context/` contains only artifact paths/metadata and canonical IDs, never evidence bodies.
