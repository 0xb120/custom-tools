# Recon Dagu Reproduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reproduce the recon pipeline orchestration as a Dagu DAG that drives the existing contract adapters, validated by an offline smoke test with stub adapters.

**Architecture:** A parent DAG (`recon.yaml`) runs scope2surface → {takeover-scope (parallel) ∥ surfagr → screenshotter ∥ (enumerate → per-app fan-out)} → done. The per-app step uses Dagu's dynamic `parallel` to call a child DAG (`app.yaml`) once per discovered `app_id` (recon ∥ subenum → takeover). Dagu knows only `BASE`/`ADAPTER_DIR`/`LIB_DIR`; every artifact path resolves inside the adapters via `lib/paths.sh`. The smoke test runs the real DAG with `ADAPTER_DIR` pointed at stub adapters that write canonical fixtures via the real `lib/`, so orchestration is validated without live tools or network.

**Tech Stack:** Dagu (YAML DAG runner, Go binary), Bash, `jq`. Tests are plain bash + the existing `utils/recon/tests/` assert harness; the DAG smoke tests additionally require the Dagu binary.

## Global Constraints

Copied from `docs/superpowers/specs/2026-06-18-recon-dagu-reproduction-design.md`. Apply to every task.

- Build on the contract foundation; do NOT modify any adapter or worker. The ONLY foundation change is the additive `app_ids`/`app_ids_json` helpers in `lib/paths.sh`.
- Dagu writes NO artifact path literal. It receives only `BASE`, `ADAPTER_DIR`, `LIB_DIR` (and `SCOPE`); all artifact paths resolve inside adapters/stubs via `lib/paths.sh`. The only structural knowledge Dagu uses is the app_id list, obtained from `app_ids_json` (the single source of truth), never a guessed glob.
- `ADAPTER_DIR` is a DAG parameter (default the real `utils/recon/adapters`); the smoke test sets it to the stub dir. Same DAG, swapped leaves.
- `LIB_DIR` is a DAG parameter (default `utils/recon/lib`); used by the `enumerate` step to find `paths.sh` independently of `ADAPTER_DIR`.
- Concurrency: per-app fan-out `max_concurrent: 3` (= legacy `xargs -P 3`). Retries disabled. `takeover-scope` continues on failure.
- Stub adapters use the REAL `lib/paths.sh` + `lib/manifest.sh` (+ `lib/appid.sh` for surfagr); only tool execution is faked. Each stub asserts its canonical INPUT exists before writing its output, so the smoke test validates dependency ordering, not just file existence.
- Offline only — no network, no live customer traffic, in any test.
- Exact Dagu YAML field tokens (command field, child-DAG invocation, parallel block keys, param passing, `dagu start` invocation) are pinned in Task 1's `SYNTAX.md` and used consistently in Tasks 4-5. If the YAML shown below differs from what Task 1 confirms, the confirmed tokens win — adjust the YAML and let the smoke test drive it to green.

---

### Task 1: Install Dagu + pin YAML syntax

**Files:**
- Create: `utils/recon/orchestration/dagu/SYNTAX.md`

**Interfaces:**
- Produces: a committed `SYNTAX.md` recording the confirmed tokens later tasks rely on: `COMMAND_FIELD` (`command` or `run`), `SUBDAG_INVOKE` (how a step calls a child DAG + how the child file is referenced), `PARALLEL_KEYS` (`items` + `maxConcurrent` vs `max_concurrent`), `ITEM_VAR` (how the current item is referenced, e.g. `${ITEM}`), `PARAM_PASS` (how params reach a child DAG), `START_CMD` (how to run a DAG with params), `STATUS_CMD` (how to inspect a finished run). Plus a working `dagu` binary on PATH.

- [ ] **Step 1: Install Dagu**

Try the official installer first; fall back to `go install`:
```bash
curl -sSL https://raw.githubusercontent.com/dagu-org/dagu/main/scripts/installer.sh | bash -s -- --version latest || go install github.com/dagu-org/dagu/cmd/dagu@latest
command -v dagu && dagu version
```
Expected: prints a version string. If neither method works (no network / no Go), report BLOCKED with the error — do not fake it.

