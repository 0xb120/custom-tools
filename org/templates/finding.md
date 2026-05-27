# <Title>

<!--
Reference template — copy to `findings/<finding_slug>.md` and fill in every field.
- `<finding_slug>` is short-kebab-case and shared with `poc/<finding_slug>/`.
- Once filled, add a row to the findings index in `<activity_name>.md`.
- Keep prose tight: no marketing, no CVSS narrative, no copy-pasted CWE blurbs.
-->

- **Vuln_ID**: `<finding_slug>`
- **Severity**: `<CRITICAL | HIGH | MEDIUM | LOW | INFORMATIONAL>`
- **Status**: `<open | fixed | non-reproducible>`
- **Affected asset(s)**: `<host / URL / endpoint / parameter / binary — one per line if multiple>`
- **Related CWE(s)**: `<CWE-NNN: short name>`
- **Segment**: `<segment-name from AGENT.md>`

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

- `poc/<finding_slug>/<finding_slug>_01.png` — <what it shows>
- `poc/<finding_slug>/req_01.http` / `res_01.http` — <what exchange it captures>
- `poc/<finding_slug>/repro.sh` — <if a script is needed to reproduce>

## Remediation

<Concrete fix at the right layer (code / config / architecture). Prefer the minimal change that closes the root cause; mention compensating controls only if the primary fix is non-trivial. Avoid generic advice ("validate input") — say *what* to validate, *where*, and *against which allowlist*.>

## References

- <Vendor advisory / CVE / standards link>
- <OWASP / PortSwigger / research write-up that backs the technique>
