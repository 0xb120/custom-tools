# Penetration Test Playbook

This is an on-demand reference. It is intentionally excluded from session boot context; consult only the relevant section when needed. Hard engagement rules remain in `AGENTS.md`.

## Finding write-up requirements

Each `findings/<slug>.md` must retain the template sections for Vuln_ID, group key, title, severity, status, affected assets, CWE, segment, observation IDs, impact summary, description, reproduction steps, managed evidence, remediation, and references. `ptctl.py` owns managed metadata and evidence blocks; the tester owns the narrative sections.

The `## References` section is mandatory: at least 3 external references, every one a link (URL), with at least one from `cheatsheetseries.owasp.org` or `portswigger.net/web-security` (prefer the vulnerability-class cheat sheet and the matching Web Security Academy topic, then vendor/CVE/standards/research links). `doctor` flags a shortfall as a warning; `doctor --strict` fails on it, so resolve it before packaging.

The managed evidence block renders each registered path as a navigable Markdown link relative to the write-up (`[scans/…](../scans/…)`); `ptctl.py` maintains it, so never hand-edit the paths.

Every finding must include at least one complete, unredacted HTTP request as evidence (`--kind http-request`): the real request confirmed working during the test, with no removed headers or redacted fields, so the client can replay it at patch time. `doctor` reports a shortfall and `doctor --strict` fails until each active finding has an `http-request` evidence whose file contains a valid request line (`METHOD path HTTP/x.y`). Opt out only for genuinely non-HTTP findings by adding `<!-- no-http-request: <reason> -->` to the write-up.

Write-up Markdown must stay copy-paste-ready: one paragraph per line (never hard-wrapped), and every fenced code block opened with a language (`http` for raw requests and responses, `sh` for commands, `json`/`xml`/`sql` for payloads, `text` when nothing else fits). Indentation is reserved for nested list items — spaces, never a tab — and is allowed nowhere else: a fence, paragraph, or table belonging to a numbered step still starts at column 0, because indented it nests into the list item or turns into an indented-code block and the client cannot paste it out of the report. The Claude `PostToolUse` hook `check-report-format.sh` rejects an offending edit; Codex edits go through `apply_patch` and are not hooked, so there the rule stands on the author.

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

An observation carries two independent things. `state` says **who decided what** — `proposed` (an agent captured it, nobody has ruled on it), `accepted` (promoted into a finding, reachable only through `finding create`/`finding attach`), `dismissed` (ruled out, reason mandatory). `confidence` says what the agent could state as fact about its own work: `suspected`, or `reproduced` if it actually reproduced the behaviour. Keeping them apart is what lets an agent capture freely without ever grading its own homework or declaring an exploration finished.

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

## Capture recipes

The invocations `AGENTS.md` names but deliberately does not spell out, so the rules stay always-on and the syntax stays here. `ptctl.py <command> --help` is authoritative.

```bash
# Register an observation. --from-http derives --method, --route and --selector
# from the saved request and registers it as the http-request evidence every
# finding needs; pass those flags only to override it.
python3 db/ptctl.py observation add \
  --title 'Cross-tenant read through orderId' \
  --family BOLA --segment customer-portal --asset A1 \
  --component orders-api --boundary cross-tenant \
  --attacker-role customer --target-role customer \
  --confidence reproduced \
  --from-http scans/customer-portal/burp/req-1842.http \
  --evidence scans/customer-portal/burp/res-1842.http

# Rule one out. The reason is mandatory and is what a later session reads back.
python3 db/ptctl.py observation state O0006 dismissed \
  --reason 'scanner false positive: output is html-encoded'
python3 db/ptctl.py observation list --state dismissed

# Promote an observation into a report finding.
python3 db/ptctl.py finding create \
  --slug cross-tenant-order-access \
  --group-key 'orders-api|object-authorization|cross-tenant' \
  --title 'Cross-tenant access to orders' --severity HIGH \
  --cwe CWE-639 --segment customer-portal --observation O0001

# Another occurrence of the same issue: attach it, never create a second finding.
python3 db/ptctl.py finding attach F01 --observation O0002
```

Use `finding update`, `finding asset`, and `finding merge` for later changes. If the related-profile guard names an existing candidate, inspect it and attach to it; `--allow-related` is for a genuinely different root cause and remediation, and the decision belongs in `journal.md`.

## Storage and naming