- [ ] **Step 2: Author a throwaway probe DAG to confirm syntax**

Create `/tmp/dagu-probe-parent.yaml` and `/tmp/dagu-probe-child.yaml` exercising every construct this plan needs: a DAG-level param, a step running a shell command, a step capturing stdout into an output variable, a step that emits a JSON array, and a `parallel` step that calls the child DAG once per array item passing the item as a param. Run it:
```bash
dagu start /tmp/dagu-probe-parent.yaml -- GREETING=hi
```
Iterate the probe YAML until it runs green, trying the candidate tokens (`command:`/`run:`; child invoke via `run: <name>` / `call:` / `run: ./child.yaml`; `maxConcurrent`/`max_concurrent`; `${ITEM}`). The point is to discover the spellings the installed binary actually accepts.

- [ ] **Step 3: Record confirmed syntax** — `utils/recon/orchestration/dagu/SYNTAX.md`

Write a short doc with the confirmed answer for each token, each shown in a minimal YAML snippet that you verified runs:
```markdown
# Dagu syntax confirmed against `dagu <version>`
- COMMAND_FIELD: <command|run> — <1-line snippet>
- SUBDAG_INVOKE: <how a step calls a child DAG; how the child file is located> — <snippet>
- PARALLEL_KEYS: items + <maxConcurrent|max_concurrent> — <snippet>
- ITEM_VAR: <e.g. ${ITEM}>
- PARAM_PASS: <how params reach the child; how to pass multiple> — <snippet>
- START_CMD: dagu start <file> <param syntax>
- STATUS_CMD: <command to print a finished run's per-step status>
```

- [ ] **Step 4: Commit**

```bash
git add utils/recon/orchestration/dagu/SYNTAX.md
git commit -m "build(recon): install Dagu and pin DAG YAML syntax"
```

---

### Task 2: `app_ids` enumeration in `lib/paths.sh`

**Files:**
- Modify: `utils/recon/lib/paths.sh` (append two functions)
- Create: `utils/recon/tests/test_app_ids.sh`

**Interfaces:**
- Consumes: `$BASE`, `app_dir` (existing).
- Produces: `app_ids` (echoes one app_id per line — the basename of each `targets/<app_id>/` dir; nothing if none) and `app_ids_json` (echoes a compact JSON array of the app_ids, e.g. `["a","b"]`, or `[]`).

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/test_app_ids.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../lib/paths.sh"

# no targets yet
assert_eq "[]" "$(app_ids_json)" "app_ids_json is [] when no workspaces"

mkdir -p "$BASE/targets/aaa111" "$BASE/targets/bbb222"
# a stray file (not a dir) must be ignored
: > "$BASE/targets/not_a_dir"

assert_eq "2" "$(app_ids | wc -l | tr -d ' ')" "app_ids lists one per workspace dir"
assert_contains <(app_ids) "aaa111" "app_ids includes aaa111"
# app_ids_json is a valid JSON array of length 2
assert_eq "2" "$(app_ids_json | jq 'length')" "app_ids_json has length 2"
assert_eq "aaa111" "$(app_ids_json | jq -r '.[0]')" "app_ids_json sorted/first element"
rm -rf "$BASE"
assert_summary
```

Note: `assert_contains` takes a file path; `<(app_ids)` is a process substitution providing one. If the harness's `assert_contains` cannot read a process substitution in this context, replace that line with: `app_ids | grep -q '^aaa111$' && echo "ok: app_ids includes aaa111" || { echo "FAIL: aaa111 missing"; ASSERT_FAILED=1; }`.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/test_app_ids.sh`
Expected: FAIL — `app_ids_json: command not found`.

- [ ] **Step 3: Append the implementation** — end of `utils/recon/lib/paths.sh`

