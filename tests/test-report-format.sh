#!/usr/bin/env bash
# Tests the report-formatting rules enforced by the PostToolUse(Write|Edit) hook
# org/templates/claude/hooks/check-report-format.sh on finding write-ups and the
# rendered activity file:
#   - report prose is never hard-wrapped mid-paragraph (pre-existing rule),
#   - every fenced code block opens with a language (```sh, ```http, ...),
#   - no fence line is indented or tab-ed.
# Working files (journal/TODO/AGENTS) and the reference templates stay exempt.
# Requires jq (the hook exits 0 without it).
set -eo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
HOOK="$ROOT/org/templates/claude/hooks/check-report-format.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

command -v jq >/dev/null 2>&1 || fail "jq is required to exercise the hook"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/findings"

HOOK_OUT=""
hook() {  # $1 = file path; sets HOOK_OUT, returns the hook exit code
    local rc=0
    HOOK_OUT="$(printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$HOOK" 2>&1)" || rc=$?
    return "$rc"
}

# --- Test 1: a compliant write-up passes ------------------------------------
cat > "$TMP/findings/clean.md" <<'MD'
# Cross-tenant order access

## Reproduction Steps

1. Replay the request below as tenant A.

```http
GET /api/orders/42 HTTP/1.1
Host: app.test
```

2. The response body contains tenant B data.

## Remediation

Scope the lookup to the caller's tenant before loading the order.
MD
hook "$TMP/findings/clean.md" || fail "a compliant write-up must pass: $HOOK_OUT"
pass "a compliant write-up passes"

# --- Test 2: a fence without a language is rejected -------------------------
cat > "$TMP/findings/no-lang.md" <<'MD'
# Missing language

## Reproduction Steps

1. Run the command below.

```
curl -sk https://app.test/api/orders/42
```

2. Note the cross-tenant response.
MD
if hook "$TMP/findings/no-lang.md"; then
    fail "a code fence without a language must be rejected"
fi
grep -q 'code fence without a language' <<<"$HOOK_OUT" \
    || fail "the message must name the missing language: $HOOK_OUT"
grep -q 'line 7' <<<"$HOOK_OUT" \
    || fail "the message must point at the offending fence line: $HOOK_OUT"
pass "a code fence without a language is rejected"

# --- Test 3: an indented fence is rejected ----------------------------------
printf '# Indented fence\n\n1. Run:\n\n   ```sh\n   id\n   ```\n\n2. Done.\n' \
    > "$TMP/findings/indented.md"
if hook "$TMP/findings/indented.md"; then
    fail "an indented code fence must be rejected"
fi
grep -q 'indented code fence' <<<"$HOOK_OUT" \
    || fail "the message must name the indentation: $HOOK_OUT"
pass "an indented code fence is rejected"

# --- Test 4: a tab-indented fence is rejected -------------------------------
printf '# Tabbed fence\n\n1. Run:\n\n\t```sh\n\tid\n\t```\n\n2. Done.\n' \
    > "$TMP/findings/tabbed.md"
if hook "$TMP/findings/tabbed.md"; then
    fail "a tab-indented code fence must be rejected"
fi
grep -q 'indented code fence' <<<"$HOOK_OUT" \
    || fail "the message must name the indentation: $HOOK_OUT"
pass "a tab-indented code fence is rejected"

# --- Test 5: the closing fence needs no language ----------------------------
# Covered implicitly by Test 1, asserted here on a fence-only file so a naive
# "every fence needs a language" implementation fails loudly.
printf '# Fence pair\n\n```json\n{"ok": true}\n```\n' > "$TMP/findings/pair.md"
hook "$TMP/findings/pair.md" || fail "a closing fence must not need a language: $HOOK_OUT"
pass "the closing fence needs no language"

# --- Test 6: working files stay out of scope --------------------------------
printf '# Journal\n\n```\nscratch notes\n```\n' > "$TMP/journal.md"
hook "$TMP/journal.md" || fail "journal.md is a working file and must stay exempt: $HOOK_OUT"
pass "working files stay out of scope"

# --- Test 7: the reference templates stay exempt ----------------------------
printf '# <Title>\n\n```\n<paste the request>\n```\n' > "$TMP/findings/_template.md"
hook "$TMP/findings/_template.md" || fail "_template.md must stay exempt: $HOOK_OUT"
pass "the reference templates stay exempt"

# --- Test 8: the rendered activity file is in scope -------------------------
printf '# Activity\n\n<!-- db:render findings -->\n<!-- /db:render -->\n\n```\nls -la\n```\n' \
    > "$TMP/engagement.md"
if hook "$TMP/engagement.md"; then
    fail "the db:render activity file must be linted too"
fi
pass "the rendered activity file is in scope"

# --- Test 9: hard-wrapped prose is still flagged (regression) ---------------
printf '# Hard wrap\n\n## Impact\n\nAn attacker with a customer account can read\norders belonging to any other tenant.\n' \
    > "$TMP/findings/wrapped.md"
if hook "$TMP/findings/wrapped.md"; then
    fail "hard-wrapped prose must still be rejected"
fi
grep -q 'lines 5-6' <<<"$HOOK_OUT" \
    || fail "the hard-wrap range must still be reported: $HOOK_OUT"
pass "hard-wrapped prose is still flagged"

# --- Test 10: prose inside a fenced block is not hard-wrap (regression) -----
cat > "$TMP/findings/fenced-prose.md" <<'MD'
# Fenced prose

## Reproduction Steps

1. Send:

```http
POST /api/orders HTTP/1.1
Host: app.test
Content-Type: application/json

{"tenant": "b"}
```

2. Observe the cross-tenant write.
MD
hook "$TMP/findings/fenced-prose.md" \
    || fail "multi-line content inside a fence must not count as hard-wrapped: $HOOK_OUT"
pass "prose inside a fenced block is not hard-wrap"

echo "All report-format tests passed."
