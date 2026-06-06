# Custom Tools

Collection of custom scripts for penetration testing and bug bounty automation. Covers the full workflow from scope ingestion to vulnerability reporting.

Planned features and their design notes live in [`ROADMAP.md`](ROADMAP.md).

---

## Directory Overview

| Directory | Purpose |
|-----------|---------|
| `recon/` | Core reconnaissance and vulnerability scanning pipeline |
| `org/` | Tool installation, project scaffolding, configuration backups |
| `poc/` | Proof-of-concept payloads (XSS, clickjacking, CORS) |
| `ssh-tools/` | SSH reverse tunnel utilities for bastion access |
| `utils/` | Wordlist generators for password and username spraying |

---

## Reconnaissance Pipeline (`recon/`)

`recon-orchestrator.sh` is the top-level driver — it stages output under `/scans/<scan_id>/`, kicks off Stage 1 takeover in the background, then runs `surfagr.sh` (clustering + screenshots), dispatches `pipeline-recon.sh` and `pipeline-subenum.sh` in parallel across apps via two concurrent `xargs -P 3` invocations, and finally fires Stage 2 takeover per-app. Every worker below can also be run standalone.

```
recon-orchestrator.sh
    │
    ├── scope2surface.sh
    ├── run-takeover-scope.sh          (background — Stage 1, nuclei)
    ├── surfagr.sh
    │     └── run-screenshotter.sh
    ├── pipeline-recon.sh + pipeline-subenum.sh   (parallel across apps)
    └── run-takeover-discovered.sh     (per-app — Stage 2, subjack)
```

### `recon-orchestrator.sh` — End-to-End Engagement Driver

Top-level entry point. Stages all output under `/scans/<scan_id>/`, manages parallel pipeline dispatch, waits for all background tasks before exiting.

```bash
./recon/recon-orchestrator.sh <scan_id> <scope_file>
```

Requires `/scans/` to be writable (or change `BASE` at the top of the script).

---

### `scope2surface.sh` — Attack Surface Discovery

Expands a raw scope (IPs, domains, wildcards, CIDRs) into a full attack surface map. Performs DNS resolution, TLS cert parsing, subdomain enumeration, tiered port scanning, and multi-engine service fingerprinting. Filters honeypots (≥15 open ports).

```bash
# From file
./recon/scope2surface.sh scope.txt [output_workspace]

# From pipe
cat scope.txt | ./recon/scope2surface.sh [output_workspace]
```

Outputs (under `<output_workspace>/scans/`): `subdomains.txt` (resolved), `unique_ips.txt`, `naabu_full_results.txt`, `httpx_full_metadata.jsonl` (probed), and per-engine fingerprintx/nerva JSONLs.

---

### `surfagr.sh` — Application Grouper

Parses `httpx` JSONL output and clusters vhosts pointing to the same underlying application (grouped by Title + Content-Length + Webserver). Creates one directory per unique app at `<output_workspace>/targets/<host>_<title>/` with `hosts.txt` and `info.txt`, then invokes `run-screenshotter.sh` once across all apps for visual triage. Per-app deep recon dispatch is the orchestrator's responsibility.

```bash
./recon/surfagr.sh httpx_full_metadata.jsonl [output_workspace]
```

---

### `pipeline-recon.sh` — Per-Target Full Recon

Orchestrates the three sub-workers below (passive → active → download) for a single application workspace directory created by `surfagr.sh`.

```bash
./recon/pipeline-recon.sh <app_workspace_dir>
```

---

### `pipeline-subenum.sh` — Per-Target Passive Subdomain Enumeration

Sibling to `pipeline-recon.sh`. Reads `<app_dir>/hosts.txt`, extracts unique domains via `unfurl`, runs `subfinder` (passive sources only, no brute-force) and pipes through `dnsx` to keep only live subdomains. Writes results to `<app_dir>/discovered_subs.txt`. Dispatched by `recon-orchestrator.sh` in parallel with `pipeline-recon.sh` across apps.

```bash
./recon/pipeline-subenum.sh <app_workspace_dir>
```

---

### `run-passive-probe.sh` — OSINT URL Discovery

Queries passive intelligence sources (Wayback Machine, AlienVault, Common Crawl, etc.) via `gau` and `urlfinder` in parallel. Outputs a deduplicated URL list.

```bash
./recon/run-passive-probe.sh hosts.txt [output_dir]
cat hosts.txt | ./recon/run-passive-probe.sh
```

---

### `run-crawler.sh` — Smart Active Crawler

Detects tech stack for each target and splits into SPA (React, Vue, Angular, Svelte, Next.js) vs. standard batches. Runs Katana in headless mode for SPAs, fast static mode otherwise. Outputs both JSONL and TXT.

```bash
./recon/run-crawler.sh targets.txt [output_name]
cat targets.txt | ./recon/run-crawler.sh
```

---

### `run-downloader.sh` — Mass Content Downloader

Separates JavaScript files from HTML/JSON endpoints, probes with `httpx`, and downloads responses into `js/` and `html/` subdirectories.

```bash
./recon/run-downloader.sh urls.txt <output_dir>
cat urls.txt | ./recon/run-downloader.sh <output_dir>
```