```bash

# workspace enumeration — single source of truth for "which app_ids exist"
app_ids()      { for d in "$BASE"/targets/*/; do [ -d "$d" ] && basename "$d"; done; }
app_ids_json() { app_ids | jq -R . | jq -s -c .; }   # ["id1","id2"]  (or []  when empty)
```

Note: `app_ids` emits names in shell glob order (sorted). `jq -R . | jq -s -c .` turns the lines into a compact JSON array; with no input it yields `[]`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/test_app_ids.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/lib/paths.sh utils/recon/tests/test_app_ids.sh
git commit -m "feat(recon): add app_ids/app_ids_json workspace enumeration to paths.sh"
```

---

### Task 3: Stub adapters + offline stub test

**Files:**
- Create: `utils/recon/tests/dagu/stubs/scope2surface.sh`, `surfagr.sh`, `screenshotter.sh`, `pipeline-recon.sh`, `pipeline-subenum.sh`, `takeover-scope.sh`, `takeover-discovered.sh`
- Create: `utils/recon/tests/dagu/fixtures/scope.txt`
- Create: `utils/recon/tests/dagu/test_stubs.sh`

**Interfaces:**
- Consumes: `lib/paths.sh`, `lib/manifest.sh`, `lib/appid.sh` (real), `$BASE` env.
- Produces: seven stub scripts with the SAME invocation contract as the real adapters (`scope2surface.sh <scope>`, `surfagr.sh`, `screenshotter.sh`, `pipeline-recon.sh <app_id>`, `pipeline-subenum.sh <app_id>`, `takeover-scope.sh`, `takeover-discovered.sh <app_id>`). Each writes its canonical artifact(s) + a manifest row, and asserts its canonical INPUT already exists (exit 1 otherwise) so dependency ordering is verifiable.

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/dagu/test_stubs.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../../lib/paths.sh"
S="$DIR/stubs"

# Run the stubs in dependency order (mimicking the DAG) — every precondition met.
bash "$S/scope2surface.sh" "$DIR/fixtures/scope.txt"
bash "$S/surfagr.sh"
bash "$S/screenshotter.sh"
bash "$S/takeover-scope.sh"
for id in $(app_ids); do
  bash "$S/pipeline-recon.sh" "$id"
  bash "$S/pipeline-subenum.sh" "$id"
  bash "$S/takeover-discovered.sh" "$id"
done

assert_file_exists "$(subdomains)" "scope2surface stub wrote subdomains"
assert_file_exists "$(httpx_meta)" "scope2surface stub wrote httpx_meta"
assert_file_exists "$(scope_findings)" "takeover-scope stub wrote scope findings"
assert_eq "2" "$(app_ids | wc -l | tr -d ' ')" "surfagr stub produced 2 app_id workspaces"
for id in $(app_ids); do
  assert_file_exists "$(meta_json "$id")"      "meta.json for $id"
  assert_file_exists "$(endpoints "$id")"      "endpoints for $id"
  assert_file_exists "$(subs "$id")"           "subs for $id"
  assert_file_exists "$(screenshot "$id")"     "screenshot for $id"
  assert_file_exists "$(takeover "$id")"       "takeover for $id"
  assert_contains "$(manifest_path "$id")" '"role":"meta"' "manifest meta row for $id"
done

# Ordering guard: takeover-discovered stub must refuse to run before recon+subenum.
fresh="$(mktemp -d)"; export BASE="$fresh"
bash "$S/scope2surface.sh" "$DIR/fixtures/scope.txt"; bash "$S/surfagr.sh"
one="$(app_ids | head -n1)"
if bash "$S/takeover-discovered.sh" "$one" 2>/dev/null; then
  echo "FAIL: takeover-discovered stub ran without endpoints/subs"; ASSERT_FAILED=1
else
  echo "ok: takeover-discovered stub enforces its preconditions"
fi
rm -rf "$BASE" "$fresh"
assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/dagu/test_stubs.sh`
Expected: FAIL — stub scripts do not exist yet.

- [ ] **Step 3: Create the fixture scope** — `utils/recon/tests/dagu/fixtures/scope.txt`

