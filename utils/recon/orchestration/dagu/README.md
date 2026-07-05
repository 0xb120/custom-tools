# Dagu reproduction of the recon pipeline

A Dagu DAG that drives the contract adapters in [`../../adapters/`](../../adapters/),
producing the canonical `app_id`-keyed workspace. It replaces the legacy
`recon-orchestrator.sh` end-to-end driver. See the design at
`docs/superpowers/specs/2026-06-18-recon-dagu-reproduction-design.md`.

## DAGs

- `recon.yaml` (parent): `scaffold` → `scope2surface` → { `takeover-scope` (stage-1, parallel) ∥
  `surfagr` → `screenshotter` ∥ (`enumerate` → `per-app` fan-out) } → `done`.
- `app.yaml` (child `recon-app`, one run per app_id): `recon` ∥ `subenum` → `takeover`.

The per-app step uses Dagu's dynamic `parallel` over the app_ids discovered at runtime
(`max_concurrent: 3`, matching the legacy `xargs -P 3`). `takeover-scope` runs concurrently
and uses `continueOn: failure`. Retries are disabled (live infra).

## Engagement folder ("the folder created by recon")

The `scaffold` step (runs first, gates everything else) creates the engagement folder at
`$BASE` and copies the input scope to `$BASE/scope.txt`:

```
<activity>/                         # = $BASE
  scope.txt                         # the input scope (copied by scaffold)
  scope/                            # scope2surface expansion (promoted out of raw/)
    scope_init.txt scope_urls.txt scope_dns.txt scope_ip.txt
  scans/                            # surface artifacts + per-target workspaces (siblings)
    subdomains.txt  httpx_full_metadata.jsonl  manifest.jsonl
    findings/takeovers_scope.jsonl
    raw/<tool>/<run>/               # surface-level raw tool output
    <target_hash>/                  # per-target workspace, written by the child app DAG
      meta.json endpoints.txt subs.txt screenshot.png findings/takeover.txt
      raw/<tool>/<run>/ manifest.jsonl
  poc/  wl/  tmp/  logs/
```

The child `app.yaml` writes **inside** this folder: its adapters resolve every path from the
same `lib/paths.sh`, so a per-app run lands in `scans/<target_hash>/` under the `$BASE` the
parent scaffolded. `<target_hash>` is the 12-hex `app_id` (`sha1(host:port)[:12]`).

## How it talks to the contract

Dagu writes no artifact paths. It passes only `BASE`, `ADAPTER_DIR`, `LIB_DIR`, `SCOPE`, `APP_DAG`;
every path resolves inside the adapters via `lib/paths.sh`. The app_id list comes from
`app_ids_json` (single source of truth), not a glob.

## Run

```bash
dagu start utils/recon/orchestration/dagu/recon.yaml -- BASE=/scans/acme SCOPE=/path/scope.txt
```

Defaults (`ADAPTER_DIR`, `LIB_DIR`, `APP_DAG`) assume the standard `/opt/custom-tools` install; pass them explicitly (absolute paths) if the toolkit lives elsewhere — Dagu runs steps in a private work dir, so relative paths will not resolve.

## Tests (offline, no live tools/network)

```bash
bash utils/recon/tests/dagu/test_stubs.sh        # stubs honor the contract
bash utils/recon/tests/dagu/test_dagu_app.sh     # child DAG ordering
bash utils/recon/tests/dagu/test_dagu_smoke.sh   # full pipeline fan-out
```

The smoke tests run the real DAG with `ADAPTER_DIR` pointed at stub adapters
(`../../tests/dagu/stubs/`) that write canonical fixtures via the real `lib/`. The stubs
assert their inputs exist before writing, so the smoke test validates dependency ordering,
not just file presence. Requires the `dagu` binary (see `SYNTAX.md` for the pinned version).

## Syntax

`SYNTAX.md` records the exact Dagu YAML tokens confirmed against the installed binary.
