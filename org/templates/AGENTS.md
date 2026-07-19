# Penetration Test Engagement

> Fill in every `<placeholder>` before starting work. This file is the single source of truth for engagement-specific rules — Claude Code and any other agent reads from here.

## Engagement Info

- **Client**: `<client name>`
- **Activity name**: `<activity slug used for the folder>`
- **Engagement type**: `<web app / external network / internal network / red team / mobile / cloud / ...>`
- **Environment**: `Prod / Pre-prod`
- **Methodology**: `Black-box / Grey-box / White-box`
- **Start date**: `<YYYY-MM-DD>`
- **End date**: `<YYYY-MM-DD>`
- **Reporting deadline**: `<YYYY-MM-DD>`
- **Report language**: `<IT / EN>`

## Client Contacts

- test@test.com

## Scope

In-scope: see `scope.txt` (one target per line).
Out-of-scope: see `out-of-scope.txt` (one target per line).

More details about the scope below:

### Authorisation

Source IPs used for testing: 
- `<list>`

Custom headers used for testing, if any:
- `<list>`


## Credentials

**Client-provided** test accounts and other secrets the client hands you go in `attachments/credentials.txt` (or an encrypted file). **Discovered** credentials (recon hits, dumps, cracking, spray hits) go in `wl/` — see [Credential tracking](#credential-tracking) for the layout and the valid-combinations table.

**Never** paste credentials into the report draft or commit them to a shared repo.


## Rules for Artifact Storage

Everything produced during the engagement must live under this folder, organised as:

```
<activity_name>/
├── AGENTS.md                 # this file — engagement rules
├── CLAUDE.md                # pointer to AGENTS.md for Claude Code
├── scope.txt                # canonical in-scope targets, one per line
├── out-of-scope.txt         # canonical out-of-scope targets, one per line
├── <activity_name>.md       # findings index + executive summary
├── TODO.md                  # task list — what's left to do, grouped by segment
├── journal.md               # chronological log — observations, hypotheses, dead-ends, decisions
├── attachments/             # client-provided files (NDA, auth letter, docs, credentials)
├── scans/                   # tool output, organised by logical segment (see below)
│   └── <segment>/           # e.g. web-customer-portal, external-network, internal-ad, mobile-ios
│       └── ...              # per-tool / per-date / flat — pentester's choice inside the segment
├── findings/                # one structured write-up per finding
│   ├── _template.md         # reference template — copy per new finding, do not edit in place
│   └── <finding_slug>.md    # schema in "Findings" section below
├── poc/                     # proof-of-concept artefacts, one folder per finding
│   └── <finding_slug>/      # screenshots, HTTP exchanges, exploit scripts
├── logs/                    # command audit log (auto-written by a Claude hook) — git-ignored, may hold secrets
└── wl/                      # wordlists + discovered creds — one file per type (see "Credential tracking")
```

### Segments

A **segment** is a logical block of the engagement that maps to a section of the final report (e.g., one web application, the external network, the internal AD, the mobile app). Pick segment names up-front and list them here:

- `<segment-1>` — `<short description>`
- `<segment-2>` — `<short description>`

Rules:

- Every artefact produced (manual or automated) lives under `scans/<segment>/`. No loose files directly in `scans/`.
- Inside a segment, the pentester is free to organise per-tool (`nmap/`, `burp/`, `nuclei/`), per-date (`20260515/`), or flat — pick one and be consistent within the segment.

How to pick segments, by engagement type:

- **Web PT (single-app)** — segment is the application itself (e.g., `customer-portal`).
- **External PT** — one segment per in-scope domain or IP (e.g., `example-com`, `203-0-113-10`).
- **Internal PT** — one segment per target network (e.g., `server`, `pc`, `wifi-guest`, `wifi-corp`, `voip`, `printers`, `cameras`, `ilo`, `ot`, `dmz`, `mgmt`). For multi-site engagements prefix with the site (`<site>-<network>`).

### Naming conventions

- `segment`: short-kebab-case (`web-customer-portal`, `external-network`, `internal-ad`, `mobile-ios`, `main`).
- `finding_slug`: short-kebab-case (`reflected-xss-search-param`, `idor-user-profile`).
- Screenshots: `<finding_slug>_NN.png`, numbered sequentially.
- HTTP exchanges: save raw request/response pairs as `req_NN.http` and `res_NN.http` inside the finding folder.
- Scripts / one-liners used to reproduce: `<finding_slug>/repro.sh` (executable, with a usage banner).

### Findings

Each finding has **three** related artefacts, all sharing the same `finding_slug`:

| Where | What |
|-------|------|
| `findings/<finding_slug>.md` | Structured write-up — schema below. Source of truth. |
| `poc/<finding_slug>/` | Evidence: screenshots, raw HTTP, repro scripts. |
| `<activity_name>.md` (index table) | One row linking to the write-up; single place to see all findings at a glance. |

**LLM workflow** (every new confirmed vulnerability):

1. Copy `findings/_template.md` to `findings/<finding_slug>.md` and fill in every field per the schema below.
2. Drop evidence into `poc/<finding_slug>/`.
3. INSERT a row into the `finding` table in `db/engagement.db` (the `evidence_path` and `poc_dir` columns auto-default from `slug` — see § Engagement database for the snippet).
4. Run `bash db/render.sh` to refresh the findings index in `<activity_name>.md`.

Do all four in the same session. The DB row holds the structured metadata (severity, status, segment, paths); the per-finding `.md` holds the prose. Both must exist for the same `slug`. **Never edit the rendered findings index by hand** — it's regenerated from the DB on every render.

#### Prose formatting

All report prose — finding write-ups, the executive summary, any text destined for the report — must be **copy-paste-ready with valid Markdown**. The single rule that matters:

- **Never hard-wrap mid-sentence.** Write each paragraph as one continuous line and let the renderer wrap it. Do not insert manual newlines to keep the source column-aligned — a paragraph split across several short lines breaks reflow, copy-paste, and search the moment it lands in the report.
- Hard newlines belong **only** between paragraphs, list items, table rows, and other block boundaries — never inside a flowing sentence.

#### Per-finding file (`findings/<finding_slug>.md`)

Each file must ALWAYS include:

- Vuln_ID (`finding_slug`)
- Title
- Severity (Critical / High / Medium / Low / Informational — see scale below)
- Status (`open` / `fixed` / `non-reproducible`)
- Affected asset(s)
- Related CWE(s)
- Impact summary (very short and high level, two or three lines max)
- Description
- Reproduction steps
- Evidence (links to `poc/<finding_slug>/`)
- Remediation
- References (list of links)

#### Findings index (`<activity_name>.md`)

Rendered from `db/engagement.db` (`finding` table) by `bash db/render.sh`, between the `<!-- db:render findings -->` markers. **Never edit this table by hand** — re-run render after every INSERT/UPDATE.

Output shape:

```
| ID  | Severity | Title                                                            | Status | Segment              |
|-----|----------|------------------------------------------------------------------|--------|----------------------|
| F01 | CRITICAL | [Reflected XSS on /search](findings/reflected-xss-search.md)     | open   | web-customer-portal  |
| F02 | HIGH     | [IDOR on /api/users/:id](findings/idor-user-profile.md)          | open   | web-customer-portal  |
```

- `ID` is `'F' || printf('%02d', f.id)` — sequential, derived from the DB row id, never reused.
- Title links to `evidence_path` (defaults to `findings/<slug>.md`).
- Rows are sorted by severity (Critical → Informational), then by `id`.

### Severity scale

Use this scale company-wide. Pick the level that best matches the *assessed impact*, not the CVSS number alone.

**CRITICAL**

A security vulnerability that allows an attacker to compromise the target application or system completely. In some cases, it will enable said attacker to gain access, with varying privilege levels, to confidential data, with partial or full integrity and/or confidentiality compromise.

CRITICAL vulnerabilities can usually be exploited with relative ease, often not requiring previous knowledge of valid users, sometimes with a low degree of difficulty and often exploitable via remote automated systems, with high reliability.

Resolution of CRITICAL vulnerabilities is absolutely vital to maintain data and/or systems integrity and/or confidentiality, especially when found in production environments.

**HIGH**

Security vulnerability which allows an attacker to sensibly compromise data and/or systems' confidentiality and/or integrity.

Despite the high potential risk, usually attack constraints are in place which hinder the probability of a successful exploitation, e.g.: by requiring a highly-privileged account, or by requiring the total lack of access control rules.

**MEDIUM**

Security vulnerability which can give an attacker access to a restricted set of non-critical data, only partially compromising confidentiality and usually not integrity.

Nevertheless, there are cases in which such a vulnerability might damage data and/or systems integrity, but to a much lesser degree than higher-severity ones.

The ability to exploit such a vulnerability is usually further hindered by specific requirements, like having administrative access to a system, making exploitation possible, but still quite unlikely in ordinary situations.

**LOW**

Security vulnerability which impacts confidentiality, integrity and/or availability to a slight degree, or heavily limited by the presence of constraints.

Nevertheless, such a vulnerability might provide an attacker with critical bits of information aiding in further exploitation of higher-severity vulnerabilities in the process.

It is therefore strongly advised not to ignore this type of vulnerability.

**INFORMATIONAL**

Issue which does not cause a confidentiality, integrity and/or availability compromise to any degree.

Such a vulnerability often hints at the lack of security practices, often in the form of "lazy" update policies.

Although not inherently dangerous, addressing these kinds of issues improves the overall security with low effort, contributing to building a more solid security stance for companies.

### Engagement database

`db/engagement.db` (SQLite) is the source of truth for **assets**, **credentials**, and **finding metadata**. The markdown tables in `<activity_name>.md` are rendered from the DB by `db/render.sh` between `<!-- db:render <block> -->` markers — never edit those tables by hand.

What lives where:

| Data | Source of truth | Rendered to |
|------|-----------------|-------------|
| Host map (name↔IP) | DB (`host`, `host_ip`, `host_segment`) | `<activity_name>.md` § Host inventory |
| Asset inventory | DB (`host`, `host_ip`, `asset`, `host_segment`) | `<activity_name>.md` § Asset inventory |
| Valid credentials | DB (`credential`, `credential_asset`) | `<activity_name>.md` § Valid credentials |
| Finding metadata | DB (`finding`, `finding_asset`) | `<activity_name>.md` § Findings index |
| Finding prose | `findings/<slug>.md` (markdown) — DB row's `evidence_path` points here | — |
| Finding evidence | `poc/<slug>/` (screenshots, http, repro) — DB row's `poc_dir` points here | — |
| Wordlists (raw) | `wl/*.txt` (one file per type) — optionally referenced by `credential.source_path` | — |

**Common writes** (operator and agent run these as needed):

```bash
# Define segments first — needed before hosts/findings can reference them.
sqlite3 db/engagement.db "INSERT INTO segment (name, description) VALUES
  ('server', 'on-prem servers'),
  ('pc',     'workstations');"

# Register a machine. At IP-first discovery the name IS the IP; rename it in
# place once DNS/NetBIOS resolves (the host id — the stable identity — is kept).
sqlite3 db/engagement.db "INSERT INTO host (name) VALUES ('10.0.0.5');"
# host_id via sub-select — last_insert_rowid() is per-connection and would be 0 in a separate sqlite3 call.
sqlite3 db/engagement.db "INSERT INTO host_ip (host_id, ip)
  VALUES ((SELECT id FROM host WHERE name='10.0.0.5'), '10.0.0.5');"
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

# Record a credential and verify it against an asset (the moment it authenticates).
# source_path is optional — set it to the file the cred came from (wl/hashes-*.txt,
# scans/.../dump.txt, …) so you can trace back where it was extracted.
# Chain the two INSERTs in one sqlite3 call so last_insert_rowid() (per-connection) resolves the credential.
sqlite3 db/engagement.db "
  INSERT INTO credential (username, secret, secret_type, role, source, source_path)
    VALUES ('admin', 'P@ssw0rd', 'password', 'admin', 'sprayed', 'wl/passwords.txt');
  INSERT INTO credential_asset (credential_id, asset_id, verified_at)
    VALUES (last_insert_rowid(),
            (SELECT id FROM asset WHERE host_id=(SELECT id FROM host WHERE name='DC01') AND port=445),
            CURRENT_TIMESTAMP);"
sqlite3 db/engagement.db "UPDATE asset SET access='admin' WHERE host_id=(SELECT id FROM host WHERE name='DC01') AND port=445;"

# Index a new finding (prose still lives in findings/<slug>.md).
# evidence_path defaults to 'findings/<slug>.md' and poc_dir to 'poc/<slug>/'
# automatically on INSERT — override explicitly only if the report lives elsewhere.
sqlite3 db/engagement.db "INSERT INTO finding
  (slug, title, severity, status, cwe, segment_id)
  VALUES ('reflected-xss-search', 'Reflected XSS on /search',
          'CRITICAL', 'open', 'CWE-79',
          (SELECT id FROM segment WHERE name='customer-portal'));"

# Override evidence_path explicitly when the report lives outside findings/:
sqlite3 db/engagement.db "INSERT INTO finding
  (slug, title, severity, evidence_path, segment_id)
  VALUES ('q2-summary', 'Q2 cumulative summary', 'INFORMATIONAL',
          'reports/2026Q2/summary.md',
          (SELECT id FROM segment WHERE name='customer-portal'));"
```

**Common reads** — saved snippets under `db/queries/`:

| Query file | Purpose |
|------------|---------|
| `assets-no-access.sql` | Assets where `access IS NULL` — what's still to crack |
| `assets-by-segment.sql` | Count of assets per segment |
| `creds-multi-host.sql` | Credentials verified on more than one asset |
| `findings-open.sql` | Open findings, severity-sorted |
| `hosts.sql` | The name↔IP host map (current + past IPs, segments) |
| `host-dossier.sql` | Everything the DB knows about one machine — bind `:host` to a name or any IP it has held |

Run any of them with `sqlite3 db/engagement.db < db/queries/<name>.sql`.

**What do we know about one machine?** `bash db/whatweknow.sh <name-or-ip>` folds the DB dossier (`host-dossier.sql`), journal entries, and raw `scans/` output into a single machine-centric view — across the machine's full token set: its `name`, `dns`, and every IP it has ever held. So a scan captured under a now-retired DHCP IP still surfaces when you query by the stable name.

**Refresh the markdown view**: `bash db/render.sh` — re-run after each batch of writes and before committing.

### Asset tracking

Every discovered service — a port on a machine — gets a row in `db/engagement.db` (`asset`), hanging off the machine (`host`) it runs on via `host_id`. Register the machine first (`host` + `host_ip`), then add its services. Rendered to `<activity_name>.md` § Asset inventory by `bash db/render.sh`, one sub-table per segment. INSERT at first discovery, `UPDATE` in place as enrichment lands — never duplicate rows for the same service (the schema enforces `UNIQUE(host_id, port)`). **Never edit the rendered tables by hand**; see § Engagement database for the INSERT/UPDATE snippets.

Host vs. service:

A service row (`asset`) hangs off a machine (`host`) via `host_id`. The machine's `name` is its stable identity — provisional (= the IP) at discovery, renamed in place once DNS/NetBIOS resolves, keeping the same id. Every IP the machine has held lives in `host_ip` (`current=1` = the live lease, retired leases kept for history). Segment membership is on the machine (`host_segment`) and inherited by all its services. `UNIQUE(host_id, port)` replaces the old `UNIQUE(host, port)`.

**Always target by name, not by IP.** When you scan, probe, or invoke any tool against a machine, use its hostname/DNS name whenever one is known; fall back to an IP **only** for a machine with no verbose name yet (and rename it the moment one resolves). Names are stable across DHCP — an IP-keyed command silently hits whatever machine currently holds that lease, which may no longer be your target. The same rule governs journal `@<tag>`s and `whatweknow.sh` lookups: prefer `@<name>` / `whatweknow.sh <name>`, IP only as a last resort.

Column semantics:

- `port` / `protocol` / `tls` — straight from the fingerprint (`httpx`, `fingerprintx`, `naabu` + probe). `tls` is `0` / `1`.
- `version` — banner / Server header / SNI cert subject; whatever identifies the service build.
- `technologies` — stack fingerprint (CMS, framework, library, …), comma-separated. From `httpx -tech-detect`, Wappalyzer, manual recon.
- `access` — operational status: NULL (none), `anonymous`, `read-only`, `user`, `admin`, `rce`, … **Run `UPDATE asset SET access = '<level>' WHERE …` the moment a valid combo authenticates or a vuln yields access.**

Working combos: INSERT into `credential` + link via `credential_asset` (with `verified_at`), AND `UPDATE asset SET access = …` in the same flow. The two stay coherent because they're rows in the same DB, not parallel markdown tables.

### Credential tracking

Anything that resembles an identity — usernames, passwords, hashes, tickets, tokens, SSH keys — lives in `wl/`, **one file per type**, never one file per source. Append-only; dedupe with `sort -u` or `anew`.

- `wl/usernames.txt` — one identifier per line.
- `wl/passwords.txt` — one cleartext password per line.
- `wl/hashes.txt` — one hash per line. Split per algorithm if mixed (`wl/hashes-ntlm.txt`, `wl/hashes-bcrypt.txt`, …).
- `wl/<other>.txt` — same rule for API keys, JWTs, tokens, SSH private keys, etc.

Discovered credentials go in `wl/`. **Client-provided test accounts stay in `attachments/credentials.txt`** — don't mix the two. **Never** commit `wl/` to a shared repo.

#### Valid combinations

Confirmed credentials (anything that authenticated successfully) live in `db/engagement.db` — `credential` row + `credential_asset` link with `verified_at` set to the auth timestamp. Rendered to `<activity_name>.md` § Valid credentials by `bash db/render.sh`. **Never edit the rendered table by hand.**

INSERT the moment the combo authenticates, not at engagement close. Later segments and lateral-movement attempts query this via `db/queries/creds-multi-host.sql` and friends — see § Engagement database for the INSERT snippet.

### TODO tracking

`TODO.md` is the engagement's task list — what's left to do. **The LLM agent reads this file at the start of every session** and uses it as the source of truth for pending work.

Format:

- `## Engagement-wide` at the top for tasks that don't belong to a specific segment.
- One `## <segment>` header per segment, in the same order as the engagement's segments.
- Tasks as markdown checkboxes under the right header: `- [ ] short description #tag` → flip to `- [x]` when done.
- Optional tags to classify: `#recon`, `#exploit`, `#manual`, `#followup`, `#report`, `#blocked`.

LLM workflow (every session):

1. Read `TODO.md` first; load open items (`- [ ]`) into the in-session task tracker.
2. When new tasks emerge during work, append them to `TODO.md` under the right segment immediately.
3. Flip `- [ ]` → `- [x]` as soon as a task is done; add a short trailing note if context matters (`- [x] enumerate subdomains — found 47, see scans/external-network/subfinder/`).
4. Findings, observations, hypotheses, dead-ends → `journal.md`. Not here.

### Working journal

`journal.md` is the engagement's chronological log — observations, hypotheses, dead-ends, decisions. **Tasks live in `TODO.md`, not here.** Do not put working notes in `<activity_name>.md` (that file is for structured findings only).

Format:

- Date headers `## YYYY-MM-DD`, one per active day.
- Free-form entries underneath, tagged inline for retrieval: `#observation`, `#hypothesis`, `#dead-end`, `#decision`.
- Tag the machine an entry concerns with `@<name>` — the stable host name (fall back to `@<ip>` only when the name isn't known yet; `whatweknow.sh` expands either to the machine's full alias set). This is the journal's host index — `grep '@DC01' journal.md` reconstructs that machine's full analysis history in one shot.
- Entries are immutable. To update or close one, append a new dated entry that references the original (don't edit in place).
- When an entry implies a follow-up action, log the observation here AND create a `- [ ]` item in `TODO.md` (cross-reference by short description).

Slice any tag with `grep '#hypothesis' journal.md`. For everything known about one machine across all sources, run `bash db/whatweknow.sh <name-or-ip>`.