```
example.com
```

- [ ] **Step 4: Write the stub adapters**

All stubs resolve the real lib via their own location (`../../../lib` from `tests/dagu/stubs/`). Create each file:

`utils/recon/tests/dagu/stubs/scope2surface.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
mkdir -p "$(surface_dir)"
printf 'a.example.com\nb.example.com\n' > "$(subdomains)"
cat > "$(httpx_meta)" <<'JSON'
{"url":"https://a.example.com","host":"a.example.com","host_ip":"10.0.0.1","title":"App A","webserver":"nginx","content_length":1,"status_code":200,"tech":["React"]}
{"url":"https://b.example.com","host":"b.example.com","host_ip":"10.0.0.2","title":"App B","webserver":"envoy","content_length":2,"status_code":200,"tech":[]}
JSON
manifest_append _surface subdomains subdomains.txt stub-scope2surface stub
manifest_append _surface httpx_meta httpx_full_metadata.jsonl stub-scope2surface stub
```

`utils/recon/tests/dagu/stubs/surfagr.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"; source "$LIB/appid.sh"
[ -f "$(httpx_meta)" ] || { echo "stub surfagr: missing httpx_meta input" >&2; exit 1; }
while read -r line; do
  [ -n "$line" ] || continue
  host="$(jq -r .host <<<"$line")"; url="$(jq -r .url <<<"$line")"
  title="$(jq -r .title <<<"$line")"; ip="$(jq -r .host_ip <<<"$line")"
  port=443; app_id="$(app_id_for "$host" "$port")"
  mkdir -p "$(app_dir "$app_id")"
  jq -n --arg app_id "$app_id" --arg host "$host" --arg port "$port" \
        --arg base_url "$url" --arg title "$title" --arg ip "$ip" \
    '{app_id:$app_id,host:$host,port:$port,base_url:$base_url,title:$title,
      host_ip:$ip,webserver:"stub",status_code:"200",tech:[],cluster_hosts:[$base_url]}' \
    > "$(meta_json "$app_id")"
  manifest_append "$app_id" meta meta.json stub-surfagr stub
done < "$(httpx_meta)"
```

`utils/recon/tests/dagu/stubs/screenshotter.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
found=0
for m in "$BASE"/targets/*/meta.json; do
  [ -e "$m" ] || continue
  found=1; app_id="$(jq -r .app_id "$m")"
  printf 'PNG' > "$(screenshot "$app_id")"
  manifest_append "$app_id" screenshot screenshot.png stub-screenshotter stub
done
[ "$found" = 1 ] || { echo "stub screenshotter: no meta.json inputs" >&2; exit 1; }
```

`utils/recon/tests/dagu/stubs/pipeline-recon.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
app_id="$1"
[ -f "$(meta_json "$app_id")" ] || { echo "stub recon: missing meta.json for $app_id" >&2; exit 1; }
printf 'https://%s/dashboard\n' "$app_id" > "$(endpoints "$app_id")"
mkdir -p "$(app_dir "$app_id")/js" "$(app_dir "$app_id")/html"
printf '//js' > "$(app_dir "$app_id")/js/app.js"
printf '<html></html>' > "$(app_dir "$app_id")/html/index.html"
manifest_append "$app_id" endpoints endpoints.txt stub-recon stub
```

`utils/recon/tests/dagu/stubs/pipeline-subenum.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
app_id="$1"
[ -f "$(meta_json "$app_id")" ] || { echo "stub subenum: missing meta.json for $app_id" >&2; exit 1; }
printf 'dev.%s\n' "$app_id" > "$(subs "$app_id")"
manifest_append "$app_id" subs subs.txt stub-subenum stub
```

`utils/recon/tests/dagu/stubs/takeover-scope.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
[ -f "$(subdomains)" ] || { echo "stub takeover-scope: missing subdomains input" >&2; exit 1; }
mkdir -p "$(surface_dir)/findings"
: > "$(scope_findings)"   # no findings (stub)
manifest_append _surface takeovers_scope findings/takeovers_scope.jsonl stub-takeover-scope stub
```

