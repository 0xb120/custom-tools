# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

Professional penetration testing and bug bounty automation toolkit. Scripts automate the full recon-to-exploitation workflow: scope ingestion → attack surface mapping → application clustering → screenshot triage → per-app OSINT/crawl + passive subenum (parallel) → subdomain takeover detection (engagement-level + per-app).

## Directory Structure

- `recon/` — Core reconnaissance and vulnerability scanning pipeline scripts
- `org/` — Tool installation, project scaffolding, and config backups (`conf/`)
- `poc/` — Proof-of-concept HTML/XSS/clickjacking payloads for assessments
- `ssh-tools/` — SSH reverse tunnel scripts through bastion hosts
- `utils/` — Wordlist generators for password/user spraying

## Reconnaissance Pipeline Architecture

The scripts chain together in a defined order. `recon-orchestrator.sh` is the top-level driver — everything else is a worker that can also be run standalone:

```
recon-orchestrator.sh <scan_id> <scope>     # Top-level: stages output under /scans/<scan_id>/
    │
    ├── scope2surface.sh        # IP/domain → full attack surface (DNS, ports, fingerprints)
    │                           # honeypot filter: drops hosts with ≥15 open ports
    │                           # Produces scans/subdomains.txt + scans/httpx_full_metadata.jsonl
    │
    ├── run-takeover-scope.sh   # STAGE 1 takeover (background): nuclei -tags takeover against
    │                           # scans/subdomains.txt. Runs concurrently with everything below;
    │                           # findings → <scan_base>/takeovers_scope.jsonl.
    │
    ├── surfagr.sh              # Cluster vhosts by Title+ContentLength+Webserver → per-app dirs
    │   │                       # Reads httpx_full_metadata.jsonl from scope2surface.
    │   │                       # No longer dispatches pipeline-recon — that's the orchestrator's job.
    │   │
    │   └── run-screenshotter.sh   # ONE httpx -screenshot pass against the BEST_HOST of every
    │                              # cluster; drops screenshot.png (or screenshot.failed) into
    │                              # each app dir BEFORE per-app deep recon starts so the operator
    │                              # can begin visual triage in parallel with long-running scans.
    │
    ├── across all apps (two concurrent xargs -P 3 invocations):
    │       ├── pipeline-recon.sh           # OSINT + crawl + download (per app)
    │       │     ├── run-passive-probe.sh    # OSINT (gau + urlfinder in parallel)
    │       │     ├── run-crawler.sh          # Katana; headless for SPA, static otherwise
    │       │     └── run-downloader.sh       # Pull HTML/JS into js/ and html/ subdirs
    │       │
    │       └── pipeline-subenum.sh         # Per-app passive subdomain enumeration:
    │             # subfinder -dL on hosts.txt, dnsx for live filtering, output to
    │             # <app_dir>/discovered_subs.txt.
    │
    └── for each app_dir:
        └── run-takeover-discovered.sh   # STAGE 2 takeover (per-app, parallel via & + wait):
                                         # subjack against the UNION of unique hosts in
                                         # all_endpoints_clean.txt and discovered_subs.txt;
                                         # output → <app_dir>/takeover.txt.
```

Standalone helpers: `find-dirb.sh` (feroxbuster recursive dirbust against a single host).
Orphaned (exists but not called by any pipeline): `run-web-sast.sh` (regex secret/endpoint hunter on downloaded JS), `pipeline-local-discovery.sh` (half-finished refactor of `pipeline-recon.sh`).

## Key Tools Expected in PATH

Project Discovery suite: `httpx`, `dnsx`, `tlsx`, `naabu`, `subfinder`, `shuffledns`, `katana`, `nuclei`, `urlfinder`
Praetorian suite: `fingerprintx`, `nerva`, `julius`
Tom Nomnom: `unfurl`, `assetfinder`, `anew`, `qsreplace`
Takeover: `subjack`
Other: `gau`, `feroxbuster`, `ffuf`, `mapcidr`, `massdns`, `jq`, `ripgrep`, system-installed Chrome/Chromium (for `httpx -screenshot`)

Install all via: `org/install-offsec-tools.sh <install-dir>`

## Project Scaffolding

New PT engagement:
```bash
bash org/newPT.sh
```
Creates: `attachments/`, `scans/`, `poc/`, `wl/`, `scope.txt`, and a Markdown notes file.

## Script Conventions

- **Output & workspace contract for new/modified workers: see [`CONVENTIONS.md`](CONVENTIONS.md).** It mandates the per-app workspace schema (canonical artifacts vs. `raw/<tool>/`), centralized paths (no hardcoded literals), a per-workspace `manifest.jsonl`, thin tool adapters, and a stable `app_id`. Existing scripts predate it — apply it when you touch them.
- Most workers accept input via a positional arg **or** stdin — both forms are supported on `scope2surface.sh`, `run-passive-probe.sh`, `run-crawler.sh`, `run-downloader.sh`. Preserve that dual interface when editing.
- Output dir is the **last** positional arg and defaults to `./<target>` or `./scans/...` — don't hardcode absolute paths.
- Deduplication is done with `anew` or `sort -u`; reuse these rather than reinventing.
- Rate limits are deliberately conservative (e.g., `feroxbuster`: 25 req/s, 10 threads). Don't raise them without a reason — these scripts run against live customer infra.
- Honeypot filter lives in `scope2surface.sh`: hosts with ≥15 open ports are dropped before fingerprinting.
- SPA detection in `run-crawler.sh` keys off httpx tech tags (React/Vue/Angular/Svelte/Next.js) and switches Katana to headless mode for matched targets only — keep the SPA vs. static split when modifying crawler logic, the perf cost of always-headless is significant.
- Temp files go in `/tmp/` and should be cleaned on exit (look for `trap` patterns in existing scripts before adding new tempfile usage).

## Workflow Notes

- The orchestrator writes to `/scans/<scan_id>/` (absolute path, requires that directory to be writable). For ad-hoc runs without an orchestrator, individual workers default to a relative `./` output dir.
- `surfagr.sh` consumes `httpx_full_metadata.jsonl` produced by `scope2surface.sh`. Per-app workspaces it creates at `<dest_dir>/targets/<host>_<title>/` (NOT `app_NNN/` — the orchestrator's globs must match this layout) are the canonical input format expected by `pipeline-recon.sh`, `pipeline-subenum.sh`, and `run-takeover-discovered.sh`.
- For new engagement scaffolding (not the recon pipeline), use `org/newPT.sh` — creates `attachments/`, `scans/`, `poc/`, `wl/`, `scope.txt`, and a Markdown notes file.
- `newPT.sh` scaffolds agent configs for **both** Claude Code (`.claude/`) and Codex (`.codex/`). The two payload-compatible hooks (`log-command.sh`, `render-after-db.sh`) live once in `org/templates/hooks/` and are copied into both agents' `hooks/` dirs; `check-report-format.sh` is Claude-only (`org/templates/claude/hooks/`) since Codex edits go through `apply_patch` (no `file_path`). Codex config is `.codex/config.toml` (`approval_policy=never` + `sandbox_mode=danger-full-access`, the bypassPermissions analog) + `.codex/hooks.json`. Container auth is seeded by `org/seed-codex-env.sh` (mirrors `seed-claude-env.sh`); launch via `./yolo-codex.sh`.
- Tool installation is handled by `org/install-offsec-tools.sh <install-dir>`; the README has the full module breakdown. If a tool is missing at runtime, install via that script rather than ad-hoc — it pins versions and PATH layout the recon scripts depend on.
