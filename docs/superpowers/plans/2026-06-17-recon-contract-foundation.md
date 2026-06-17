# Recon Contract Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the shared, tool-agnostic contract substrate (`lib/` + thin per-worker adapters) that makes the `CONVENTIONS.md` workspace/output contract real, without modifying any proven worker script.

**Architecture:** Three sourceable libraries (`paths.sh`, `appid.sh`, `manifest.sh`) hold the single source of truth for paths, the stable `app_id`, and manifest provenance. One thin adapter per worker wraps the unchanged worker in two halves: `run_<tool>` materializes the inputs the legacy worker expects and runs it into `raw/<tool>/<run>/`; `normalize_<tool>` promotes the output to a canonical name and appends a manifest row. The `normalize_` halves are pure file manipulation and are unit-tested offline against fixtures built in temp dirs; the `run_` halves (which hit live infra) are written but executed only later in the reproduction phase.

**Tech Stack:** Bash, `jq`, `sha1sum`, `sed`/`grep`. Tests are plain bash with a tiny assert helper — zero external test dependencies.

## Global Constraints

These apply to EVERY task. Values copied verbatim from `docs/superpowers/specs/2026-06-17-recon-contract-foundation-design.md`.

- Workers are NEVER modified. Adapters wrap them.
- No file writes a literal path — all paths come from `lib/paths.sh` helpers.
- Raw tool output goes to `raw/<tool>/<run>/` (per-app via `raw_dir`) or `att_surface/raw/<tool>/<run>/` (scope-level via `surface_raw`); nothing downstream reads `raw/`.
- Every canonical artifact gets a `manifest.jsonl` row via `manifest_append`.
- Workspaces are keyed on `app_id`, never on host/title. `app_id = sha1("<host>:<port>") | cut -c1-12`, where `<host>` is the DNS hostname of the cluster's representative (best) host — not the IP, not the title.
- `<run>` id format: `date -u +%Y%m%dT%H%M%SZ`. Manifest `ts` format: `date -u +%Y-%m-%dT%H:%M:%SZ`.
- Manifest `path` is RELATIVE to the workspace; manifest `input` is a free-form provenance string.
- Adapters are sourceable: define functions, and only run `main` when executed directly (`[ "${BASH_SOURCE[0]}" = "$0" ]` guard), so tests can source them and call `normalize_` directly.
- `BASE` (engagement root) is read from the environment; never hardcoded.
- Tests run fully offline — no network, no live customer traffic.

---

### Task 1: Test harness (`assert.sh` + `run.sh`)

**Files:**
- Create: `utils/recon/tests/assert.sh`
- Create: `utils/recon/tests/run.sh`
- Create: `utils/recon/tests/test_harness.sh`

**Interfaces:**
- Produces: `assert_eq <expected> <actual> <msg>`, `assert_ne <a> <b> <msg>`, `assert_file_exists <path> <msg>`, `assert_contains <file> <substr> <msg>`, `assert_summary` (exits 1 if any assertion failed). Test files source `assert.sh`, run assertions, then call `assert_summary`. `run.sh` executes every `test_*.sh` in the dir and returns non-zero if any fail.

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_harness.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"

assert_eq "a" "a" "eq matches equal values"
assert_ne "a" "b" "ne matches different values"
tmp="$(mktemp)"; echo "hello world" > "$tmp"
assert_file_exists "$tmp" "file exists after write"
assert_contains "$tmp" "hello" "contains finds substring"
rm -f "$tmp"

assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_harness.sh`
Expected: FAIL — `assert.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation** — `utils/recon/tests/assert.sh`

```bash
# Tiny assertion helper. Source it, run assert_*, then call assert_summary.
ASSERT_FAILED=0

assert_eq() {  # expected actual msg
  if [ "$1" != "$2" ]; then echo "FAIL: $3 (expected '$1', got '$2')"; ASSERT_FAILED=1
  else echo "ok: $3"; fi
}
assert_ne() {  # a b msg
  if [ "$1" = "$2" ]; then echo "FAIL: $3 (both '$1')"; ASSERT_FAILED=1
  else echo "ok: $3"; fi
}
assert_file_exists() {  # path msg
  if [ ! -e "$1" ]; then echo "FAIL: $2 (missing $1)"; ASSERT_FAILED=1
  else echo "ok: $2"; fi
}
assert_contains() {  # file substr msg
  if ! grep -qF "$2" "$1" 2>/dev/null; then echo "FAIL: $3 (no '$2' in $1)"; ASSERT_FAILED=1
  else echo "ok: $3"; fi
}
assert_summary() {
  if [ "$ASSERT_FAILED" -eq 0 ]; then echo "PASS"; else echo "FAILED"; exit 1; fi
}
```

And `utils/recon/tests/run.sh`:

```bash
#!/usr/bin/env bash
# Runs every test_*.sh in this directory; non-zero exit if any fail.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$DIR"/test_*.sh; do
  [ -e "$t" ] || continue
  echo "== $(basename "$t") =="
  bash "$t" || rc=1
done
exit "$rc"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_harness.sh`
Expected: lines of `ok:` then `PASS`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/tests/assert.sh utils/recon/tests/run.sh utils/recon/tests/test_harness.sh
git commit -m "test(recon): add offline bash assert harness"
```

---

### Task 2: `lib/appid.sh` — stable app_id

**Files:**
- Create: `utils/recon/lib/appid.sh`
- Create: `utils/recon/tests/test_appid.sh`

**Interfaces:**
- Produces: `app_id_for <host> <port>` → echoes a 12-char lowercase hex string, deterministic for a given `host:port`.

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_appid.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
source "$DIR/../lib/appid.sh"

a="$(app_id_for example.com 443)"
b="$(app_id_for example.com 443)"
c="$(app_id_for other.com 443)"
d="$(app_id_for example.com 8443)"

assert_eq "$a" "$b" "same host:port is deterministic"
assert_eq "12" "${#a}" "app_id is 12 chars"
assert_ne "$a" "$c" "different host yields different id"
assert_ne "$a" "$d" "different port yields different id"

assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_appid.sh`
Expected: FAIL — `appid.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation** — `utils/recon/lib/appid.sh`

```bash
# Stable workspace key. Hash the DNS hostname + port (NOT the IP, NOT the title).
app_id_for() {  # host port
  printf '%s:%s' "$1" "$2" | sha1sum | cut -c1-12
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_appid.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/lib/appid.sh utils/recon/tests/test_appid.sh
git commit -m "feat(recon): add stable app_id_for hashing host:port"
```

---

### Task 3: `lib/paths.sh` — path single source of truth

**Files:**
- Create: `utils/recon/lib/paths.sh`
- Create: `utils/recon/tests/test_paths.sh`

**Interfaces:**
- Consumes: `$BASE` from environment.
- Produces (all echo a path string):
  - scope-level: `surface_dir`, `subdomains`, `httpx_meta`, `scope_findings`, `surface_raw <tool> <run>`
  - per-app (`$1=app_id`): `app_dir`, `meta_json`, `endpoints`, `subs`, `screenshot`, `takeover`, `raw_dir <app_id> <tool> <run>`, `manifest_path <app_id|_surface>`
  - common: `new_run` (echoes `date -u +%Y%m%dT%H%M%SZ`)

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_paths.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="/tmp/eng"
source "$DIR/../lib/paths.sh"

assert_eq "/tmp/eng/att_surface"                          "$(surface_dir)"            "surface_dir"
assert_eq "/tmp/eng/att_surface/subdomains.txt"           "$(subdomains)"             "subdomains"
assert_eq "/tmp/eng/att_surface/httpx_full_metadata.jsonl" "$(httpx_meta)"            "httpx_meta"
assert_eq "/tmp/eng/att_surface/findings/takeovers_scope.jsonl" "$(scope_findings)"  "scope_findings"
assert_eq "/tmp/eng/att_surface/raw/surfagr/R1"           "$(surface_raw surfagr R1)" "surface_raw"
assert_eq "/tmp/eng/targets/abc"                          "$(app_dir abc)"            "app_dir"
assert_eq "/tmp/eng/targets/abc/meta.json"                "$(meta_json abc)"          "meta_json"
assert_eq "/tmp/eng/targets/abc/endpoints.txt"            "$(endpoints abc)"          "endpoints"
assert_eq "/tmp/eng/targets/abc/subs.txt"                 "$(subs abc)"               "subs"
assert_eq "/tmp/eng/targets/abc/screenshot.png"           "$(screenshot abc)"         "screenshot"
assert_eq "/tmp/eng/targets/abc/findings/takeover.txt"    "$(takeover abc)"           "takeover"
assert_eq "/tmp/eng/targets/abc/raw/katana/R1"            "$(raw_dir abc katana R1)"  "raw_dir"
assert_eq "/tmp/eng/targets/abc/manifest.jsonl"           "$(manifest_path abc)"      "manifest_path app"
assert_eq "/tmp/eng/att_surface/manifest.jsonl"           "$(manifest_path _surface)" "manifest_path surface"
assert_eq "12" "$(printf %s "$(new_run)" | wc -c | tr -d ' ' | sed 's/16/12/')" "new_run runs"

assert_summary
```

Note: the final `new_run` assertion just confirms the function executes without error; the exact value is time-dependent. Replace its assert line with the simpler check below if preferred:

```bash
r="$(new_run)"; assert_ne "" "$r" "new_run is non-empty"
```

Use the simpler `assert_ne "" "$r"` form.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_paths.sh`
Expected: FAIL — `paths.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation** — `utils/recon/lib/paths.sh`

```bash
# Single source of truth for every path in the contract. Requires $BASE.
# scope-level
surface_dir()    { echo "$BASE/att_surface"; }
subdomains()     { echo "$(surface_dir)/subdomains.txt"; }
httpx_meta()     { echo "$(surface_dir)/httpx_full_metadata.jsonl"; }
scope_findings() { echo "$(surface_dir)/findings/takeovers_scope.jsonl"; }
surface_raw()    { echo "$(surface_dir)/raw/$1/$2"; }      # tool run

# per-app ($1 = app_id)
app_dir()        { echo "$BASE/targets/$1"; }
meta_json()      { echo "$(app_dir "$1")/meta.json"; }
endpoints()      { echo "$(app_dir "$1")/endpoints.txt"; }
subs()           { echo "$(app_dir "$1")/subs.txt"; }
screenshot()     { echo "$(app_dir "$1")/screenshot.png"; }
takeover()       { echo "$(app_dir "$1")/findings/takeover.txt"; }
raw_dir()        { echo "$(app_dir "$1")/raw/$2/$3"; }     # app_id tool run

# manifest file selector: real app_id -> per-app manifest; _surface -> surface manifest
manifest_path()  {
  if [ "$1" = "_surface" ]; then echo "$(surface_dir)/manifest.jsonl"
  else echo "$(app_dir "$1")/manifest.jsonl"; fi
}

# common
new_run()        { date -u +%Y%m%dT%H%M%SZ; }
```

Make the test's `new_run` line the simpler `r="$(new_run)"; assert_ne "" "$r" "new_run is non-empty"` before running.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_paths.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/lib/paths.sh utils/recon/tests/test_paths.sh
git commit -m "feat(recon): add lib/paths.sh path single source of truth"
```

---

### Task 4: `lib/manifest.sh` — manifest append

**Files:**
- Create: `utils/recon/lib/manifest.sh`
- Create: `utils/recon/tests/test_manifest.sh`

**Interfaces:**
- Consumes: `manifest_path` and `new_run` from `lib/paths.sh` (source it before this).
- Produces: `manifest_append <app_id|_surface> <role> <rel_path> <tool> <input>` — appends one JSONL row `{"role","path","tool","input","ts"}` to the resolved manifest file, creating its parent directory if absent. `ts` is `date -u +%Y-%m-%dT%H:%M:%SZ`.

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_manifest.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../lib/paths.sh"
source "$DIR/../lib/manifest.sh"

manifest_append abc endpoints endpoints.txt katana "raw/pipeline-recon/R1/"
manifest_append _surface subdomains subdomains.txt subfinder "scope.txt"

app_mf="$(manifest_path abc)"
srf_mf="$(manifest_path _surface)"

assert_file_exists "$app_mf" "per-app manifest created"
assert_file_exists "$srf_mf" "surface manifest created"
assert_contains "$app_mf" '"role":"endpoints"' "endpoints role recorded"
assert_contains "$app_mf" '"path":"endpoints.txt"' "endpoints path recorded"
assert_contains "$srf_mf" '"role":"subdomains"' "subdomains role recorded"
# every line must be valid JSON
if jq -e . "$app_mf" >/dev/null && jq -e . "$srf_mf" >/dev/null; then
  echo "ok: manifest rows are valid JSON"
else
  echo "FAIL: manifest rows are not valid JSON"; ASSERT_FAILED=1
fi
rm -rf "$BASE"
assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_manifest.sh`
Expected: FAIL — `manifest.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation** — `utils/recon/lib/manifest.sh`

```bash
# Append one role->path+provenance row to the workspace manifest.
# Requires lib/paths.sh sourced first (manifest_path).
manifest_append() {  # app_id|_surface  role  rel_path  tool  input
  local mf ts
  mf="$(manifest_path "$1")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$mf")"
  jq -c -n \
    --arg role "$2" --arg path "$3" --arg tool "$4" --arg input "$5" --arg ts "$ts" \
    '{role:$role, path:$path, tool:$tool, input:$input, ts:$ts}' >> "$mf"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_manifest.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/lib/manifest.sh utils/recon/tests/test_manifest.sh
git commit -m "feat(recon): add lib/manifest.sh manifest_append helper"
```

---

### Task 5: `adapters/scope2surface.sh`

**Files:**
- Create: `utils/recon/adapters/scope2surface.sh`
- Create: `utils/recon/tests/test_adapter_scope2surface.sh`

**Interfaces:**
- Consumes: `lib/paths.sh`, `lib/manifest.sh`. Worker `../scope2surface.sh` (writes `<dest>/scans/subdomains.txt` and `<dest>/scans/httpx_full_metadata.jsonl`).
- Produces: `run_scope2surface <scope_file>` (echoes the run id) and `normalize_scope2surface <run>`. Promotes to `att_surface/subdomains.txt` and `att_surface/httpx_full_metadata.jsonl`; manifest roles `subdomains`, `httpx_meta` (selector `_surface`).

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_adapter_scope2surface.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/scope2surface.sh"     # sourced: main guard prevents auto-run

# Build a fixture raw output exactly as the worker would have produced it.
run="20260617T000000Z"
raw="$(surface_raw scope2surface "$run")"
mkdir -p "$raw/scans"
printf 'a.example.com\nb.example.com\n' > "$raw/scans/subdomains.txt"
printf '{"url":"https://a.example.com"}\n'  > "$raw/scans/httpx_full_metadata.jsonl"

normalize_scope2surface "$run"

assert_file_exists "$(subdomains)" "subdomains promoted to canonical"
assert_file_exists "$(httpx_meta)" "httpx_meta promoted to canonical"
assert_contains "$(subdomains)" "a.example.com" "canonical subdomains has content"
assert_contains "$(manifest_path _surface)" '"role":"subdomains"' "subdomains manifest row"
assert_contains "$(manifest_path _surface)" '"role":"httpx_meta"' "httpx_meta manifest row"
rm -rf "$BASE"
assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_adapter_scope2surface.sh`
Expected: FAIL — `scope2surface.sh` (adapter) not found.

- [ ] **Step 3: Write minimal implementation** — `utils/recon/adapters/scope2surface.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_scope2surface() {   # scope_file -> echoes run id
  local run raw; run="$(new_run)"; raw="$(surface_raw scope2surface "$run")"
  mkdir -p "$raw"
  "$WORKER/scope2surface.sh" "$1" "$raw" >&2
  echo "$run"
}

normalize_scope2surface() {   # run id
  local raw; raw="$(surface_raw scope2surface "$1")"
  mkdir -p "$(surface_dir)"
  cp "$raw/scans/subdomains.txt" "$(subdomains)"
  cp "$raw/scans/httpx_full_metadata.jsonl" "$(httpx_meta)"
  manifest_append _surface subdomains          subdomains.txt            scope2surface "raw/scope2surface/$1/scans/subdomains.txt"
  manifest_append _surface httpx_meta          httpx_full_metadata.jsonl scope2surface "raw/scope2surface/$1/scans/httpx_full_metadata.jsonl"
}

main() { local run; run="$(run_scope2surface "$1")"; normalize_scope2surface "$run"; }
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_adapter_scope2surface.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/adapters/scope2surface.sh utils/recon/tests/test_adapter_scope2surface.sh
git commit -m "feat(recon): add scope2surface adapter (raw->canonical+manifest)"
```

---

### Task 6: `adapters/surfagr.sh` — the app_id promoter ⭐

**Files:**
- Create: `utils/recon/adapters/surfagr.sh`
- Create: `utils/recon/tests/test_adapter_surfagr.sh`

**Interfaces:**
- Consumes: `lib/paths.sh`, `lib/manifest.sh`, `lib/appid.sh`. Worker `../surfagr.sh` (produces `<dest>/targets/<host>_<title>/{hosts.txt,info.txt}`; `hosts.txt` = sorted unique URLs; `info.txt` lines `Title: …`, `IP: …`, `Webserver: …`, `Tech Stack: …`, `Content-Length: …`, `Status-Code: …`).
- Produces: `run_surfagr` (echoes run id) and `normalize_surfagr <run>`. For each raw cluster dir, computes `app_id` from the representative host and writes `targets/<app_id>/meta.json`; manifest role `meta`.
- **meta.json shape** (consumed by Tasks 7, 8, 9): `{app_id, host, port, base_url, title, host_ip, webserver, status_code, tech:[…], cluster_hosts:[…]}`. Consumers read `.app_id` and `.cluster_hosts[]`.
- **Known coupling (do NOT fix here):** `surfagr.sh` calls `run-screenshotter.sh` internally (line ~121). `run_surfagr` therefore triggers a screenshot pass as a side effect. This is left as-is; the separate `screenshotter` adapter is the canonical screenshot producer, and the reproduction phase decides how to handle the redundancy. The contract phase tests only `normalize_surfagr`, so this side effect is never exercised by tests.

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_adapter_surfagr.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../lib/appid.sh"                 # for computing expected app_id in the test
source "$DIR/../adapters/surfagr.sh"

run="20260617T000000Z"
raw="$(surface_raw surfagr "$run")"

# Cluster 1: domain host on default https port
mkdir -p "$raw/targets/login.example.com_acme_login"
printf 'https://login.example.com/\nhttps://10.0.0.5/\n' > "$raw/targets/login.example.com_acme_login/hosts.txt"
printf 'Title: ACME Login\nIP: 10.0.0.5\nWebserver: nginx\nTech Stack: React, Nginx\nContent-Length: 1234\nStatus-Code: 200\n' \
  > "$raw/targets/login.example.com_acme_login/info.txt"

# Cluster 2: explicit port
mkdir -p "$raw/targets/api.example.com_8443_api"
printf 'https://api.example.com:8443/\n' > "$raw/targets/api.example.com_8443_api/hosts.txt"
printf 'Title: API\nIP: 10.0.0.6\nWebserver: envoy\nTech Stack: None detected\nContent-Length: 0\nStatus-Code: 404\n' \
  > "$raw/targets/api.example.com_8443_api/info.txt"

normalize_surfagr "$run"

id1="$(app_id_for login.example.com 443)"
id2="$(app_id_for api.example.com 8443)"

assert_file_exists "$(meta_json "$id1")" "cluster 1 meta.json created at app_id dir"
assert_file_exists "$(meta_json "$id2")" "cluster 2 meta.json created at app_id dir"
assert_eq "login.example.com" "$(jq -r .host "$(meta_json "$id1")")" "cluster 1 host parsed (domain over IP)"
assert_eq "443"               "$(jq -r .port "$(meta_json "$id1")")" "cluster 1 default port"
assert_eq "8443"              "$(jq -r .port "$(meta_json "$id2")")" "cluster 2 explicit port"
assert_eq "2"                 "$(jq '.cluster_hosts | length' "$(meta_json "$id1")")" "cluster 1 keeps all hosts"
assert_eq "2"                 "$(jq '.tech | length' "$(meta_json "$id1")")" "cluster 1 tech split into array"
assert_eq "0"                 "$(jq '.tech | length' "$(meta_json "$id2")")" "cluster 2 'None detected' -> empty array"
assert_contains "$(manifest_path "$id1")" '"role":"meta"' "cluster 1 meta manifest row"
rm -rf "$BASE"
assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_adapter_surfagr.sh`
Expected: FAIL — adapter not found.

- [ ] **Step 3: Write minimal implementation** — `utils/recon/adapters/surfagr.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"; source "$LIB/appid.sh"

run_surfagr() {   # echoes run id
  # NOTE: surfagr.sh also invokes run-screenshotter.sh internally (known coupling).
  local run raw; run="$(new_run)"; raw="$(surface_raw surfagr "$run")"
  mkdir -p "$raw"
  "$WORKER/surfagr.sh" "$(httpx_meta)" "$raw" >&2
  echo "$run"
}

# Pure-bash parse of "scheme://host[:port]/..." -> sets REPL_HOST, REPL_PORT
_parse_authority() {  # url
  local url="$1" scheme authority
  scheme="${url%%://*}"
  authority="${url#*://}"; authority="${authority%%/*}"
  REPL_HOST="${authority%%:*}"
  if [ "$authority" != "$REPL_HOST" ]; then REPL_PORT="${authority##*:}"
  elif [ "$scheme" = "https" ]; then REPL_PORT=443
  else REPL_PORT=80; fi
}

normalize_surfagr() {   # run id  -- fan-out promoter, enforces stable app_id (§5)
  local run raw d hosts best title ip ws status tech_csv tech_json hosts_json app_id
  run="$1"; raw="$(surface_raw surfagr "$run")"
  for d in "$raw"/targets/*/; do
    [ -d "$d" ] || continue
    hosts="${d%/}/hosts.txt"
    # representative host: first non-IP URL, else first URL (mirrors pipeline-recon BEST_HOST)
    best="$(grep -vE '^https?://([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?(/|$)' "$hosts" | head -n1)"
    [ -n "$best" ] || best="$(head -n1 "$hosts")"
    _parse_authority "$best"
    app_id="$(app_id_for "$REPL_HOST" "$REPL_PORT")"
    title="$(sed -n 's/^Title: //p' "${d%/}/info.txt" | head -n1)"
    ip="$(sed -n 's/^IP: //p' "${d%/}/info.txt" | head -n1)"
    ws="$(sed -n 's/^Webserver: //p' "${d%/}/info.txt" | head -n1)"
    status="$(sed -n 's/^Status-Code: //p' "${d%/}/info.txt" | head -n1)"
    tech_csv="$(sed -n 's/^Tech Stack: //p' "${d%/}/info.txt" | head -n1)"
    tech_json="$(printf '%s' "$tech_csv" | jq -R 'if . == "None detected" or . == "" then [] else split(", ") end')"
    hosts_json="$(jq -R . < "$hosts" | jq -s .)"
    mkdir -p "$(app_dir "$app_id")"
    jq -n \
      --arg app_id "$app_id" --arg host "$REPL_HOST" --arg port "$REPL_PORT" \
      --arg base_url "$best" --arg title "$title" --arg ip "$ip" \
      --arg webserver "$ws" --arg status "$status" \
      --argjson tech "$tech_json" --argjson cluster_hosts "$hosts_json" \
      '{app_id:$app_id, host:$host, port:$port, base_url:$base_url, title:$title,
        host_ip:$ip, webserver:$webserver, status_code:$status,
        tech:$tech, cluster_hosts:$cluster_hosts}' > "$(meta_json "$app_id")"
    manifest_append "$app_id" meta meta.json surfagr "att_surface/raw/surfagr/$run/targets/$(basename "${d%/}")/"
  done
}

main() { local run; run="$(run_surfagr)"; normalize_surfagr "$run"; }
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_adapter_surfagr.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/adapters/surfagr.sh utils/recon/tests/test_adapter_surfagr.sh
git commit -m "feat(recon): add surfagr adapter promoting clusters to app_id workspaces"
```

---

### Task 7: `adapters/screenshotter.sh`

**Files:**
- Create: `utils/recon/adapters/screenshotter.sh`
- Create: `utils/recon/tests/test_adapter_screenshotter.sh`

**Interfaces:**
- Consumes: `lib/paths.sh`, `lib/manifest.sh`; `meta.json` (`.app_id`, `.cluster_hosts[]`) from Task 6. Worker `../run-screenshotter.sh <surface_dir>` (writes `<surface_dir>/<sub>/screenshot.png` or `screenshot.failed` per subdir that holds a `hosts.txt`).
- Produces: `run_screenshotter` (builds a staging dir with one subdir per `app_id` holding `hosts.txt`, runs ONE batch pass; echoes run id) and `normalize_screenshotter <run>`. Promotes each `screenshot.png`/`.failed` to `targets/<app_id>/`; manifest role `screenshot`.

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_adapter_screenshotter.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/screenshotter.sh"

app_id="abc123def456"
mkdir -p "$(app_dir "$app_id")"
run="20260617T000000Z"
staging="$(surface_raw screenshotter "$run")"
mkdir -p "$staging/$app_id"
printf 'PNGDATA' > "$staging/$app_id/screenshot.png"

normalize_screenshotter "$run"

assert_file_exists "$(screenshot "$app_id")" "screenshot promoted to app workspace"
assert_contains "$(manifest_path "$app_id")" '"role":"screenshot"' "screenshot manifest row"
rm -rf "$BASE"
assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_adapter_screenshotter.sh`
Expected: FAIL — adapter not found.

- [ ] **Step 3: Write minimal implementation** — `utils/recon/adapters/screenshotter.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_screenshotter() {   # echoes run id
  local run staging m app_id; run="$(new_run)"; staging="$(surface_raw screenshotter "$run")"
  mkdir -p "$staging"
  for m in "$BASE"/targets/*/meta.json; do
    [ -e "$m" ] || continue
    app_id="$(jq -r .app_id "$m")"
    mkdir -p "$staging/$app_id"
    jq -r '.cluster_hosts[]' "$m" > "$staging/$app_id/hosts.txt"
  done
  "$WORKER/run-screenshotter.sh" "$staging" >&2 || true   # ONE batch httpx -screenshot pass
  echo "$run"
}

normalize_screenshotter() {   # run id
  local run staging d app_id; run="$1"; staging="$(surface_raw screenshotter "$run")"
  for d in "$staging"/*/; do
    [ -d "$d" ] || continue
    app_id="$(basename "${d%/}")"
    [ -d "$(app_dir "$app_id")" ] || continue
    if [ -f "${d%/}/screenshot.png" ]; then
      cp "${d%/}/screenshot.png" "$(screenshot "$app_id")"
      manifest_append "$app_id" screenshot screenshot.png run-screenshotter "att_surface/raw/screenshotter/$run/$app_id/"
    elif [ -f "${d%/}/screenshot.failed" ]; then
      cp "${d%/}/screenshot.failed" "$(app_dir "$app_id")/screenshot.failed"
      manifest_append "$app_id" screenshot screenshot.failed run-screenshotter "att_surface/raw/screenshotter/$run/$app_id/"
    fi
  done
}

main() { local run; run="$(run_screenshotter)"; normalize_screenshotter "$run"; }
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_adapter_screenshotter.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/adapters/screenshotter.sh utils/recon/tests/test_adapter_screenshotter.sh
git commit -m "feat(recon): add screenshotter adapter (batch pass -> per-app canonical)"
```

---

### Task 8: `adapters/pipeline-recon.sh`

**Files:**
- Create: `utils/recon/adapters/pipeline-recon.sh`
- Create: `utils/recon/tests/test_adapter_pipeline_recon.sh`

**Interfaces:**
- Consumes: `lib/paths.sh`, `lib/manifest.sh`; `meta.json` (`.cluster_hosts[]`). Worker `../pipeline-recon.sh <app_dir>` (reads `<app_dir>/hosts.txt`; writes `<app_dir>/all_endpoints_clean.txt`, and `<app_dir>/js/`, `<app_dir>/html/`).
- Produces: `run_pipeline_recon <app_id>` (stages `hosts.txt` from meta, runs worker; echoes run id) and `normalize_pipeline_recon <app_id> <run>`. Promotes `all_endpoints_clean.txt`→`endpoints.txt`, `js/`→`js/`, `html/`→`html/`; manifest roles `endpoints`, `js_assets`, `html_assets`.

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_adapter_pipeline_recon.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/pipeline-recon.sh"

app_id="abc123def456"
mkdir -p "$(app_dir "$app_id")"
run="20260617T000000Z"
raw="$(raw_dir "$app_id" pipeline-recon "$run")"
mkdir -p "$raw/js" "$raw/html"
printf 'https://login.example.com/dashboard\n' > "$raw/all_endpoints_clean.txt"
printf 'console.log(1)\n' > "$raw/js/app.js"
printf '<html></html>\n'  > "$raw/html/index.html"

normalize_pipeline_recon "$app_id" "$run"

assert_file_exists "$(endpoints "$app_id")" "endpoints promoted"
assert_contains "$(endpoints "$app_id")" "dashboard" "endpoints content present"
assert_file_exists "$(app_dir "$app_id")/js/app.js" "js dir promoted"
assert_file_exists "$(app_dir "$app_id")/html/index.html" "html dir promoted"
assert_contains "$(manifest_path "$app_id")" '"role":"endpoints"' "endpoints manifest row"
assert_contains "$(manifest_path "$app_id")" '"role":"js_assets"' "js manifest row"
assert_contains "$(manifest_path "$app_id")" '"role":"html_assets"' "html manifest row"
rm -rf "$BASE"
assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_adapter_pipeline_recon.sh`
Expected: FAIL — adapter not found.

- [ ] **Step 3: Write minimal implementation** — `utils/recon/adapters/pipeline-recon.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_pipeline_recon() {   # app_id -> echoes run id
  local app_id run raw; app_id="$1"; run="$(new_run)"; raw="$(raw_dir "$app_id" pipeline-recon "$run")"
  mkdir -p "$raw"
  jq -r '.cluster_hosts[]' "$(meta_json "$app_id")" > "$raw/hosts.txt"
  "$WORKER/pipeline-recon.sh" "$raw" >&2
  echo "$run"
}

normalize_pipeline_recon() {   # app_id run
  local app_id run raw; app_id="$1"; run="$2"; raw="$(raw_dir "$app_id" pipeline-recon "$run")"
  cp "$raw/all_endpoints_clean.txt" "$(endpoints "$app_id")"
  manifest_append "$app_id" endpoints endpoints.txt "katana+gau+urlfinder" "raw/pipeline-recon/$run/all_endpoints_clean.txt"
  if [ -d "$raw/js" ]; then
    cp -r "$raw/js" "$(app_dir "$app_id")/js"
    manifest_append "$app_id" js_assets js run-downloader "raw/pipeline-recon/$run/js/"
  fi
  if [ -d "$raw/html" ]; then
    cp -r "$raw/html" "$(app_dir "$app_id")/html"
    manifest_append "$app_id" html_assets html run-downloader "raw/pipeline-recon/$run/html/"
  fi
}

main() { local run; run="$(run_pipeline_recon "$1")"; normalize_pipeline_recon "$1" "$run"; }
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_adapter_pipeline_recon.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/adapters/pipeline-recon.sh utils/recon/tests/test_adapter_pipeline_recon.sh
git commit -m "feat(recon): add pipeline-recon adapter (endpoints/js/html canonical)"
```

---

### Task 9: `adapters/pipeline-subenum.sh`

**Files:**
- Create: `utils/recon/adapters/pipeline-subenum.sh`
- Create: `utils/recon/tests/test_adapter_pipeline_subenum.sh`

**Interfaces:**
- Consumes: `lib/paths.sh`, `lib/manifest.sh`; `meta.json` (`.cluster_hosts[]`). Worker `../pipeline-subenum.sh <app_dir>` (reads `<app_dir>/hosts.txt`; writes `<app_dir>/discovered_subs.txt`).
- Produces: `run_pipeline_subenum <app_id>` (echoes run id) and `normalize_pipeline_subenum <app_id> <run>`. Promotes `discovered_subs.txt`→`subs.txt`; manifest role `subs`.

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_adapter_pipeline_subenum.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/pipeline-subenum.sh"

app_id="abc123def456"
mkdir -p "$(app_dir "$app_id")"
run="20260617T000000Z"
raw="$(raw_dir "$app_id" pipeline-subenum "$run")"
mkdir -p "$raw"
printf 'dev.example.com\nstaging.example.com\n' > "$raw/discovered_subs.txt"

normalize_pipeline_subenum "$app_id" "$run"

assert_file_exists "$(subs "$app_id")" "subs promoted to canonical"
assert_contains "$(subs "$app_id")" "dev.example.com" "subs content present"
assert_contains "$(manifest_path "$app_id")" '"role":"subs"' "subs manifest row"
rm -rf "$BASE"
assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_adapter_pipeline_subenum.sh`
Expected: FAIL — adapter not found.

- [ ] **Step 3: Write minimal implementation** — `utils/recon/adapters/pipeline-subenum.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_pipeline_subenum() {   # app_id -> echoes run id
  local app_id run raw; app_id="$1"; run="$(new_run)"; raw="$(raw_dir "$app_id" pipeline-subenum "$run")"
  mkdir -p "$raw"
  jq -r '.cluster_hosts[]' "$(meta_json "$app_id")" > "$raw/hosts.txt"
  "$WORKER/pipeline-subenum.sh" "$raw" >&2
  echo "$run"
}

normalize_pipeline_subenum() {   # app_id run
  local app_id run raw; app_id="$1"; run="$2"; raw="$(raw_dir "$app_id" pipeline-subenum "$run")"
  cp "$raw/discovered_subs.txt" "$(subs "$app_id")"
  manifest_append "$app_id" subs subs.txt subfinder "raw/pipeline-subenum/$run/discovered_subs.txt"
}

main() { local run; run="$(run_pipeline_subenum "$1")"; normalize_pipeline_subenum "$1" "$run"; }
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_adapter_pipeline_subenum.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/adapters/pipeline-subenum.sh utils/recon/tests/test_adapter_pipeline_subenum.sh
git commit -m "feat(recon): add pipeline-subenum adapter (discovered_subs->subs canonical)"
```

---

### Task 10: `adapters/takeover-scope.sh`

**Files:**
- Create: `utils/recon/adapters/takeover-scope.sh`
- Create: `utils/recon/tests/test_adapter_takeover_scope.sh`

**Interfaces:**
- Consumes: `lib/paths.sh`, `lib/manifest.sh`; canonical `subdomains` (from Task 5). Worker `../run-takeover-scope.sh <subs_file> <output_jsonl>` (writes nuclei findings, possibly empty/absent).
- Produces: `run_takeover_scope` (echoes run id) and `normalize_takeover_scope <run>`. Promotes findings to `att_surface/findings/takeovers_scope.jsonl` (creating an empty file if the worker produced none); manifest role `takeovers_scope` (selector `_surface`).

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_adapter_takeover_scope.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/takeover-scope.sh"

run="20260617T000000Z"
raw="$(surface_raw takeover-scope "$run")"
mkdir -p "$raw"
printf '{"template-id":"takeover"}\n' > "$raw/takeovers.jsonl"

normalize_takeover_scope "$run"
assert_file_exists "$(scope_findings)" "scope findings promoted"
assert_contains "$(manifest_path _surface)" '"role":"takeovers_scope"' "takeovers_scope manifest row"

# absent findings -> canonical still created (empty)
run2="20260617T000001Z"
mkdir -p "$(surface_raw takeover-scope "$run2")"   # no takeovers.jsonl produced
normalize_takeover_scope "$run2"
assert_file_exists "$(scope_findings)" "scope findings exists even when worker produced none"
rm -rf "$BASE"
assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_adapter_takeover_scope.sh`
Expected: FAIL — adapter not found.

- [ ] **Step 3: Write minimal implementation** — `utils/recon/adapters/takeover-scope.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_takeover_scope() {   # echoes run id
  local run raw; run="$(new_run)"; raw="$(surface_raw takeover-scope "$run")"
  mkdir -p "$raw"
  "$WORKER/run-takeover-scope.sh" "$(subdomains)" "$raw/takeovers.jsonl" >&2 || true
  echo "$run"
}

normalize_takeover_scope() {   # run id
  local raw; raw="$(surface_raw takeover-scope "$1")"
  mkdir -p "$(surface_dir)/findings"
  [ -f "$raw/takeovers.jsonl" ] || : > "$raw/takeovers.jsonl"
  cp "$raw/takeovers.jsonl" "$(scope_findings)"
  manifest_append _surface takeovers_scope findings/takeovers_scope.jsonl nuclei "raw/takeover-scope/$1/takeovers.jsonl"
}

main() { local run; run="$(run_takeover_scope)"; normalize_takeover_scope "$run"; }
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_adapter_takeover_scope.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/adapters/takeover-scope.sh utils/recon/tests/test_adapter_takeover_scope.sh
git commit -m "feat(recon): add takeover-scope adapter (stage-1 findings canonical)"
```

---

### Task 11: `adapters/takeover-discovered.sh`

**Files:**
- Create: `utils/recon/adapters/takeover-discovered.sh`
- Create: `utils/recon/tests/test_adapter_takeover_discovered.sh`

**Interfaces:**
- Consumes: `lib/paths.sh`, `lib/manifest.sh`; canonical `endpoints` (Task 8) and `subs` (Task 9). Worker `../run-takeover-discovered.sh <app_dir>` (reads `<app_dir>/all_endpoints_clean.txt` and optional `<app_dir>/discovered_subs.txt`; writes `<app_dir>/takeover.txt`).
- Produces: `run_takeover_discovered <app_id>` (stages `all_endpoints_clean.txt` from `endpoints` and `discovered_subs.txt` from `subs`; echoes run id) and `normalize_takeover_discovered <app_id> <run>`. Promotes `takeover.txt`→`findings/takeover.txt`; manifest role `takeover`. Output kept unfiltered (subjack `[Not Vulnerable]` noise filtered at triage, not here).

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_adapter_takeover_discovered.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../adapters/takeover-discovered.sh"

app_id="abc123def456"
mkdir -p "$(app_dir "$app_id")"
run="20260617T000000Z"
raw="$(raw_dir "$app_id" takeover-discovered "$run")"
mkdir -p "$raw"
printf '[Not Vulnerable] https://login.example.com\n' > "$raw/takeover.txt"

normalize_takeover_discovered "$app_id" "$run"

assert_file_exists "$(takeover "$app_id")" "takeover promoted to findings/"
assert_contains "$(takeover "$app_id")" "Not Vulnerable" "output kept unfiltered"
assert_contains "$(manifest_path "$app_id")" '"role":"takeover"' "takeover manifest row"
rm -rf "$BASE"
assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_adapter_takeover_discovered.sh`
Expected: FAIL — adapter not found.

- [ ] **Step 3: Write minimal implementation** — `utils/recon/adapters/takeover-discovered.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"

run_takeover_discovered() {   # app_id -> echoes run id
  local app_id run raw; app_id="$1"; run="$(new_run)"; raw="$(raw_dir "$app_id" takeover-discovered "$run")"
  mkdir -p "$raw"
  cp "$(endpoints "$app_id")" "$raw/all_endpoints_clean.txt"
  if [ -f "$(subs "$app_id")" ]; then cp "$(subs "$app_id")" "$raw/discovered_subs.txt"; else : > "$raw/discovered_subs.txt"; fi
  "$WORKER/run-takeover-discovered.sh" "$raw" >&2
  echo "$run"
}

normalize_takeover_discovered() {   # app_id run
  local app_id run raw; app_id="$1"; run="$2"; raw="$(raw_dir "$app_id" takeover-discovered "$run")"
  mkdir -p "$(app_dir "$app_id")/findings"
  cp "$raw/takeover.txt" "$(takeover "$app_id")"
  manifest_append "$app_id" takeover findings/takeover.txt subjack "raw/takeover-discovered/$run/takeover.txt"
}

main() { local run; run="$(run_takeover_discovered "$1")"; normalize_takeover_discovered "$1" "$run"; }
[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_adapter_takeover_discovered.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/adapters/takeover-discovered.sh utils/recon/tests/test_adapter_takeover_discovered.sh
git commit -m "feat(recon): add takeover-discovered adapter (stage-2 findings canonical)"
```

---

### Task 12: Full suite green + documentation

**Files:**
- Create: `utils/recon/adapters/README.md`
- Modify: `CONVENTIONS.md` (the "Current state (honest gap)" section, lines ~88-93)

**Interfaces:**
- Consumes: every test from Tasks 1-11 (via `tests/run.sh`).
- Produces: documentation only. No code interfaces.

- [ ] **Step 1: Run the full suite**

Run: `bash utils/recon/tests/run.sh; echo "exit=$?"`
Expected: each `test_*.sh` prints `PASS`; final line `exit=0`.

- [ ] **Step 2: Write the adapter layer README** — `utils/recon/adapters/README.md`

````markdown
# Contract adapter layer

Thin adapters that wrap the unchanged worker scripts in `../` and make them honor the
workspace/output contract in [`CONVENTIONS.md`](../../../CONVENTIONS.md). The path single
source of truth lives in [`../lib/paths.sh`](../lib/paths.sh); `app_id` in
[`../lib/appid.sh`](../lib/appid.sh); manifest provenance in
[`../lib/manifest.sh`](../lib/manifest.sh).

The two future reproductions (Taskfile-only, Dagu-only) MUST source `lib/paths.sh` for
every path rather than re-declaring literals — that is what keeps a single source of truth
across both orchestrators.

## Each adapter has two halves

- `run_<tool>`      — materializes the inputs the legacy worker expects, runs it into
                      `raw/<tool>/<run>/`, echoes the run id. (Hits live infra.)
- `normalize_<tool>` — promotes the raw output to its canonical name and appends a
                      `manifest.jsonl` row. (Pure file manipulation; unit-tested offline.)

Adapters are sourceable: they only run `main` when executed directly, so tests source them
and call `normalize_` against fixtures.

## Invocation order (what the reproductions will wire up)

```
scope2surface        -> att_surface/{subdomains.txt, httpx_full_metadata.jsonl}
surfagr   (promoter) -> targets/<app_id>/meta.json            # enforces stable app_id
screenshotter        -> targets/<app_id>/screenshot.png
takeover-scope       -> att_surface/findings/takeovers_scope.jsonl   # stage 1 (parallel)
per app_id:
  pipeline-recon     -> targets/<app_id>/{endpoints.txt, js/, html/}
  pipeline-subenum   -> targets/<app_id>/subs.txt
  takeover-discovered-> targets/<app_id>/findings/takeover.txt        # stage 2
```

## Required env

- `BASE` — engagement root (e.g. `/scans/<scan_id>`). All paths derive from it.

## Known coupling

`../surfagr.sh` invokes `../run-screenshotter.sh` internally, so `run_surfagr` triggers a
screenshot pass as a side effect. The `screenshotter` adapter is the canonical screenshot
producer; the reproduction phase decides how to handle the redundancy.

## Tests

```bash
bash ../tests/run.sh
```
Offline only — no network, no live customer traffic.
````

- [ ] **Step 3: Update the CONVENTIONS "Current state" note** — `CONVENTIONS.md`

Replace the "## Current state (honest gap)" paragraph with:

```markdown
## Current state

A contract-compliant foundation now exists under `utils/recon/lib/` (path/app_id/manifest
single sources of truth) and `utils/recon/adapters/` (one thin adapter per worker that
splits `run_`/`normalize_`, promotes raw output to canonical names, and appends a manifest
row). See `utils/recon/adapters/README.md`.

The legacy workers themselves are unchanged and still write tool-named files; the adapters
are the seam that makes the contract real. The live orchestration (`recon-orchestrator.sh`)
has NOT yet been re-wired onto the adapters — that lands with the Taskfile-only and
Dagu-only reproductions, each of which sources `lib/paths.sh` for paths. Until then, drive
the contract layer through the adapters directly.
```

- [ ] **Step 4: Commit**

```bash
git add utils/recon/adapters/README.md CONVENTIONS.md
git commit -m "docs(recon): document contract adapter layer; update CONVENTIONS current state"
```

---

## Self-Review

**1. Spec coverage:**
- §3 workspace schema → Tasks 3 (paths), 5/6 (scope + app dirs created). ✓
- §4 code layout → Tasks 1-12 create exactly that tree. ✓
- §5 paths.sh → Task 3. ✓
- §6 appid.sh → Task 2. ✓
- §7 manifest.sh + `_surface` selector → Tasks 3 (manifest_path) + 4. ✓
- §8 adapter pattern (run_/normalize_ split, sourceable guard) → Tasks 5-11. ✓
- §8.1 adapter→canonical map (all 7 adapters) → Tasks 5,6,7,8,9,10,11. ✓
- §8.2 surfagr promoter (app_id, meta.json) → Task 6. ✓
- §8.3 subjack noise kept unfiltered → Task 11 (asserted). ✓
- §9 offline fixture tests, app_id determinism, surfagr promoter test → Tasks 2,5-11. ✓
- §10 orchestrator left as-is; validation via fixture tests → no orchestrator task; Task 12 documents the gap. ✓
- §11 out of scope (reproductions, re-decomposing pipeline-recon) → respected (pipeline-recon wrapped whole in Task 8). ✓
- §12 knobs (12-char hash, relative path, att_surface, surface_raw helper) → Tasks 2,3,4. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". Every code step shows complete code. ✓

**3. Type consistency:**
- `app_id_for <host> <port>` — defined Task 2, used Task 6. ✓
- path helpers — defined Task 3, used everywhere with matching names (`endpoints`, `subs`, `screenshot`, `takeover`, `meta_json`, `surface_raw`, `raw_dir`, `manifest_path`, `scope_findings`, `subdomains`, `httpx_meta`). ✓
- `manifest_append <app_id|_surface> <role> <rel_path> <tool> <input>` — defined Task 4, used Tasks 5-11 with 5 args throughout. ✓
- `normalize_*`/`run_*` signatures — each adapter's Interfaces block matches its `main` and its test's call. ✓
- meta.json shape (`.app_id`, `.cluster_hosts[]`) — produced Task 6, consumed Tasks 7,8,9 via `jq -r '.cluster_hosts[]'` / `jq -r .app_id`. ✓