`utils/recon/tests/dagu/stubs/takeover-discovered.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
app_id="$1"
[ -f "$(endpoints "$app_id")" ] && [ -f "$(subs "$app_id")" ] || {
  echo "stub takeover-discovered: requires endpoints+subs for $app_id" >&2; exit 1; }
mkdir -p "$(app_dir "$app_id")/findings"
printf '[Not Vulnerable] https://%s\n' "$app_id" > "$(takeover "$app_id")"
manifest_append "$app_id" takeover findings/takeover.txt stub-takeover-discovered stub
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash utils/recon/tests/dagu/test_stubs.sh`
Expected: `ok:` lines then `PASS`.

- [ ] **Step 6: Commit**

```bash
git add utils/recon/tests/dagu/stubs utils/recon/tests/dagu/fixtures utils/recon/tests/dagu/test_stubs.sh
git commit -m "test(recon): add stub adapters + offline stub test for the Dagu reproduction"
```

---

### Task 4: Child DAG `app.yaml`

**Files:**
- Create: `utils/recon/orchestration/dagu/app.yaml`
- Create: `utils/recon/tests/dagu/test_dagu_app.sh`

**Interfaces:**
- Consumes: `SYNTAX.md` (Task 1) for exact tokens; the stub adapters (Task 3); `lib/appid.sh`.
- Produces: a child DAG named `recon-app` taking params `BASE`, `APP_ID`, `ADAPTER_DIR`; steps `recon` ∥ `subenum` → `takeover`. Each step runs `bash ${ADAPTER_DIR}/<adapter>.sh ${APP_ID}` with `BASE` in env.

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/dagu/test_dagu_app.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../../lib/paths.sh"; source "$DIR/../../lib/appid.sh"
STUBS="$(cd "$DIR/stubs" && pwd)"
DAG="$(cd "$DIR/../../orchestration/dagu" && pwd)/app.yaml"

# Pre-create a workspace the child DAG operates on (surfagr's job, done here directly).
app_id="$(app_id_for app.example.com 443)"
mkdir -p "$(app_dir "$app_id")"
printf '{"app_id":"%s","cluster_hosts":["https://app.example.com"]}\n' "$app_id" > "$(meta_json "$app_id")"

# Run the child DAG with stub adapters. (Use START_CMD param syntax from SYNTAX.md.)
dagu start "$DAG" -- BASE="$BASE" APP_ID="$app_id" ADAPTER_DIR="$STUBS"

assert_file_exists "$(endpoints "$app_id")" "child DAG produced endpoints (recon ran)"
assert_file_exists "$(subs "$app_id")"      "child DAG produced subs (subenum ran)"
assert_file_exists "$(takeover "$app_id")"  "child DAG produced takeover (after recon+subenum)"
rm -rf "$BASE"
assert_summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/dagu/test_dagu_app.sh`
Expected: FAIL — `app.yaml` does not exist (dagu errors).

- [ ] **Step 3: Write the child DAG** — `utils/recon/orchestration/dagu/app.yaml`

Use the tokens confirmed in `SYNTAX.md` (Task 1). Confirmed facts that shape this file:
the shell-command field is **`run:`** (not `command:`); and the file must have **NO `name:`
field** — Task 1 found that a DAG passed to `dagu start` is rejected if it declares `name:`,
and a child invoked via `with.dag: <path>` is located by PATH, not by name. So `app.yaml`
omits `name:` (it works both as the Task-4 `dagu start` entrypoint and as the Task-5 child).

```yaml
params:
  - BASE: ""
  - APP_ID: ""
  - ADAPTER_DIR: ""
env:
  - BASE: ${BASE}
steps:
  - name: recon
    run: bash ${ADAPTER_DIR}/pipeline-recon.sh ${APP_ID}
  - name: subenum
    run: bash ${ADAPTER_DIR}/pipeline-subenum.sh ${APP_ID}
  - name: takeover
    run: bash ${ADAPTER_DIR}/takeover-discovered.sh ${APP_ID}
    depends:
      - recon
      - subenum
