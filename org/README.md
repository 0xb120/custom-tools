# Engagement tooling (`org/`)

`org/` contains the host installer and the templates used to create a penetration-test workspace. The primary entry point is `newPT.sh`.

## Create an engagement

Run the scaffolder from the directory that should contain the new engagement:

```bash
/path/to/custom-tools/org/newPT.sh <type> <activity_name> [base]
```

For example:

```bash
./org/newPT.sh web acme-portal
./org/newPT.sh internal acme-internal kali
./org/newPT.sh none report-only
```

Supported types select installer groups:

| Type | Intended use | Tool groups |
|---|---|---|
| `web` | Web application test | `base,PD,praetorian,tomnomnom,recon,takeover,dictionary,sast,dast,utils,AI` |
| `external` | External infrastructure test | `base,PD,praetorian,tomnomnom,recon,takeover,dictionary,dast,cracking,utils,AI` |
| `internal` | Internal/network test | `base,PD,tomnomnom,recon,cracking,RT,utils,AI` |
| `cloud` | Cloud assessment | `base,cloud,utils,AI` |
| `mobile` | Mobile assessment | `base,reversing,utils,AI` |
| `code` | White-box source review | `base,sast,utils,AI` |
| `full` | Complete toolkit | every install group |
| `lite` | Desk research, report work, or a small workspace | `base,utils,AI` |
| `none` | Scaffold only | no tool installation |

