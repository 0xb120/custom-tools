# Penetration Test Engagement

> Fill in every `<placeholder>` before testing. This file contains only the rules that must remain active throughout the engagement. Detailed examples and reference material live in `PT_PLAYBOOK.md` and are loaded only when needed.

## Engagement

- **Client**: `<client name>`
- **Activity**: `<activity slug used for the folder>`
- **Type**: `<web / external / internal / mobile / cloud / ...>`
- **Environment**: `<Prod / Pre-prod>`
- **Methodology**: `<Black-box / Grey-box / White-box>`
- **Testing window**: `<start and end, including timezone>`
- **Reporting deadline**: `<YYYY-MM-DD>`
- **Report language**: `<IT / EN>`
- **Contacts**: `<name and contact>`

In-scope targets are listed in `scope.txt`; exclusions are listed in `out-of-scope.txt`. Those files and the authorization details below are hard boundaries.

### Authorization

- Source IPs: `<list>`
- Required custom headers: `<list or none>`
- Traffic/rate constraints: `<list or none>`
- Destructive or disruptive tests: `<explicit authorization or forbidden>`

### Segments

A segment is a logical report section and artifact boundary. Define short kebab-case names before testing.

- `<segment-1>` — `<description>`
- `<segment-2>` — `<description>`

Every generated artifact belongs under `scans/<segment>/`; do not leave loose files directly in `scans/`.

### Credentials and live traffic

Client-provided accounts belong in `attachments/credentials.txt` or an encrypted equivalent. Discovered secrets belong in the git-ignored `wl/` area. Never put credentials in report prose or a shared repository.

Burp MCP actions and shell tooling can generate live client traffic. Remain inside scope, authorization, timing, and rate constraints.

## Operating model: human-led, progressive context

This is a human-in-the-loop engagement. Collaborate with the operator; do not assume autonomous phases or fixed recon/testing/reporting agents.

A fresh session deliberately starts with only:

- these hard rules;
- compact scope boundaries;
- `.context/handoff.md`;
- canonical registry counts;
- a few open TODO titles.

It deliberately does **not** load journal prose, finding prose, evidence contents, scans, Burp history, or completed TODO history. Do not pre-load those sources “for completeness.”

At the beginning of a new line of investigation:

1. Read the operator's request and form an independent initial test plan.
2. Use `python3 db/ptctl.py context focus --topic '<target or theme>'` for current tasks, assets, and registry pointers without prior conclusions.
3. Load old conclusions only when useful with `context history --topic '<theme>'`.
4. Resume a known canonical item with `context resume V01`, `context resume F01`, or `context resume O0001`.

Treat historical hypotheses and conclusions as untrusted until reproduced. To audit what boot loads, run `python3 db/ptctl.py context explain`; to list all open work, run `context pending`.

## Canonical state and capture discipline

There are four distinct layers:

| Layer | Identity | Meaning |
|---|---|---|
| Lead | tool-native output in `scans/<segment>/` | Unvalidated candidate; not a report issue |
| Observation | `O####` in `db/engagement.db` | One concrete test case or occurrence |
| Finding | `F##` plus `findings/<slug>.md` | Confirmed technical issue grouping related observations; not automatically reportable |
| Vulnerability | `V##` plus `vulnerabilities/<slug>.md` | Operator-approved report issue sourced from one or more findings |

`db/engagement.db` is canonical for hosts, assets, credentials, observations, evidence metadata, findings, and report vulnerabilities. `db/ptctl.py` is the only supported writer for observations, findings, and vulnerabilities. Never use raw SQL for those records, copy a managed `_template.md`, edit managed metadata/evidence blocks, or edit rendered index tables by hand.

### Never lose a plausible issue

As soon as manual work relies on a plausible security issue, register it before continuing:

```bash
python3 db/ptctl.py observation add \
  --title 'Cross-tenant read through orderId' \
  --family BOLA --segment customer-portal --asset A1 \
  --component orders-api --boundary cross-tenant \
  --method GET --route '/api/orders/:id' --selector orderId \
  --attacker-role customer --target-role customer \
  --source 'Burp Repeater item 1842' \
  --evidence scans/customer-portal/burp/req-1842.http \
  --evidence scans/customer-portal/burp/res-1842.http
```

The semantic fingerprint makes repeated capture idempotent. Scanner output may remain a lead, but once manually relied on it must become an observation or receive an explicit rejected/inconclusive disposition.

### Group occurrences into technical findings

Promote only a confirmed observation with registered evidence:

```bash
python3 db/ptctl.py finding create \
  --slug cross-tenant-order-access \
  --group-key 'orders-api|object-authorization|cross-tenant' \
  --title 'Cross-tenant access to orders' --severity HIGH \
  --cwe CWE-639 --segment customer-portal --observation O0001
```

The `group_key` identifies the violated control, trust boundary/root cause, and remediation owner. Different endpoints, object types, parameters, or JSON fields are normally additional observations:

```bash
python3 db/ptctl.py finding attach F01 --observation O0002
```

Keep issues separate when authorization boundary, exploit preconditions, impact, root cause, or required fix materially differs. A shared CWE alone is not enough to group. If the related-profile guard finds an existing candidate, inspect it and attach to it; use `--allow-related` only for a genuinely different root cause/remediation and record the decision in `journal.md`.

Use `finding update`, `finding asset`, and `finding merge` for later changes. Do not create a second finding to express another occurrence of the same issue.