```
If `dagu` rejects any field, correct it per the installed binary (and fix `SYNTAX.md`); the
Task-4 test is the oracle.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/dagu/test_dagu_app.sh`
Expected: `ok:` lines then `PASS`. If dagu rejects a field, correct it per the real binary (and fix `SYNTAX.md` if it was wrong), then re-run.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/orchestration/dagu/app.yaml utils/recon/tests/dagu/test_dagu_app.sh
git commit -m "feat(recon): add Dagu child app DAG (recon∥subenum→takeover)"
```

---

### Task 5: Parent DAG `recon.yaml` + full smoke test

**Files:**
- Create: `utils/recon/orchestration/dagu/recon.yaml`
- Create: `utils/recon/tests/dagu/test_dagu_smoke.sh`

**Interfaces:**
- Consumes: `SYNTAX.md`; `app.yaml` (the child, name `recon-app`); the stubs (Task 3); `app_ids_json` (Task 2).
- Produces: the parent DAG named `recon` taking params `BASE`, `SCOPE`, `ADAPTER_DIR` (default `utils/recon/adapters`), `LIB_DIR` (default `utils/recon/lib`); the topology from the spec; the end-to-end offline smoke test.

- [ ] **Step 1: Write the failing test** — `utils/recon/tests/dagu/test_dagu_smoke.sh`

```bash
#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/../assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../../lib/paths.sh"
STUBS="$(cd "$DIR/stubs" && pwd)"
LIBD="$(cd "$DIR/../../lib" && pwd)"
DAG="$(cd "$DIR/../../orchestration/dagu" && pwd)/recon.yaml"
SCOPE="$DIR/fixtures/scope.txt"

dagu start "$DAG" -- BASE="$BASE" SCOPE="$SCOPE" ADAPTER_DIR="$STUBS" LIB_DIR="$LIBD"

# scope-level artifacts
assert_file_exists "$(subdomains)"      "smoke: subdomains promoted"
assert_file_exists "$(httpx_meta)"      "smoke: httpx_meta promoted"
assert_file_exists "$(scope_findings)"  "smoke: stage-1 takeover findings present"
# fan-out happened for both discovered app_ids
assert_eq "2" "$(app_ids | wc -l | tr -d ' ')" "smoke: 2 app workspaces created"
for id in $(app_ids); do
  assert_file_exists "$(endpoints "$id")"  "smoke: endpoints for $id (recon ran)"
  assert_file_exists "$(subs "$id")"       "smoke: subs for $id (subenum ran)"
  assert_file_exists "$(screenshot "$id")" "smoke: screenshot for $id"
  assert_file_exists "$(takeover "$id")"   "smoke: takeover for $id (after recon+subenum)"
done
rm -rf "$BASE"
assert_summary
```

Note: the per-app `takeover.txt` existing proves ordering — the stub `takeover-discovered` exits non-zero unless `endpoints`+`subs` already exist, so a wrong `depends` in the DAG makes the child step (and the assertion) fail.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash utils/recon/tests/dagu/test_dagu_smoke.sh`
Expected: FAIL — `recon.yaml` does not exist.

- [ ] **Step 3: Write the parent DAG** — `utils/recon/orchestration/dagu/recon.yaml`