Each type also selects a set of agent plugins — see [Per-engagement plugins](#per-engagement-plugins).

The optional base is `debian` (the default, `debian:trixie-slim`) or `kali` (`kalilinux/kali-rolling`).

`newPT.sh` requires Bash, `sqlite3` and `python3` on the host: it creates and initializes `db/engagement.db`, and writes the plugin allowlist into the generated `.claude/settings.json`. Docker and the Dev Container CLI are needed only when launching the generated container.

## Configure secrets and Burp

The scaffolder copies `org/conf/devcontainer.env` into the generated `.devcontainer/.env`. Create the master file once from the committed example:

```bash
cp org/templates/devcontainer/env-example org/conf/devcontainer.env
chmod 600 org/conf/devcontainer.env
```

The master file and generated `.env` are secret-bearing files and must not be committed.

Claude and Codex are configured to reach the Burp MCP extension on `http://127.0.0.1:9876` (SSE transport, served at the root path — the extension returns 404 on `/sse` and `/mcp`). Override that endpoint while scaffolding when necessary:

```bash
BURP_MCP_URL=http://127.0.0.1:18080 \
  ./org/newPT.sh web acme-portal
```

The devcontainer uses host networking. Its startup probe warns when the endpoint is unavailable but does not block the container.

## Generated workspace

The important generated paths are:

```text
<activity>/
├── AGENTS.md                 # small, always-on scope and operating rules
├── PT_PLAYBOOK.md            # detailed reference, loaded only when needed
├── CLAUDE.md                 # points Claude to the shared rules
├── scope.txt
├── out-of-scope.txt
├── TODO.md
├── journal.md
├── <activity>.md             # rendered inventory and findings index
├── attachments/              # client-provided material and credentials
├── scans/<segment>/          # tool-native output and captured exchanges
├── poc/<finding-slug>/       # curated reproduction artifacts
├── findings/                 # one managed write-up per canonical finding
├── wl/                       # discovered identities/secrets; keep private
├── db/
│   ├── engagement.db         # canonical structured engagement state
│   ├── ptctl.py              # observation, finding, context, cleanup, coverage CLI
│   ├── render.sh
│   ├── whatweknow.sh
│   └── queries/
├── .claude/                  # Claude hooks and engagement settings
├── .codex/                   # Codex hooks and engagement settings
├── .devcontainer/
├── .mcp.json                 # Claude's project-scoped Burp MCP registration
├── yolo.sh
└── yolo-codex.sh
```

The generated `AGENTS.md` contains authorization boundaries and the rules that must remain active. Fill every placeholder before testing. Keep detailed examples in `PT_PLAYBOOK.md` out of automatic context.

## Start an engagement

After scaffolding:

```bash
cd acme-portal
$EDITOR _init_notes.txt
$EDITOR AGENTS.md
$EDITOR scope.txt
$EDITOR out-of-scope.txt
python3 db/ptctl.py context explain
python3 db/ptctl.py doctor
```

Then launch either agent:

```bash
./yolo.sh
./yolo-codex.sh
```

Both launchers build/start the devcontainer and run their agent with permission bypass enabled. Use them only inside an engagement whose scope and authorization are already correct. For a manual launch:

```bash
bash .devcontainer/up.sh
devcontainer exec --workspace-folder . claude
```

## Progressive context

Session bootstrap is intentionally bounded. It contains engagement identity, compact scope, open cleanup obligations, canonical counts, and a limited number of open task titles. It excludes historical journal prose, completed TODO history, finding prose, evidence bodies, scans, the coverage ledger, and the full board. It also excludes the hard rules themselves: both clients discover `AGENTS.md` natively (Codex reads it, Claude Code hardcodes `CLAUDE.md` / `AGENTS.md` discovery), so inlining it here put the same ~11 KB in context twice, re-paid on every resume and compact.

Load more context deliberately:

```bash
# Audit exactly what automatic boot includes and excludes.
python3 db/ptctl.py context explain

# List open work without completed task history.
python3 db/ptctl.py context pending

# Orient on current tasks, assets, and canonical pointers.
python3 db/ptctl.py context focus --topic 'orders authorization'

# Load prior conclusions only after forming an independent plan.
python3 db/ptctl.py context history --topic 'orders authorization'

# Resume one known observation or finding; evidence files are listed, not inlined.
python3 db/ptctl.py context resume O0001
python3 db/ptctl.py context resume F01

# Surface unexplored attack surface instead of a backlog to close.
python3 db/ptctl.py coverage gaps
```

## Canonical observations and findings

The control plane separates unvalidated leads, concrete observations, and report findings:

| Layer | Identity | Meaning |
|---|---|---|
| Lead | Tool-native file under `scans/<segment>/` | Candidate that has not been validated |
| Observation | `O####` in `db/engagement.db` | One concrete occurrence/test case with registered evidence |
| Finding | `F##` plus `findings/<slug>.md` | One report issue the operator accepted |

An agent captures observations; an operator decides which become findings. That split is the point of the layer: `state` records who decided what (`proposed` → `accepted`/`dismissed`), and an agent reaches only `proposed` on its own. How sure the agent is lives in a separate `confidence` field (`suspected` / `reproduced`), never in the lifecycle, so nothing ever asks a model to declare an open-ended exploration finished — `proposed` is the operator's review queue, not drift to clear.

Register an observation as soon as work relies on a plausible issue:

```bash
python3 db/ptctl.py observation add \
  --title 'Cross-tenant read through orderId' \
  --family BOLA --segment customer-portal --asset A1 \
  --component orders-api --boundary cross-tenant \
  --attacker-role customer --target-role customer \
  --confidence reproduced \
  --from-http scans/customer-portal/burp/req-1842.http \
  --evidence scans/customer-portal/burp/res-1842.http
```

`--from-http` reads the saved request for `--method`, `--route` and `--selector` and registers it as the mandatory `http-request` evidence, so capturing before moving on costs one flag instead of six.

Read the registry back, dismissals included — the reason something was ruled out is what keeps the next session from redoing it:

```bash
python3 db/ptctl.py inbox                          # awaiting an operator decision
python3 db/ptctl.py observation list --state dismissed
python3 db/ptctl.py observation state O0006 dismissed --reason 'scanner false positive'
```

Promote an observation into a report finding (this is what sets `accepted`):

```bash
python3 db/ptctl.py finding create \
  --slug cross-tenant-order-access \
  --group-key 'orders-api|object-authorization|cross-tenant' \
  --title 'Cross-tenant access to orders' \
  --severity HIGH --cwe CWE-639 \
  --segment customer-portal --observation O0001
```

`ptctl.py` owns observation/finding writes, managed finding metadata, evidence blocks, PoC paths, and index rendering. Do not replace those operations with raw SQL or hand-edit a rendered index. Raw SQL remains supported for inventory and credentials; run `bash db/render.sh` afterward.

Useful checks:

```bash
python3 db/ptctl.py board
python3 db/ptctl.py inbox
python3 db/ptctl.py doctor
python3 db/ptctl.py doctor --strict
bash db/whatweknow.sh <host-or-ip>
```

`doctor` reports only defects in the deliverable — drift, altered evidence, open cleanup obligations. An untriaged review queue is not one of those and is reported as a `NOTE` that never fails, including under `--strict`. `whatweknow.sh <host>` folds in the observations that never became findings (with the reason each was dismissed) and every attempt recorded against the machine.

## Concurrent sessions

Several Claude/Codex sessions can work one engagement at the same time. There is no session marker, no shared baseline file, and no handoff document: `db/engagement.db` is the only state shared between them. It runs in WAL mode with `BEGIN IMMEDIATE` writes and a 10s busy timeout, so concurrent writers serialize rather than lose each other's work, and observation fingerprints are idempotent, so two sessions capturing the same issue converge on one `O####`.

The single-tenant `.context/` layer that used to sit here (`handoff.md`, `state.json`, `active.json`) was removed because it was unsound under exactly this condition: one global active marker meant a second session never opened its own gate, and the first session to close rewrote the global baseline, absorbing every other session's in-flight artifacts and silently releasing their capture gate. What it enforced, it enforced only for a single agent.

Two things it held could not be reconstructed from the registry, so they became tables instead.

### Cleanup register — what testing left on the target

```bash
python3 db/ptctl.py cleanup add --what 'created user pentest_tmp' --asset A1 --owner claude
python3 db/ptctl.py cleanup list
python3 db/ptctl.py cleanup done C01 --note 'removed, confirmed gone'
```

Open obligations load into every session's bootstrap, `doctor` warns while any remain, and `doctor --strict` fails. This is state on the client's systems, so no query over `db/` or `scans/` can rediscover it.

### Attempt log — what was tried, tries that found nothing included

```bash
python3 db/ptctl.py coverage add --asset A1 --class bola \
  --note 'cross-tenant read/write/delete all returned 403'
python3 db/ptctl.py coverage list --segment customer-portal
python3 db/ptctl.py coverage gaps
```

There is no verdict field: "this class is clean here" is a claim about a search with no natural end, so the ledger records the attempt and lets the reader judge it. `--note` is therefore mandatory. `--class` normalizes through the same alias table as `observation --family`. The table is append-only and nothing supersedes anything, so concurrent sessions never race on a read-modify-write and every attempt survives. `coverage gaps` reports assets nobody has recorded work against, plus assets missing a class that was exercised elsewhere — the vocabulary is the engagement's own, so there is no taxonomy to maintain.

## Lifecycle hooks

| Event | Claude | Codex |
|---|---|---|
| Session start | Loads bounded context including `AGENTS.md` | Loads bounded context; Codex reads `AGENTS.md` natively |
| Shell command | Writes the git-ignored command audit log | Same shared hook |
| DB write | Re-renders Markdown views | Same shared hook |
| Report edit | Checks report prose, code-fence and indentation formatting | Claude-only |
| Stop | Reports engagement drift on stderr; never blocks | Same shared hook |

Shared scripts live in `templates/hooks/`. Claude-only hooks live in `templates/claude/hooks/`.

## Install tools directly

`install-offsec-tools.sh` can provision a host independently from an engagement:

```bash
sudo bash org/install-offsec-tools.sh /opt
sudo bash org/install-offsec-tools.sh --groups=base,recon,AI /opt
sudo bash org/install-offsec-tools.sh --dry-run --groups=base,recon /opt
```

Supported groups are `base`, `PD`, `praetorian`, `tomnomnom`, `recon`, `takeover`, `dictionary`, `sast`, `dast`, `cracking`, `RT`, `cloud`, `reversing`, `utils`, and `AI`. `--groups=none` is a no-op used by scaffold-only workspaces.

Run the installer through `sudo` from a regular account so user-scoped Go and pipx binaries land in the invoking user's home. `--insecure` disables TLS verification across download mechanisms and is only appropriate behind a trusted intercepting proxy.

## Agent configuration inside the container

The container imports exactly two files from the host — the Claude and Codex credentials — and nothing else. `~/.claude` and `~/.codex` are not mounted, so the operator's plugins, marketplaces, skills and MCP servers never reach an engagement. Containers therefore start with **no plugins and no marketplaces**; Claude regenerates a clean `~/.claude.json` on first launch.

| Mounted from the host | Container path | Copied to |
| --- | --- | --- |
| `~/.claude/.credentials.json` | `/seed/claude-credentials.json` | `~/.claude/.credentials.json` (600) |
| `~/.codex/auth.json` | `/seed/codex-auth.json` | `~/.codex/auth.json` (600) |

Both are read-only binds and both must exist on the host, otherwise container creation fails; `up.sh` checks them first and says which login to run. To log in inside the container instead, delete the corresponding mount line from `.devcontainer/devcontainer.json`.

MCP servers are declared per engagement: `.mcp.json` for Claude (project scope, auto-approved by `enableAllProjectMcpServers`) and a `codex mcp add` in `postCreateCommand` for Codex, which ignores project-scoped `mcp_servers`.

## Per-engagement plugins

The engagement's plugin set lives in its own `.claude/settings.json`. That file is the single source of truth: it is what Claude Code reads, what `claude plugin install --scope project` writes, and what the sync step below applies — so hand-editing and the CLI converge on the same place.

```json
{
  "extraKnownMarketplaces": {
    "trailofbits":             { "source": { "source": "github", "repo": "trailofbits/skills" } },
    "claude-plugins-official": { "source": { "source": "github", "repo": "anthropics/claude-plugins-official" } }
  },
  "enabledPlugins": {
    "burpsuite-project-parser@trailofbits": true
  }
}
```

Both `trailofbits` (`trailofbits/skills`) and `claude-plugins-official` (`anthropics/claude-plugins-official`) are declared in **every** engagement, whether or not it enables a plugin from them: that is what makes them browsable in `/plugin` and installable by name mid-engagement without adding the marketplace first. Claude Code registers the official one for itself anyway, but the row here is what pushes it into the container's *project* scope, which is the only thing `sync-agent-plugins.sh` reads.

Plugins are declared in two places, both at the top of `newPT.sh`. `BASE_PLUGINS` is the set every type gets — the reasoning and write-up side of the work, useful whatever the target is. `type_plugins()` then adds one row per `<type>`, 1:1 with `INSTALL_GROUPS` and with no group indirection. Ids are `<plugin>@<marketplace>`, and every marketplace named must resolve in `marketplace_source()`; scaffolding refuses one that does not, so the mistake surfaces on the workstation instead of inside the container's postCreate.

| Declared in every type | Why |
| --- | --- |
| `ask-questions-if-underspecified@trailofbits` | clarifies an underspecified ask before acting |
| `sharp-edges@trailofbits` | error-prone APIs, footgun configurations |
| `insecure-defaults@trailofbits` | hardcoded credentials, fallback secrets, weak defaults |
| `playground@claude-plugins-official` | self-contained interactive HTML (PoC pages, explorers) |
| `remember@claude-plugins-official` | session memory across engagement sessions |
| `code-simplifier@claude-plugins-official` | tidies up throwaway PoC/exploit code |
| `miro@claude-plugins-official` | boards: attack paths, network diagrams, report figures |

| Type | Adds on top of the base set |
| --- | --- |
| `web` | `burpsuite-project-parser`, `fp-check`, `playwright`, `code-review` |
| `external` | `burpsuite-project-parser`, `fp-check`, `playwright`, `code-review` |
| `internal` | `fp-check` |
| `cloud` | `fp-check`, `supply-chain-risk-auditor` |
| `mobile` | `fp-check`, `audit-context-building`, `variant-analysis`, `code-review`, `claude-security`, `firebase-apk-scanner`, `supply-chain-risk-auditor` |
| `code` | `audit-context-building`, `variant-analysis`, `static-analysis`, `fp-check`, `code-review`, `claude-security`, `supply-chain-risk-auditor`, `trailmark` |
| `full` | every one of the above |
| `lite`, `none` | — (base set only) |

Match a row to what the type can actually do: a plugin whose toolchain is not in that type's `INSTALL_GROUPS` is a skill with no binary underneath. `static-analysis` is the clearest case — `install_sast()` ships CodeQL and Semgrep, and `sast` is only in `web`, `code` and `full`. `firebase-apk-scanner` is the same rule seen from the other side: it shells out to `apktool`, which `install_reversing()` provides, so it belongs to the two types that install `reversing` (`mobile`, `full`) and nowhere else. `trailmark` is the case that made the coupling explicit — its skills probe for a `trailmark` CLI and, finding none, can only answer "trailmark is not installed" while still costing their context, so `install_sast()` now `pipx install`s it (Python 3.12+, from PyPI) and the plugin is declared only where `sast` is. Test 4c in `tests/test-newPT.sh` asserts that pairing for all three. Four entries carry a runtime caveat worth knowing rather than rediscovering. `playwright` starts an MCP server (`npx @playwright/mcp@latest`, so nodejs from the `base` group) whose tool definitions sit in context for the whole session. `remember` installs `SessionStart`/`UserPromptSubmit`/`PostToolUse` hooks that run alongside the engagement's own ptctl context hooks — both write session state, a deliberate duplication. `miro` reaches a **remote** MCP server at `mcp.miro.com`, so whatever an engagement hands it leaves the container. `claude-security` is the single most expensive entry in context (~630 tok, mostly the descriptions of its 8 subagents) and needs `python3` 3.9+ on PATH — its own scanning runs entirely in-session, with no network of its own. Mid-engagement, add anything else with `claude plugin install <plugin>@<marketplace> --scope project`.

Declaring is not enough on its own: a declared-but-uninstalled plugin gets its cache materialised but never loads, so its skills do not reach the session. `sync-agent-plugins.sh` performs the install, idempotently, and verifies the result:

```bash
bash ~/custom-tools/org/sync-agent-plugins.sh /workspace --dry-run   # print the plan
bash ~/custom-tools/org/sync-agent-plugins.sh /workspace             # apply it
```

`postCreateCommand` runs it at container creation; run it again by hand after editing the list, then restart the agent — plugins load at session start. It applies the same list to Codex (`codex plugin add`), whose plugins are container-global since Codex has no project scope. Marketplaces are cloned over HTTPS (`CLAUDE_CODE_PLUGIN_PREFER_HTTPS`), so a public one needs no credentials inside the container.

Keep the lists short: every enabled plugin costs always-on context in every session of the engagement. Enablement is driven entirely by `enabledPlugins` — a plugin with no entry there is inactive, and one set to `false` is declared but off. Settings precedence is user < project < local < flag < policy.

## Validate changes

From the repository root:

```bash
bash tests/test-newPT.sh
bash tests/test-db-host-mapping.sh
bash tests/test-finding-workflow.sh
bash tests/test-context-router.sh
bash tests/test-install-offsec-tools.sh
```

When changing a generated file, edit its source under `org/templates/`; `newPT.sh` copies those templates into new engagement workspaces.