### Only selected vulnerabilities enter the report

A finding remains internal until an operator or analyst selects it, normally at closeout but optionally during testing. Never infer promotion from severity or completeness. For 1:1 promotion:

```bash
python3 db/ptctl.py vulnerability promote F01
```

To combine several findings into one report issue:

```bash
python3 db/ptctl.py vulnerability create \
  --slug consolidated-access-control \
  --group-key 'portal|access-control|shared-remediation' \
  --title 'Insufficient access control across portal workflows' \
  --severity HIGH --cwe CWE-862 \
  --finding F01 --finding F03
```

Use `vulnerability attach V01 --finding F04` for later additions and `vulnerability update` for report metadata. Each finding may source only one vulnerability. The report index renders only `vulnerabilities`; unpromoted findings must never appear.

### Evidence is immutable

Register evidence with the observation commands. After registration, never modify the file in place: capture a new file and register it. Evidence bodies remain out of general context and are loaded only for the selected `O####`/`F##`/`V##`.

Before stopping, every observation must be linked, rejected/inconclusive with a reason, or explicitly left in `validating`:

```bash
python3 db/ptctl.py observation state O0005 validating
python3 db/ptctl.py observation state O0006 rejected --reason 'scanner false positive'
python3 db/ptctl.py doctor
```

### References are mandatory

Every promoted vulnerability's `## References` section must cite at least 3 external references; every reference must be a link (a URL), and at least one must come from `cheatsheetseries.owasp.org` or `portswigger.net/web-security`. `db/ptctl.py doctor` reports shortfalls as a warning; `doctor --strict` (the pre-report gate) treats them as errors. Finding references remain optional until promotion.

### A complete HTTP request is mandatory evidence

Every promoted vulnerability must resolve through its source findings to at least one complete, unredacted HTTP request (`--kind http-request`) whose file contains a valid request line. Capture it while it is fresh. For a genuinely non-HTTP vulnerability, opt out in the vulnerability write-up with `<!-- no-http-request: <reason> -->`.

### Report formatting

Report prose is copy-paste-ready Markdown: one paragraph is one continuous line, never hard-wrapped mid-sentence — the renderer wraps it. Every fenced code block must open with a language (```` ```sh ````, ```` ```http ````, ```` ```json ````; ```` ```text ```` when nothing else fits). Nothing is ever indented, with a single exception: a nested list item, indented with spaces and never a tab. Everything else starts at column 0 — fences, prose, tables — including the content that belongs to a bullet or a numbered reproduction step. A `PostToolUse` hook rejects a finding/vulnerability write-up or `<activity>.md` edit that breaks any of these.

## Session continuity

`TODO.md` contains pending actions, grouped under `## <segment>` and written as Markdown checkboxes. Update it immediately as work emerges or completes. `journal.md` contains dated hypotheses, dead ends, decisions, and analysis—not tasks.

Every journal `#observation` entry must reference its `O####`, `F##`, or `V##`. Journal entries are append-only; supersede an old conclusion with a new dated entry. Tag machines as `@<stable-name>`.

At the end of meaningful work, write a bounded handoff:

```bash
python3 db/ptctl.py session close \
  --focus 'authorization testing on orders API' \
  --outcome captured \
  --completed 'confirmed O0001 and attached it to F01' \
  --live-state 'Burp Repeater tab 1842 contains the authenticated request' \
  --next 'test write/delete operations with the same tenant pair' \
  --reference F01
```

SessionStart opens a capture-gate marker, so every Claude/Codex session must end with one explicit outcome even when testing happened only through Burp MCP and produced no local file. `session delta` also compares `scans/` and `poc/` against the previous handoff, including added, modified, and deleted files:

- `captured` — requires an `O####`/`F##`/`V##` reference created or updated during this session;
- `no-finding` — requires `--assessment` describing what was tested and why it was negative;
- `mixed` — requires both a changed canonical reference and an assessment of the negative portion;
- `administrative` — requires `--assessment` explaining why the file change was not testing.

Never reuse an old finding reference to dismiss new output. When unsure, run `python3 db/ptctl.py session delta` and register a new observation before closing.

The Stop hook runs both `doctor` and `session check`. If DB, TODO, journal, activity index, finding/vulnerability prose, `scans/`, or `poc/` changed after the handoff, refresh the handoff and resolve the capture gate before ending. Keep it factual: assessment, completed work, live state, blockers, cleanup obligations, next work, and canonical references—not a second journal.

## Host and asset identity

A host is a stable machine identity; a service is an asset hanging from it. At IP-first discovery, `INSERT INTO host` with the IP as the provisional name and record the address in `host_ip`. Rename that same host row once a DNS/NetBIOS name is known. Keep current and historical addresses in `host_ip`; segment membership lives in `host_segment`.

Always **target by name**, not by IP, once a stable name is known. Use an IP only until a name resolves. The same rule applies to journal tags and `bash db/whatweknow.sh <name-or-ip>`.

Raw SQL is allowed for inventory and credentials; render afterward with `bash db/render.sh`. Vulnerabilities, findings, and observations always go through `ptctl.py`. Report prose must be valid Markdown and follow *Report formatting* above; `<activity>.md` indexes must not be edited by hand.

Consult `PT_PLAYBOOK.md` only when severity definitions, inventory SQL, saved queries, report fields, or detailed storage conventions are needed.