Use the tokens confirmed in `SYNTAX.md` (Task 1). Confirmed facts that shape this file:
shell-command field is **`run:`**; this entrypoint DAG must have **NO `name:`** field;
child-DAG invocation is **`action: dag.run`** with **`with.dag: <path>`** (located by PATH —
so the child path is passed as the `APP_DAG` param, not referenced by a DAG name) and
**`with.params`**; the parallel concurrency key is **`max_concurrent`** (snake_case); the
current item is **`${ITEM}`**. Structure:
```yaml
params:
  - BASE: ""
  - SCOPE: ""
  - ADAPTER_DIR: "utils/recon/adapters"
  - LIB_DIR: "utils/recon/lib"
  - APP_DAG: ""          # absolute path to app.yaml (the child); passed by caller/test
env:
  - BASE: ${BASE}
steps:
  - name: scope2surface
    run: bash ${ADAPTER_DIR}/scope2surface.sh ${SCOPE}
  - name: takeover-scope
    run: bash ${ADAPTER_DIR}/takeover-scope.sh
    depends:
      - scope2surface
    continueOn:
      failure: true
  - name: surfagr
    run: bash ${ADAPTER_DIR}/surfagr.sh
    depends:
      - scope2surface
  - name: screenshotter
    run: bash ${ADAPTER_DIR}/screenshotter.sh
    depends:
      - surfagr
  - name: enumerate
    run: bash -c 'source "${LIB_DIR}/paths.sh"; app_ids_json'
    output: APP_IDS
    depends:
      - surfagr
  - name: per-app
    action: dag.run
    with:
      dag: ${APP_DAG}
      params: "BASE=${BASE} APP_ID=${ITEM} ADAPTER_DIR=${ADAPTER_DIR}"
    parallel:
      items: ${APP_IDS}
      max_concurrent: 3
    depends:
      - enumerate
  - name: done
    run: "true"
    depends:
      - per-app
      - takeover-scope
      - screenshotter
```

Notes for the implementer:
- `enumerate` needs `$BASE` in its environment — set by the DAG-level `env`. `app_ids_json` requires `jq`.
- `APP_DAG` is the absolute path to `app.yaml`; the smoke test (Step 1) passes it explicitly. If `SYNTAX.md`/the binary accept a relative `with.dag: ./app.yaml` resolved against the parent DAG's directory, you may default `APP_DAG` to that — but the test passing an absolute path must work regardless.
- The exact `with.params` form (string `"K=V K=V"` vs a YAML map) and `continueOn` spelling must match what the binary accepts; correct the YAML if `dagu` rejects it. The smoke test is the oracle — iterate until green, keeping `SYNTAX.md` accurate.

Also update the smoke test (Step 1) `dagu start` line to pass `APP_DAG`:
```bash
dagu start "$DAG" -- BASE="$BASE" SCOPE="$SCOPE" ADAPTER_DIR="$STUBS" LIB_DIR="$LIBD" APP_DAG="$(dirname "$DAG")/app.yaml"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash utils/recon/tests/dagu/test_dagu_smoke.sh`
Expected: `ok:` lines then `PASS`. Iterate the YAML against dagu's errors until green; keep `SYNTAX.md` accurate.

- [ ] **Step 5: Commit**

```bash
git add utils/recon/orchestration/dagu/recon.yaml utils/recon/tests/dagu/test_dagu_smoke.sh
git commit -m "feat(recon): add Dagu parent DAG + offline smoke test (full pipeline fan-out)"
```

---

### Task 6: Documentation

**Files:**
- Create: `utils/recon/orchestration/dagu/README.md`

**Interfaces:**
- Consumes: everything above. Produces: docs only.

- [ ] **Step 1: Confirm the whole offline suite is green**

Run: `bash utils/recon/tests/run.sh; echo "exit=$?"`
Expected: every `test_*.sh` (including `test_app_ids.sh`) prints `PASS`, final `exit=0`. Then run the Dagu tests explicitly (they live under `tests/dagu/`, which `run.sh` does not recurse into):
```bash
bash utils/recon/tests/dagu/test_stubs.sh && \
bash utils/recon/tests/dagu/test_dagu_app.sh && \
bash utils/recon/tests/dagu/test_dagu_smoke.sh ; echo "dagu-exit=$?"
```
Expected: `PASS` for each, `dagu-exit=0`.

- [ ] **Step 2: Write the README** — `utils/recon/orchestration/dagu/README.md`

````markdown
# Dagu reproduction of the recon pipeline

