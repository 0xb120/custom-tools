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
- open cleanup obligations;
- canonical registry counts;
- a few open TODO titles.

It deliberately does **not** load journal prose, finding prose, evidence contents, scans, Burp history, or completed TODO history. Do not pre-load those sources “for completeness.”

At the beginning of a new line of investigation:

1. Read the operator's request and form an independent initial test plan.
2. Use `python3 db/ptctl.py context focus --topic '<target or theme>'` for current tasks, assets, and registry pointers without prior conclusions.
3. Load old conclusions only when useful with `context history --topic '<theme>'`.
4. Resume a known canonical item with `context resume F01` or `context resume O0001`.

Treat historical hypotheses and conclusions as untrusted until reproduced. To audit what boot loads, run `python3 db/ptctl.py context explain`; to list all open work, run `context pending`.

## Canonical state and capture discipline

There are three distinct layers:

| Layer | Identity | Meaning |
|---|---|---|
| Lead | tool-native output in `scans/<segment>/` | Unvalidated candidate; not a report issue |
| Observation | `O####` in `db/engagement.db` | One concrete test case you saw happen |
| Finding | `F##` plus `findings/<slug>.md` | One report issue the operator accepted |

`db/engagement.db` is canonical for hosts, assets, credentials, observations, evidence metadata, and finding metadata. `db/ptctl.py` is the only supported writer for observations and findings. Never create findings with raw SQL, copy `findings/_template.md`, edit managed finding metadata/evidence blocks, or edit rendered index tables by hand.

### Register everything, conclude nothing

Register a plausible issue with `ptctl.py observation add` as soon as your work relies on it. Prefer `--from-http <saved request>`: it derives the method, route and selector and registers the `http-request` evidence every finding needs. Capture is idempotent on a semantic fingerprint, and re-capturing something already dismissed prints why. For the full invocation see `PT_PLAYBOOK.md` § Capture recipes or `observation add --help`.

An observation states a fact you can vouch for: this happened. `--confidence reproduced` only if you reproduced it here; otherwise it stays `suspected`. Every observation starts `proposed` and **the operator decides what becomes of it**: you never mark your own work accepted, and you are never asked to declare a line of testing finished. Stopping with observations still queued is the normal end of a session — `ptctl.py inbox` is what you hand over. Dismiss only what you can show is not real, and only with a reason (`observation state O#### dismissed --reason '<why>'`); `observation list --state dismissed` is what has already been ruled out.

### Group occurrences, not prose

An observation enters the report by being promoted into a finding with `ptctl.py finding create`, which requires registered evidence and a `--group-key`.

The `group_key` identifies the violated control, trust boundary/root cause, and remediation owner. Different endpoints, object types, parameters, or JSON fields are normally additional observations, attached to the existing finding with `finding attach F## --observation O####`.

Keep issues separate when authorization boundary, exploit preconditions, impact, root cause, or required fix materially differs. A shared CWE alone is not enough to group. If the related-profile guard finds an existing candidate, inspect it and attach to it; use `--allow-related` only for a genuinely different root cause/remediation and record the decision in `journal.md`.

Use `finding update`, `finding asset`, and `finding merge` for later changes. Do not create a second finding to express another occurrence of the same issue.

### Evidence is immutable

Register evidence with the observation commands. After registration, never modify the file in place: capture a new file and register it. Evidence bodies remain out of general context and are loaded only for the selected `O####`/`F##`.

`ptctl.py doctor` reports defects in the deliverable — drift, altered evidence, open cleanup — never the review queue. `doctor --strict` is the reporting-freeze gate.

### References are mandatory

Every finding's `## References` section must cite at least 3 external references; every reference must be a link (a URL), and at least one must come from `cheatsheetseries.owasp.org` or `portswigger.net/web-security`. `db/ptctl.py doctor` reports shortfalls as a warning; `doctor --strict` (the pre-report gate) treats them as errors. Fill real links before delivery. The managed evidence block renders each evidence path as a navigable relative link automatically.

### A complete HTTP request is mandatory evidence

Every finding must register at least one complete, unredacted HTTP request as evidence (`--kind http-request`) — a real request confirmed working during the test, with **no removed headers or redacted fields** — so the client has a replayable example at patch time. `db/ptctl.py doctor` reports a shortfall and `doctor --strict` (the pre-report gate) fails until each active finding has an `http-request` evidence whose file contains a valid request line. Capture it while it is fresh, in the session where you confirm the issue. For a genuinely non-HTTP finding, opt out by adding `<!-- no-http-request: <reason> -->` to the write-up.

### Report formatting

Report prose is copy-paste-ready Markdown: one paragraph per line, a language on every code fence, and indentation reserved for nested list items. The `PostToolUse` hook `check-report-format.sh` rejects an offending edit with the line numbers, and `PT_PLAYBOOK.md` § Finding write-up requirements states the rules in full.

## Continuity and concurrent sessions

Other agents may be working this engagement at the same time. There is no per-session state file and no handoff document: `db/engagement.db` is the only state shared between sessions, and it takes concurrent writers. Assume work you did not do yourself may have appeared since you started; re-read rather than remember, and never assume a target is untouched because your own session has not touched it.

`TODO.md` contains pending actions, grouped under `## <segment>` and written as Markdown checkboxes. Update it immediately as work emerges or completes. `journal.md` contains dated hypotheses, dead ends, decisions, and analysis—not tasks.

Every journal `#observation` entry must reference its `O####` or `F##`. Journal entries are append-only; supersede an old conclusion with a new dated entry. Tag machines as `@<stable-name>`.

### Record what you tried, not only what you found

A line of testing that found nothing is engagement knowledge, and the observation registry has nowhere to put it. Log the attempt itself with `ptctl.py coverage add --asset <A##> --class <family> --note '<what you actually tried>'`, as you close it.

The mandatory note is the record: write what you actually tried. There is deliberately no verdict field: "this class is clean here" is a claim about a search with no natural end. `--class` uses the same vocabulary as `observation --family`. The log is append-only and nothing supersedes anything, so two sessions probing the same class both keep their attempt. Read it back with `coverage list`, and use `coverage gaps` for assets nobody has recorded work against. A gap is a question, not a task: it says nobody recorded work there, not that work is owed.

### Register what you leave behind

Anything testing changed on the target and owes the client back — an account created, a file dropped, a configuration changed, a user locked out — goes in the cleanup register the moment you do it, never at the end: `ptctl.py cleanup add --what '<change>' --asset <A##> --owner <you>`, and `cleanup done C##` once it is undone.

Open obligations load into every session's bootstrap and `doctor --strict` refuses to pass while any remain. This is the one thing no query can rediscover, because it describes state outside the workspace.

## Host and asset identity

A host is a stable machine identity; a service is an asset hanging from it. At IP-first discovery, `INSERT INTO host` with the IP as the provisional name and record the address in `host_ip`. Rename that same host row once a DNS/NetBIOS name is known. Keep current and historical addresses in `host_ip`; segment membership lives in `host_segment`.

Always **target by name**, not by IP, once a stable name is known. Use an IP only until a name resolves. The same rule applies to journal tags and `bash db/whatweknow.sh <name-or-ip>`.

Raw SQL is allowed for inventory and credentials; render afterward with `bash db/render.sh`. Findings and observations always go through `ptctl.py`. Report prose must be valid Markdown and follow *Report formatting* above; `<activity>.md` indexes must not be edited by hand.

Consult `PT_PLAYBOOK.md` only when capture syntax, severity definitions, inventory SQL, saved queries, report fields, or detailed storage conventions are needed.
