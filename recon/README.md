# recon/

Reconnaissance pipeline for penetration testing and bug bounty engagements.
Scripts compose into a single orchestrated flow (driven by
`recon-orchestrator.sh`) but every worker can also be run standalone.

## Pipeline flow

```
scope.txt
    │
    ▼
scope2surface.sh ─────────────┐
    │                         │
    ▼                         ▼
surfagr.sh           run-takeover-scope.sh   (Stage 1 takeover, background)
    │                         │
    ▼                         │
run-screenshotter.sh          │
    │                         │
    ▼                         │
for each app_dir (xargs -P 3, two parallel fan-outs):
    ├── pipeline-recon.sh ─── run-passive-probe.sh
    │                       └── run-crawler.sh
    │                       └── run-downloader.sh
    └── pipeline-subenum.sh
    │
    ▼
for each app_dir (parallel):
    run-takeover-discovered.sh   (Stage 2 takeover)
```

## Orchestrator

### `recon-orchestrator.sh`
Top-level driver. Stages output under `/scans/<scan_id>/` and chains every
worker below in the correct order with the right concurrency.

```bash
./recon/recon-orchestrator.sh <scan_id> <scope_file>
```

Requires `/scans/<scan_id>/` to be writable. Use the standalone scripts below
for ad-hoc runs that don't need engagement staging.

## Surface discovery

### `scope2surface.sh`
Expands a scope (IPs, domains, wildcards) into the full attack surface:
DNS resolution, TLS cert parsing, tiered port scanning (1k → 65k after
honeypot filter), and multi-engine fingerprinting (httpx, fingerprintx, nerva).
Hosts with >= 15 open ports are dropped as suspected honeypots.

```bash
# File input
./recon/scope2surface.sh <scope_file.txt> [dest_dir]
# Stdin input
cat scope.txt | ./recon/scope2surface.sh [dest_dir]
```

Key outputs (under `<dest_dir>/scans/`):
- `subdomains.txt` — resolved live subdomains
- `httpx_full_metadata.jsonl` — input format expected by `surfagr.sh`

### `surfagr.sh`
Clusters httpx vhosts by `(Title, Content-Length, Webserver)` into per-app
workspaces and invokes `run-screenshotter.sh` once across all clusters. Does
NOT dispatch per-app recon — that is the orchestrator's job.

```bash
./recon/surfagr.sh <httpx_full_metadata.jsonl> [dest_dir]
```

Creates `<dest_dir>/targets/<host>_<title>/` with `hosts.txt`, `info.txt`
(IP, tech, status), and `screenshot.png` (or `screenshot.failed`).

### `run-screenshotter.sh`
Single httpx `-screenshot` pass against the best host of every clustered app.
Drops each PNG back into its app dir so the operator can start visual triage
before long-running scans finish.

```bash
./recon/run-screenshotter.sh <surface_dir>
```

`<surface_dir>` must contain per-app subdirectories produced by `surfagr.sh`.

## Per-application pipelines

These two run in parallel across all app directories (`xargs -P 3`).

### `pipeline-recon.sh`
Orchestrates passive OSINT, smart crawl, and mass download for one app.

```bash
./recon/pipeline-recon.sh <app_dir>
```

Reads `<app_dir>/hosts.txt`, writes `all_endpoints_clean.txt`, `js/`, `html/`.
Internally chains:

- **`run-passive-probe.sh`** — runs `gau` and `urlfinder` in parallel against
  the host list. Accepts file or stdin; emits a deduplicated URL list.
  ```bash
  ./recon/run-passive-probe.sh <hosts.txt> [out_dir]
  cat hosts.txt | ./recon/run-passive-probe.sh > urls.txt
  ```

- **`run-crawler.sh`** — Katana crawl with automatic SPA vs static split.
  SPA detection keys off httpx tech tags (React/Vue/Angular/Svelte/Next.js);
  matched targets get headless mode, the rest stay on the cheap static path.
  ```bash
  ./recon/run-crawler.sh <targets.txt> [output_name]
  cat targets.txt | ./recon/run-crawler.sh
  ```