- Segment and finding slugs use short kebab-case.
- Screenshots use `<finding-slug>_NN.png`.
- Raw HTTP pairs use `req_NN.http` and `res_NN.http`.
- Reproduction scripts go under `poc/<finding-slug>/`, include a usage banner, and are executable. Evidence registered with `--kind poc` (stored under `scans/`) is materialized into the matching `poc/<finding-slug>/` by `db/ptctl.py poc sync` (run it before packaging; it copies, never prunes, so hand-written repro scripts are preserved).
- Organize `scans/<segment>/` consistently by tool, date, or a deliberate flat layout.
- Client-provided secrets stay in `attachments/`; discovered identities and secrets stay in `wl/`, one append-only/deduplicated file per type.

Recommended discovered-secret files are `wl/usernames.txt`, `wl/passwords.txt`, and algorithm-specific `wl/hashes-<type>.txt`. Insert a DB credential and link it to the asset immediately when it authenticates.

## Reporting checks

Run `python3 db/ptctl.py doctor` during testing and before packaging. Use `--strict` at reporting freeze. It checks DB/Markdown drift, missing artifacts, evidence integrity, and open cleanup obligations — defects that would ship. It does **not** treat observations awaiting review as drift: those are reported as a `NOTE` that never fails, including under `--strict`, because a queue that has not been triaged yet is normal engagement state and a check that fires on normal state is a check everyone learns to ignore.

Use `python3 db/ptctl.py inbox` for the review queue itself, and `python3 db/ptctl.py board` when a full canonical registry view is intentionally needed. Do not put full board output into automatic session context.

## Attempt log

The observation and finding tables record what was found. The `coverage` table records what was **tried**, tries that found nothing included, so a later session can tell "nobody looked" apart from "looked, this is what was done":

```bash
# A line of testing closed with nothing to report.
python3 db/ptctl.py coverage add --asset A1 --class bola \
  --note 'cross-tenant read/write/delete all 403 for customer/customer'

# Partially explored — the note says where it stopped.
python3 db/ptctl.py coverage add --asset A1 --class xss \
  --note 'reflected params covered; stored paths behind the approval flow untested'

# Tried and it produced something; the detail lives in the observation.
python3 db/ptctl.py coverage add --asset A2 --class auth --note 'lockout bypass reproduced, see O0004'
```

There is no verdict field, by design. A verdict on a test class ("bola: negative") is a claim that an exploration with no natural end is over, and neither an agent nor a tester can make it honestly; the two verdicts that mattered, `negative` and `partial`, differed only by that judgement, and `positive` merely duplicated the observation registry. What is recordable is the attempt, so `--note` is mandatory and carries it. A reader decides from that sentence whether the class is covered enough; the table never decides for them.

`--class` is normalized through the same alias table as `observation --family` (`idor` → `bola`), so the two vocabularies stay comparable. Target with `--asset A1` or `--segment <name>`. The table is append-only and nothing supersedes anything: two sessions probing the same class from different angles each keep their attempt, and no read-modify-write exists for concurrent sessions to race on.

Read it back:

```bash
python3 db/ptctl.py coverage list --segment customer-portal   # every attempt per target/class
python3 db/ptctl.py coverage gaps                             # assets with nothing recorded
python3 db/ptctl.py coverage gaps --segment customer-portal --limit 40
```

`coverage gaps` reports two things: assets nobody has recorded any work against, and assets tested for some classes but not for classes that were exercised elsewhere in the engagement. The class vocabulary is the engagement's own — whatever anyone has recorded — so there is no fixed taxonomy to maintain. Treat the output as questions, not as a task list.

## Cleanup register

Every change testing makes to the target is an obligation until it is undone. Register it when you make it:

```bash
python3 db/ptctl.py cleanup add --what 'created user pentest_tmp' --asset A1 --owner claude
python3 db/ptctl.py cleanup add --what 'uploaded shell.aspx' --location 'https://portal/uploads/' --owner codex
python3 db/ptctl.py cleanup list            # open obligations
python3 db/ptctl.py cleanup list --all      # including resolved ones
python3 db/ptctl.py cleanup done C01 --note 'removed 2026-07-24, confirmed 404'
```

Open obligations appear in every session's bootstrap context, `doctor` warns while any remain, and `doctor --strict` — the reporting-freeze gate — fails. Nothing else in the engagement records this: it is state on the client's systems, not in the workspace, so no query over `db/` or `scans/` can rediscover it.

## Concurrent sessions

Several Claude/Codex sessions can work one engagement at the same time. There is no session marker, no shared baseline file, and no handoff document; `db/engagement.db` is the only shared state, and it is WAL with `BEGIN IMMEDIATE` writes and a 10s busy timeout, so concurrent writers serialize instead of corrupting or losing each other's work. Observation fingerprints are idempotent, so two sessions capturing the same issue converge on one `O####` rather than creating duplicates.

What this costs: nothing tracks per-session artifact deltas any more, so `scans/` output is accounted for by the discipline of registering observations and coverage as work happens, not by a gate at the end. Register as you go.
