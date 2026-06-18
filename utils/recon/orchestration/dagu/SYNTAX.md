# Dagu syntax confirmed against `dagu 2.7.17`

Binary: `~/.local/bin/dagu` (v2.7.17, installed from GitHub release `dagucloud/dagu` via tarball)

## Notes on entrypoint DAGs
An entrypoint DAG file (the one passed to `dagu start`) must NOT define a `name:` field — the
engine derives the DAG name from the filename. Non-entrypoint (child) DAGs called via
`action: dag.run` CAN have a `name:` but it is also optional (defaults to filename stem).

---

- **CONTINUE_ON**: step-level fault tolerance uses `continue_on:` (snake_case). `continueOn:` is
  rejected by the parser with "use snake_case keys (continueOn -> continue_on)".

  ```yaml
  steps:
    - name: optional-step
      run: might-fail.sh
      continue_on:
        failure: true
  ```

- **COMMAND_FIELD**: `run:` (canonical; `command:` is accepted but deprecated)

  ```yaml
  steps:
    - name: greet
      run: echo "greeting is ${GREETING}"
  ```

- **SUBDAG_INVOKE**: `action: dag.run` with `with.dag:` pointing to an **absolute path** (or a
  DAG name registered in `$DAGU_HOME/dags/`). The `run:` field is for shell commands, not
  sub-DAG calls.

  ```yaml
  steps:
    - name: run-child
      action: dag.run
      with:
        dag: /absolute/path/to/child.yaml   # or bare name if in DAGU_HOME/dags/
        params:
          MY_PARAM: "value"
  ```

- **PARALLEL_KEYS**: `parallel:` block uses `items:` + `max_concurrent:` (snake_case, NOT
  `maxConcurrent`). Default `max_concurrent` is 10; maximum is 1000. Only valid with
  `action: dag.run` (or `dag.enqueue`).

  ```yaml
  steps:
    - name: fan-out
      action: dag.run
      with:
        dag: /path/to/child.yaml
        params:
          APP_DIR: "${ITEM}"
      parallel:
        items: ["/scans/app1", "/scans/app2", "/scans/app3"]
        max_concurrent: 3
  ```

- **ITEM_VAR**: `${ITEM}` — the current item from the `parallel.items` list is bound to the
  variable `ITEM` and can be referenced as `${ITEM}` anywhere in the step's `with.params`
  block.

  ```yaml
  with:
    dag: /path/to/child.yaml
    params:
      APP_DIR: "${ITEM}"   # ITEM = current element from parallel.items
  ```

- **PARAM_PASS**: params reach the child DAG via `with.params:` as a map of `KEY: value`. The
  child accesses them with `${KEY}`. Multiple params: just add more keys to the map.

  ```yaml
  # parent
  with:
    dag: /path/to/child.yaml
    params:
      APP_DIR: "${ITEM}"
      SCAN_ID: "${SCAN_ID}"

  # child (params block declares expected params)
  params:
    - name: APP_DIR
      type: string
      required: true
    - name: SCAN_ID
      type: string
      required: true
  steps:
    - name: work
      run: echo "processing ${APP_DIR} for scan ${SCAN_ID}"
  ```

- **START_CMD**: `dagu start <file> -- KEY=value KEY2=value2`

  ```bash
  dagu start /path/to/parent.yaml -- SCAN_ID=abc123 SCOPE=scope.txt
  ```

- **STATUS_CMD**: `dagu status <DAG name or file>` — shows the most recent run's per-step
  status tree. Optionally narrow to a specific run with `--run-id <id>`.

  ```bash
  dagu status /path/to/parent.yaml
  dagu status --run-id 019ed9ec-3bf6-7afa-b704-f2f61eacce2e /path/to/parent.yaml
  ```

  Output format (verified):
  ```
  Succeeded - 2026-06-18T10:49:58+02:00

  dag: dagu-probe-parent (0s)
  ├─step-shell-cmd (0s) [succeeded]
  ├─step-capture-stdout (0s) [succeeded]
  ├─step-emit-json-array (0s) [succeeded]
  └─step-parallel-subdag (0s) [succeeded]
    ├─subdag: <id> [APP_DIR="/scans/app1"]
    ├─subdag: <id> [APP_DIR="/scans/app2"]
    └─subdag: <id> [APP_DIR="/scans/app3"]
  ```

---

## Probe DAGs used for verification

### `/tmp/dagu-probe-parent.yaml` (entrypoint — no `name:` field)
```yaml
params:
  - name: GREETING
    type: string
    description: A greeting message
    default: hello
type: graph
steps:
  - name: step-shell-cmd
    run: echo "greeting is ${GREETING}"

  - name: step-capture-stdout
    run: echo "item-alpha item-beta item-gamma"
    output: ITEMS_RAW
    depends: [step-shell-cmd]

  - name: step-emit-json-array
    run: 'echo ''["alpha","beta","gamma"]'''
    output: ITEMS_JSON
    depends: [step-capture-stdout]

  - name: step-parallel-subdag
    action: dag.run
    with:
      dag: /tmp/dagu-probe-child.yaml
      params:
        ITEM: "${ITEM}"
    parallel:
      items: ["alpha", "beta", "gamma"]
      max_concurrent: 2
    depends: [step-emit-json-array]
```

### `/tmp/dagu-probe-child.yaml` (sub-DAG — no `name:` field needed)
```yaml
params:
  - name: ITEM
    type: string
    description: Item passed from parent parallel step
    required: true
    default: default-item
type: graph
steps:
  - name: greet
    run: echo "child processing ITEM=${ITEM}"
  - name: done
    run: echo "child done for ${ITEM}"
    depends: [greet]
```

Run command verified green:
```bash
dagu start /tmp/dagu-probe-parent.yaml -- GREETING=hi
# Result: Succeeded
```
