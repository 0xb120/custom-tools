# Engagement tooling (`org/`)

`org/` contains the host installer, portable Claude/Codex environment seeders, and the templates used to create a penetration-test workspace. The primary entry point is `newPT.sh`.

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
| `full` | Complete toolkit | every install group |
| `lite` | Desk research, report work, or a small workspace | `base,utils,AI` |
| `none` | Scaffold only | no tool installation |

The optional base is `debian` (the default, `debian:trixie-slim`) or `kali` (`kalilinux/kali-rolling`).

`newPT.sh` requires Bash and `sqlite3` on the host because it creates and initializes `db/engagement.db`. Docker and the Dev Container CLI are needed only when launching the generated container.

## Configure secrets and Burp

The scaffolder copies `org/conf/devcontainer.env` into the generated `.devcontainer/.env`. Create the master file once from the committed example:

```bash
cp org/templates/devcontainer/env-example org/conf/devcontainer.env
chmod 600 org/conf/devcontainer.env
```

The master file and generated `.env` are secret-bearing files and must not be committed.

Claude and Codex are configured to reach the Burp MCP extension on `http://127.0.0.1:9876/sse`. Override that endpoint while scaffolding when necessary:

```bash
BURP_MCP_URL=http://127.0.0.1:18080/sse \
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
│   ├── ptctl.py              # observation, finding, context, and session CLI
│   ├── render.sh
│   ├── whatweknow.sh
│   └── queries/
├── .context/
│   ├── handoff.md            # compact cross-session handoff
│   └── state.json            # artifact and registry baseline; no evidence bodies
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

Session bootstrap is intentionally bounded. It contains the hard rules (bridged for Claude, native for Codex), compact scope, the latest handoff, canonical counts, and a limited number of open task titles. It excludes historical journal prose, completed TODO history, finding prose, evidence bodies, scans, and the full board.

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
```

## Canonical observations and findings

The control plane separates unvalidated leads, concrete observations, and report findings:

| Layer | Identity | Meaning |
|---|---|---|
| Lead | Tool-native file under `scans/<segment>/` | Candidate that has not been validated |
| Observation | `O####` in `db/engagement.db` | One concrete occurrence/test case with registered evidence |
| Finding | `F##` plus `findings/<slug>.md` | One report issue grouping related observations |

Register an observation as soon as manual work relies on a plausible issue:

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

Promote a confirmed observation with registered evidence:

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
python3 db/ptctl.py doctor
python3 db/ptctl.py doctor --strict
bash db/whatweknow.sh <host-or-ip>
```

## Session handoff and capture gate

The SessionStart hooks open an active marker. Before ending meaningful work, inspect changes and write one explicit outcome:

```bash
python3 db/ptctl.py session delta

# Canonical security state was captured or updated.
python3 db/ptctl.py session close \
  --focus 'orders authorization' \
  --outcome captured --reference F01

# Testing produced a negative result.
python3 db/ptctl.py session close \
  --focus 'orders authorization' \
  --outcome no-finding \
  --assessment 'cross-tenant read/write/delete returned 403'

# File-only maintenance.
python3 db/ptctl.py session close \
  --focus 'artifact cleanup' \
  --outcome administrative \
  --assessment 'renamed imported client documentation'
```

Changes under `scans/` or `poc/` activate the capture gate. A `captured` outcome must reference an observation/finding changed during the current session; an old unchanged reference cannot account for new output. `no-finding`, `mixed`, and `administrative` outcomes require an assessment.

The Stop hook runs `doctor` and `session check`. It blocks an agent from ending with canonical drift, untriaged observations, a stale handoff, or an active session without a closing outcome.

## Lifecycle hooks

| Event | Claude | Codex |
|---|---|---|
| Session start | Opens the session and loads bounded context including `AGENTS.md` | Opens the session and loads bounded context; Codex reads `AGENTS.md` natively |
| Shell command | Writes the git-ignored command audit log | Same shared hook |
| DB write | Re-renders Markdown views | Same shared hook |
| Report edit | Checks report prose formatting | Claude-only |
| Stop | Runs the engagement doctor and handoff check | Same shared hook |

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

## Portable agent environments

The seeders copy portable configuration while excluding machine/session state and credentials by default:

```bash
org/seed-claude-env.sh export ./claude-seed
org/seed-claude-env.sh apply /mnt/seed/claude-seed

org/seed-codex-env.sh export ./codex-seed
org/seed-codex-env.sh apply /mnt/seed/codex-seed
```

Pass `--with-credentials` only when the seed remains on trusted local storage. Use `--home <path>` with `apply` to provision another user's home.

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
