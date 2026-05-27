#!/usr/bin/env bash
# recon-orchestrator.sh <scan_id> <scope_file>
set -euo pipefail

SCAN_ID="$1"
SCOPE="$2"
BASE="./scans/${SCAN_ID}"
mkdir -p "$BASE"
cp "$SCOPE" "$BASE/scope.txt"

# 1. Attack surface
/opt/custom-tools/recon/scope2surface.sh "$BASE/scope.txt" "$BASE/att_surface"

# 1b. Stage 1 takeover (background, parallel with everything below)
/opt/custom-tools/recon/run-takeover-scope.sh \
    "$BASE/att_surface/scans/subdomains.txt" \
    "$BASE/takeovers_scope.jsonl" &
TAKEOVER_SCOPE_PID=$!

# 2. Cluster vhosts per app
/opt/custom-tools/recon/surfagr.sh "$BASE/att_surface/scans/httpx_full_metadata.jsonl" "$BASE/apps"

# 3. Per-app pipelines (recon + subenum) in parallel across apps
find "$BASE/apps/targets" -mindepth 1 -maxdepth 1 -type d | \
    xargs -P 3 -I {} /opt/custom-tools/recon/pipeline-recon.sh {} &
PIPELINE_RECON_PID=$!

find "$BASE/apps/targets" -mindepth 1 -maxdepth 1 -type d | \
    xargs -P 3 -I {} /opt/custom-tools/recon/pipeline-subenum.sh {} &
PIPELINE_SUBENUM_PID=$!

wait $PIPELINE_RECON_PID $PIPELINE_SUBENUM_PID

# 4. Stage 2 takeover per-app (after pipeline-recon has produced all_endpoints_clean.txt)
# Track Stage 2 PIDs explicitly: a bare `wait` here would also reap the
# Stage 1 PID we still want to wait on below, making the next `wait` fail
# with "pid N is not a child of this shell".
STAGE2_PIDS=()
for app_dir in "$BASE/apps"/targets/*/; do
    /opt/custom-tools/recon/run-takeover-discovered.sh "$app_dir" &
    STAGE2_PIDS+=("$!")
done
[ "${#STAGE2_PIDS[@]}" -gt 0 ] && wait "${STAGE2_PIDS[@]}"

# 5. Wait for Stage 1 takeover (likely already finished)
wait "$TAKEOVER_SCOPE_PID"
