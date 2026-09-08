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

# --- Test 8: Claude Code installs natively, never as a root-owned npm global ---
# This is what makes auto-update possible: `sudo npm install -g` puts the CLI in
# /usr/local/lib/node_modules (root-owned), the non-root container user cannot
# write there, the autoupdater fails, and the agent stays pinned to whatever
# release the Docker layer was built with.
grep -q 'npm install -g @anthropic-ai/claude-code' "$SCRIPT" && \
    fail "Claude Code must NOT be installed via npm -g (root-owned tree breaks the autoupdater)"
grep -q 'claude.ai/install.sh' "$SCRIPT" || \
    fail "Claude Code must be installed via the native installer (claude.ai/install.sh)"
grep -q 'as_user bash -c' "$SCRIPT" || \
    fail "the native installer must run as the target user, not root (it refuses sudo)"
grep -q 'npm uninstall -g @anthropic-ai/claude-code' "$SCRIPT" || \
    fail "a legacy root-owned npm global install should be cleaned up after migrating"
pass "Claude Code uses the native, user-owned installer (autoupdater can self-heal)"

# --- Test 9: --claude-only refreshes just the agent, skipping every group ---
output="$(bash "$SCRIPT" --dry-run --claude-only /tmp)" || fail "--claude-only dry-run failed"
[ "$output" = "install_claude_code" ] || \
    fail "--claude-only should resolve to install_claude_code alone, got: $output"
output="$(bash "$SCRIPT" --dry-run --claude-only=2.1.263 /tmp)" \
    || fail "--claude-only=<version> dry-run failed"
[ "$output" = "install_claude_code" ] || \
    fail "--claude-only=<version> should resolve to install_claude_code alone, got: $output"
# The refresh path must stop before the system-wide passes: the trailing
# `chmod -R` over INSTALL_DIR would rewrite metadata for the whole toolchain,
# which inside a Docker build means a layer carrying a copy of every file.
grep -q 'CLAUDE_ONLY.*-eq 1' "$SCRIPT" || \
    fail "--claude-only needs an early-exit guard before the system-wide passes"
pass "--claude-only is a surgical, group-free Claude Code refresh"

# --- Test 10: the release channel is selectable (pin for reproducible engagements) ---
grep -q 'CLAUDE_CHANNEL="\${CLAUDE_CHANNEL:-latest}"' "$SCRIPT" || \
    fail "CLAUDE_CHANNEL must default to 'latest' and stay env-overridable"
bash "$SCRIPT" --dry-run --claude-only /tmp >/dev/null || fail "default channel path broke"
pass "Claude Code release channel defaults to latest and is overridable"

# --- Test 11: as_user resolves user-local binaries invoked by bare name ---
# sudo looks the command up in its OWN secure_path; the inline `PATH=...`
# assignment only lands in the child's environment, too late for the lookup.
# Without an `env` interposer every pipx binary under ~/.local/bin called by
# bare name dies with "sudo: <tool>: command not found" — which is exactly how
# `as_user search_vulns -u` failed mid-build while `as_user pipx ...` (pipx
# lives in /usr/bin, inside secure_path) sailed through.
as_user_body="$(sed -n '/^as_user() {/,/^}/p' "$SCRIPT")"
echo "$as_user_body" | grep -qw env \
    || fail "as_user must exec through 'env' so the PATH it sets is the one used to resolve the command"
echo "$as_user_body" | grep -q 'PATH=' \
    || fail "as_user must still put \$TARGET_HOME/.local/bin on PATH"
pass "as_user resolves bare-name user-local binaries (env interposer present)"

# --- Test 12: clone_if_missing retries transient git failures ---
# Same rationale as go_install: one dropped connection or a resolver timeout
# (glibc gives up after timeout:5 x attempts:2 -> "Could not resolve host")
# must not discard a ten-minute toolchain build under `set -e`.
clone_body="$(sed -n '/^clone_if_missing() {/,/^}/p' "$SCRIPT")"
echo "$clone_body" | grep -qw retry \
    || fail "clone_if_missing must wrap git clone in retry, like go_install does"