- **`run-downloader.sh`** — separates JS from HTML/API URLs, probes with
  httpx, and writes responses to `js/` and `html/` subdirs of the output.
  ```bash
  ./recon/run-downloader.sh <urls.txt> <out_dir>
  cat urls.txt | ./recon/run-downloader.sh <out_dir>
  ```

### `pipeline-subenum.sh`
Per-app passive subdomain enumeration. Reads the app's `hosts.txt`, extracts
unique apex domains, runs `subfinder` (passive sources only) and `dnsx` for
live filtering. Output goes to `<app_dir>/discovered_subs.txt`.

```bash
./recon/pipeline-subenum.sh <app_dir>
```

## Subdomain takeover detection

### `run-takeover-scope.sh`  (Stage 1, engagement-level)
Runs `nuclei -tags takeover` against the scope-level subdomain list produced
by `scope2surface.sh`. Started in the background by the orchestrator and runs
in parallel with everything else.

```bash
./recon/run-takeover-scope.sh <subs_file> <output_jsonl>
```

Empty output means no takeovers found. Errors during scanning never abort the
engagement.

### `run-takeover-discovered.sh`  (Stage 2, per-app)
Runs `subjack` against the union of `all_endpoints_clean.txt` and
`discovered_subs.txt` for one app. Output: `<app_dir>/takeover.txt`.
Subjack signatures complement nuclei's, hence why hosts already covered by
Stage 1 are re-checked here.

```bash
./recon/run-takeover-discovered.sh <app_dir>
```

Note: subjack emits a `[Not Vulnerable]` line for every host. Filter at
triage time with `grep -v 'Not Vulnerable'`.

## Standalone helpers

### `find-dirb.sh`
Feroxbuster directory bruteforce against a single host, conservative defaults
(25 req/s, 10 threads, depth 3). Not part of the orchestrated pipeline.

```bash
./recon/find-dirb.sh <target_dns> [dest_dir]
```

### `run-web-sast.sh`  (orphan)
Regex secret/endpoint hunter on a `js/` directory produced by
`run-downloader.sh`. Currently not wired into any pipeline; run manually after
`pipeline-recon.sh` if you want a quick pass over downloaded JS.

```bash
./recon/run-web-sast.sh <app_dir>
```

### `pipeline-local-discovery.sh`  (orphan / WIP)
Half-finished refactor of `pipeline-recon.sh`. Do not use; prefer
`pipeline-recon.sh`.

## Conventions

- **Input duality** — `scope2surface.sh`, `run-passive-probe.sh`,
  `run-crawler.sh`, `run-downloader.sh` accept their primary input via
  positional arg OR stdin. Preserve this when editing.
- **Output dir is the last positional arg** and defaults to `./<target>` or
  `./scans/...`. Do not hardcode absolute paths.
- **Deduplication** uses `anew` or `sort -u`. Reuse, don't reinvent.
- **Rate limits** are deliberately conservative (e.g. feroxbuster at
  25 req/s). Don't raise them without a reason — these scripts run against
  live customer infrastructure.
- **Temp files** go in `/tmp/` and should be cleaned via `trap` on exit.

## End-to-end example

```bash
# Full orchestrated engagement
./recon/recon-orchestrator.sh acme-2026q2 /path/to/scope.txt

# Ad-hoc surface mapping only (no orchestrator staging)
./recon/scope2surface.sh scope.txt ./out
./recon/surfagr.sh ./out/scans/httpx_full_metadata.jsonl ./apps

# Per-app deep recon on a single cluster after surfagr.sh
./recon/pipeline-recon.sh ./apps/targets/example.com_login/
./recon/pipeline-subenum.sh ./apps/targets/example.com_login/
./recon/run-takeover-discovered.sh ./apps/targets/example.com_login/
```