---

### `run-screenshotter.sh` — Per-App Visual Triage

Captures one screenshot per clustered web application using `httpx -screenshot` (chromedp under the hood). Walks each app's `hosts.txt` under `<surface_dir>/`, picks the BEST_HOST per cluster (DNS preferred over IP), runs a single httpx invocation against all BEST_HOSTs, and distributes PNGs into each app dir as `screenshot.png`. Apps whose capture failed get a one-line `screenshot.failed` marker with the reason. Invoked automatically by `surfagr.sh` after clustering — PNGs are available for triage before the per-app pipelines (recon + subenum) start running.

Requires `httpx`, `jq`, and a system-installed Chrome/Chromium.

```bash
./recon/run-screenshotter.sh <surface_dir>
# <surface_dir> is the parent of <host>_<title>/ subdirectories produced by surfagr.sh
# (in orchestrator runs that's <scan_base>/apps/targets/)
```

> **Future:** TODO comment in-script tracks migrating to `gowitness` v3.x for engagements where a grid-view report (`gowitness report serve`) is worth the dependency.

---

### `run-takeover-scope.sh` — Stage 1 Subdomain Takeover (Engagement-Level)

Runs `nuclei -tags takeover` against the resolved subdomain list from `scope2surface.sh`. Invoked in the background by `recon-orchestrator.sh` immediately after `scope2surface.sh`, so it runs concurrently with clustering and per-app recon — adding effectively zero wall-time.

```bash
./recon/run-takeover-scope.sh <subs_file> <output_jsonl>
# Example:
./recon/run-takeover-scope.sh /scans/<id>/att_surface/scans/subdomains.txt /scans/<id>/takeovers_scope.jsonl
```

Empty input is success (exits 0 with empty output). nuclei errors log a warning but never abort the engagement.

---

### `run-takeover-discovered.sh` — Stage 2 Subdomain Takeover (Per-App)

Runs `subjack` against the union of unique hosts from `<app_dir>/all_endpoints_clean.txt` (deduped OSINT + crawled URLs from `pipeline-recon.sh`) and `<app_dir>/discovered_subs.txt` (subfinder-derived live subs from `pipeline-subenum.sh`). Invoked per-app by `recon-orchestrator.sh` after both per-app pipelines complete, in parallel via `&` + `wait`. Each app gets its own `takeover.txt`.

Re-checks scope hosts that the crawl rediscovered — subjack's signatures complement nuclei's in Stage 1.

Requires `subjack` (install via `org/install-offsec-tools.sh`) and `unfurl`.

```bash
./recon/run-takeover-discovered.sh <app_dir>
```

---

### `find-dirb.sh` — Directory Brute Force

Runs `feroxbuster` recursively (depth 3) against a target using SecLists `common.txt`. Conservative rate limiting (25 req/s, 10 threads).

```bash
./recon/find-dirb.sh example.com [output_dir]
```

---

## Organization Scripts (`org/`)

### `install-offsec-tools.sh` — Tool Installer

Installs the full penetration testing toolkit. Modules:
- **Base**: `git`, `curl`, `jq`, `tmux`, `docker`, Go 1.24.4, etc.
- **Project Discovery**: `httpx`, `dnsx`, `tlsx`, `naabu`, `nuclei`, `katana`, `subfinder`, `shuffledns`, `urlfinder`
- **Praetorian**: `fingerprintx`, `nerva`, `julius`, `brutus`, `augustus`, `titus`
- **Tom Nomnom**: `unfurl`, `assetfinder`, `anew`, `qsreplace`
- **Takeover**: `subjack`

```bash
./org/install-offsec-tools.sh <install_directory>
```

### `newPT.sh` — Project Scaffolding

Creates a standardized engagement directory structure: `attachments/`, `scans/`, `poc/`, `wl/`, `scope.txt`, and a Markdown notes file.

```bash
./org/newPT.sh
```

### `comparer.py` — File Differ

Compares two files line by line and prints lines unique to each. Useful for scope diffs or deduplicating wordlists.

```bash
python3 org/comparer.py file1.txt file2.txt
```

### `webm2gif.sh` — Screen Recording Converter

Converts `.webm` screen recordings to `.gif` for PoC attachments.

```bash
./org/webm2gif.sh recording.webm
```

---

## Wordlist Generators (`utils/`)

### `gen-pwd-wl.sh` — Password Wordlist

Generates a target-specific password list from a customer label and hostname. Produces variants with the current year (±10 years), capitalization, and common symbols, plus default passwords (`admin`, `P@ssword!`, etc.).

```bash
./utils/gen-pwd-wl.sh <customer_label> <hostname>
# Output: /tmp/wordlists/
```

---

## PoC Templates (`poc/`)

Ready-to-use HTML/SVG payloads for common web vulnerabilities:

| File | Type |
|------|------|
| `reflected-xss-poc.html` | Reflected XSS |
| `reflected-xss-input-poc.html` | Input-based XSS |
| `svg-xss.svg` | SVG XSS |
| `clickjacking.html` | Clickjacking |
| `csd.html`, `csd2.html` | CORS / SOP bypass |