# Behavioural check: drive the real helpers with a stubbed git that fails twice
# before succeeding, and a stubbed sleep so the backoff costs no wall clock.
harness="$(mktemp -d)"
{
    sed -n '/^retry() {/,/^}/p' "$SCRIPT"
    echo "$clone_body"
    cat <<'STUB'
sleep() { :; }
attempts=0
git() {
    attempts=$((attempts + 1))
    [ "$attempts" -ge 3 ] || { echo "fatal: Could not resolve host: gitlab.com" >&2; return 128; }
    mkdir -p "${@: -1}/.git"
}
clone_if_missing https://example.invalid/x.git "$1/dest" >/dev/null 2>&1 \
    || { echo "clone_if_missing gave up despite a retry budget"; exit 1; }
[ "$attempts" -eq 3 ] || { echo "expected 3 git attempts, got $attempts"; exit 1; }
# Second call must short-circuit on the existing .git, not re-clone.
before=$attempts
clone_if_missing https://example.invalid/x.git "$1/dest" >/dev/null 2>&1
[ "$attempts" -eq "$before" ] || { echo "clone_if_missing re-cloned an existing checkout"; exit 1; }
STUB
} > "$harness/harness.sh"
out="$(bash "$harness/harness.sh" "$harness" 2>&1)" \
    || fail "clone_if_missing retry behaviour: $out"
rm -rf "$harness"
pass "clone_if_missing retries transient clone failures and stays idempotent"

# --- Test 13: the exploitdb clone is best-effort and never dangles a symlink ---
# It is the largest clone in the script and the only one not on GitHub, so it is
# the likeliest to be cut short — and a missing exploit DB is no reason to throw
# away the whole toolchain. Its three neighbours in install_recon (wpprobe
# update-db, search_vulns -u, the EyeWitness venv) are already best-effort.
exploitdb_block="$(grep -A6 'exploit-database/exploitdb' "$SCRIPT")"
echo "$exploitdb_block" | grep -q 'if clone_if_missing' \
    || fail "the exploitdb clone must be best-effort (an abort here discards the whole install)"
echo "$exploitdb_block" | grep -q 'ln -sf' \
    || fail "expected the searchsploit symlink next to the exploitdb clone"
# The symlink has to sit inside the success branch, or a failed clone leaves
# /usr/local/bin/searchsploit pointing at nothing.
echo "$exploitdb_block" | sed -n '/if clone_if_missing/,/^    else/p' | grep -q 'ln -sf' \
    || fail "the searchsploit symlink must only be created when the clone succeeded"
pass "exploitdb is best-effort and symlinks only on success"

# --- Test 14: install_RT ships the Rust toolchain aardwolf needs, before NetExec ---
# NetExec hard-depends on aardwolf, which PyPI publishes as an sdist only and
# which builds a PyO3 extension through setuptools-rust. There is no wheel to
# fall back on, so a missing rustc is a deterministic build kill, not a flake:
#   error: can't find Rust compiler
#   ERROR: Failed building wheel for aardwolf
rt_body="$(sed -n '/^install_RT()/,/^}/p' "$SCRIPT")"
echo "$rt_body" | grep -q 'apt install -y rustc cargo' \
    || fail "install_RT must install a Rust toolchain (aardwolf builds a PyO3 extension from sdist)"
rust_line="$(echo "$rt_body" | grep -n 'rustc cargo'        | head -1 | cut -d: -f1)"
nxc_line="$(echo  "$rt_body" | grep -n 'Pennyw0rth/NetExec' | head -1 | cut -d: -f1)"
[ -n "$rust_line" ] && [ -n "$nxc_line" ] && [ "$rust_line" -lt "$nxc_line" ] \
    || fail "rustc must be installed BEFORE NetExec (rust=$rust_line netexec=$nxc_line)"
pass "install_RT installs rustc/cargo ahead of NetExec"

# --- Test 15: install_RT supplies the readline headers evil-winrm's gem chain needs ---
# evil-winrm pulls readline-ext, a native extension. ruby-dev provides the
# ncurses headers its extconf probes for but not readline's, so the build stops
# at "checking for readline/readline.h... no" and gem install exits 1 — another
# deterministic build kill, not a flake.
echo "$rt_body" | grep -q 'apt install -y libreadline-dev' \
    || fail "install_RT must install libreadline-dev (readline-ext builds a native extension)"
rl_line="$(echo "$rt_body" | grep -n 'libreadline-dev' | head -1 | cut -d: -f1)"
ew_line="$(echo "$rt_body" | grep -n 'gem install --no-document evil-winrm' | head -1 | cut -d: -f1)"
[ -n "$rl_line" ] && [ -n "$ew_line" ] && [ "$rl_line" -lt "$ew_line" ] \
    || fail "libreadline-dev must be installed BEFORE evil-winrm (readline=$rl_line evil-winrm=$ew_line)"
pass "install_RT installs libreadline-dev ahead of evil-winrm"

echo "All tests passed."
