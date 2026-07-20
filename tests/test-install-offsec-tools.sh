#!/usr/bin/env bash
# Tests for org/install-offsec-tools.sh.
# Runs as a normal user (not root). Uses --dry-run to avoid all side effects
# (apt, pipx, file writes). Each test is self-contained and prints PASS/FAIL.
set -eo pipefail

SCRIPT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/org/install-offsec-tools.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -f "$SCRIPT" ] || fail "installer not found at $SCRIPT"

# --- Test 1: --dry-run exits 0 without performing any installation ---
output="$(bash "$SCRIPT" --dry-run /tmp 2>&1)" \
    || fail "--dry-run should exit 0; got: $output"
pass "--dry-run exits 0"

# --- Test 2: --dry-run lists all install_* functions when --groups is unset ---
output="$(bash "$SCRIPT" --dry-run /tmp)" || fail "--dry-run failed"
for fn in install_base install_PD install_praetorian install_tomnomnom \
          install_takeover install_recon install_cracking install_dictionary \
          install_sast install_dast install_RT install_cloud install_reversing \
          install_utils install_AI; do
    echo "$output" | grep -qx "$fn" || fail "dry-run missing $fn in output"
done
# install_go is no longer a selectable group — it's an internal helper called
# unconditionally by install_base — so it must NOT appear in the dispatch list.
echo "$output" | grep -qx install_go && fail "install_go should not be in INSTALL_FNS_ALL (now called from install_base)"
pass "--dry-run with no --groups lists all 15 selectable install_* functions"

# --- Test 3: --groups=base,recon limits dry-run output to install_base, install_recon ---
output="$(bash "$SCRIPT" --dry-run --groups=base,recon /tmp)" \
    || fail "--dry-run --groups=base,recon failed"
echo "$output" | grep -qx install_base   || fail "expected install_base when --groups=base,recon"
echo "$output" | grep -qx install_recon  || fail "expected install_recon when --groups=base,recon"
echo "$output" | grep -qx install_PD     && fail "did NOT expect install_PD when --groups=base,recon"
echo "$output" | grep -qx install_RT     && fail "did NOT expect install_RT when --groups=base,recon"
pass "--groups=base,recon filters INSTALL_FNS to those groups only"

# --- Test 4: --groups order on the CLI does not affect output order (canonical order is preserved) ---
output="$(bash "$SCRIPT" --dry-run --groups=utils,base /tmp)" \
    || fail "--dry-run --groups=utils,base failed"
base_line=$(echo "$output" | grep -n -x install_base   | cut -d: -f1)
utils_line=$(echo "$output" | grep -n -x install_utils | cut -d: -f1)
[ -n "$base_line" ] && [ -n "$utils_line" ] && [ "$base_line" -lt "$utils_line" ] \
    || fail "canonical order not preserved (base line=$base_line, utils line=$utils_line)"
pass "canonical execution order preserved regardless of --groups CLI order"

# --- Test 5: unknown group name aborts with exit 1 and a helpful message ---
if bash "$SCRIPT" --dry-run --groups=base,does_not_exist,recon /tmp 2>/tmp/err.log; then
    fail "expected exit 1 for unknown group, got exit 0"
fi
grep -q "unknown group" /tmp/err.log || fail "stderr should mention 'unknown group' (got: $(cat /tmp/err.log))"
grep -q "does_not_exist" /tmp/err.log || fail "stderr should name the offending group"
pass "unknown group name exits 1 with helpful stderr"
rm -f /tmp/err.log

# --- Test 6: --groups= (empty list) aborts with exit 1 ---
if bash "$SCRIPT" --dry-run --groups= /tmp 2>/tmp/err.log; then
    fail "expected exit 1 for empty --groups=, got exit 0"
fi
pass "empty --groups= exits 1"
rm -f /tmp/err.log

# --- Test 7: install_AI pre-installs the mcp-remote bridge (Codex <-> Burp MCP) ---
grep -q 'npm install -g mcp-remote' "$SCRIPT" || \
    fail "install_AI must pre-install mcp-remote (Codex Burp MCP bridge)"
pass "install_AI pre-installs mcp-remote"

echo "All tests passed."
