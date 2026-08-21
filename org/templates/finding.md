# <Title>

<!--
Reference template — `db/ptctl.py finding create` copies and initializes it.
- Do not create finding files or edit the metadata block by hand.
- Update canonical metadata with `db/ptctl.py finding update`.
- Evidence inside the managed markers is rendered from the evidence registry.
- Keep prose tight: no marketing, no CVSS narrative, no copy-pasted CWE blurbs.
-->

- **Vuln_ID**: `<finding_slug>`
- **Group key**: `<group_key>`
- **Severity**: `<CRITICAL | HIGH | MEDIUM | LOW | INFORMATIONAL>`
- **Status**: `<open | fixed | non-reproducible>`
- **Affected asset(s)**: `<host / URL / endpoint / parameter / binary — one per line if multiple>`
- **Related CWE(s)**: `<CWE-NNN: short name>`
- **Segment**: `<segment-name from AGENTS.md>`
- **Observation(s)**: `<O0001, O0002>`

## Impact

<Two or three lines, high level. What an attacker gains, on which asset, and the resulting business impact. No reproduction details here.>

## Description

<What the vulnerability is and why it exists. Identify the vulnerable component, the trust boundary crossed, and the root cause (missing check, wrong default, broken assumption). Reference code paths or request flows where useful.>

## Reproduction Steps

1. <Pre-condition — auth state, role, network position, required setup>.
2. <Action — exact request, payload, or command. Paste raw HTTP or shell, do not paraphrase.>
3. <Observation — what the server/system returned that proves the issue.>

<Repeat as needed. Steps must be deterministic: another tester following them must reach the same result.>

## Evidence

<!--
Evidence rule (doctor blocks the stop hook and fails --strict): every finding
must register at least one complete, unredacted HTTP request (kind=http-request)
— a real request confirmed working during the test, with no removed headers or
redacted fields, so the client can replay it at patch time. For a genuinely
non-HTTP finding, opt out with a no-http-request marker (see AGENTS.md).
-->
<!-- ptctl:evidence -->
_No registered evidence yet — use `ptctl.py observation evidence`._
<!-- /ptctl:evidence -->

## Remediation

<Concrete fix at the right layer (code / config / architecture). Prefer the minimal change that closes the root cause; mention compensating controls only if the primary fix is non-trivial. Avoid generic advice ("validate input") — say *what* to validate, *where*, and *against which allowlist*.>

## References

<!--
Rule (enforced by `db/ptctl.py doctor`; a warning normally, fatal under
--strict): list at least 3 external references below; every reference must be a
link (a URL, bare or Markdown). At least one must come from
cheatsheetseries.owasp.org or portswigger.net/web-security. Replace every
placeholder with a real link.
-->
- <cheatsheetseries.owasp.org cheat sheet for this vulnerability class — paste the full link>
- <portswigger.net/web-security topic that backs the technique — paste the full link>
- <vendor advisory / CVE / standards / research link>