A Dagu DAG that drives the contract adapters in [`../../adapters/`](../../adapters/),
producing the canonical `app_id`-keyed workspace. It replaces the legacy
`recon-orchestrator.sh` end-to-end driver. See the design at
`docs/superpowers/specs/2026-06-18-recon-dagu-reproduction-design.md`.

## DAGs

- `recon.yaml` (parent): `scope2surface` → { `takeover-scope` (stage-1, parallel) ∥
  `surfagr` → `screenshotter` ∥ (`enumerate` → `per-app` fan-out) } → `done`.
- `app.yaml` (child `recon-app`, one run per app_id): `recon` ∥ `subenum` → `takeover`.

The per-app step uses Dagu's dynamic `parallel` over the app_ids discovered at runtime
(`max_concurrent: 3`, matching the legacy `xargs -P 3`). `takeover-scope` runs concurrently
and uses `continueOn: failure`. Retries are disabled (live infra).

## How it talks to the contract

Dagu writes no artifact paths. It passes only `BASE`, `ADAPTER_DIR`, `LIB_DIR`, `SCOPE`;
every path resolves inside the adapters via `lib/paths.sh`. The app_id list comes from
`app_ids_json` (single source of truth), not a glob.

## Run

```bash
dagu start utils/recon/orchestration/dagu/recon.yaml -- \
  BASE=/scans/acme SCOPE=/path/scope.txt
```

`ADAPTER_DIR` defaults to `utils/recon/adapters` and `LIB_DIR` to `utils/recon/lib`.

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
````

- [ ] **Step 3: Commit**

```bash
git add utils/recon/orchestration/dagu/README.md
git commit -m "docs(recon): document the Dagu reproduction and how to run it"
```

---

## Self-Review

**1. Spec coverage:**
- §3.1 parent topology → Task 5 (recon.yaml). ✓
- §3.2 child topology → Task 4 (app.yaml). ✓
- §3.3 concurrency/resilience (max_concurrent 3, continueOn failure, retries off) → Task 5 YAML. ✓
- §4 contract integration (BASE/ADAPTER_DIR/LIB_DIR, no path literals, app_ids) → Tasks 2 (app_ids), 4-5 (DAGs pass only BASE/dirs). ✓
- §5 smoke test with stubs (stubs use real lib, assert inputs) → Tasks 3 (stubs+offline test), 5 (smoke). ✓
- §6 install + pin syntax → Task 1. ✓
- §7 file layout → Tasks 1-6 create exactly that tree. ✓
- §8 how to run → Task 6 README. ✓
- §9 out of scope (Taskfile, live tools, scheduler/UI) → respected; nothing builds them. ✓
- §10 knobs (max_concurrent 3, screenshotter ∥ fan-out, locations, app_ids in lib) → Tasks 2,5. ✓

**2. Placeholder scan:** No TBD/TODO. Every code/YAML step shows complete content. The "adjust to SYNTAX.md" notes are a real verification gate against a version-variable tool, not deferred work — the YAML shown is concrete and runnable as the starting point, and the smoke test is the oracle that confirms it.

**3. Type consistency:**
- `app_ids` / `app_ids_json` — defined Task 2, used in Task 5's `enumerate` step and in Tasks 3-5 tests. ✓
- Stub invocation contract (`scope2surface.sh <scope>`, `pipeline-recon.sh <app_id>`, etc.) matches the real adapters' interface and the DAG step commands in Tasks 4-5. ✓
- Child DAG name `recon-app` — defined Task 4 (`name: recon-app`), referenced Task 5 (`run: recon-app`). ✓
- Path helpers (`subdomains`, `httpx_meta`, `scope_findings`, `meta_json`, `endpoints`, `subs`, `screenshot`, `takeover`, `app_dir`, `surface_dir`, `manifest_path`) — all from the existing `lib/paths.sh`, used consistently in stubs and tests. ✓
- `BASE`/`ADAPTER_DIR`/`LIB_DIR` params — defined in both DAGs and passed consistently parent→child (Task 5 `params:` → Task 4 `params:`). ✓
