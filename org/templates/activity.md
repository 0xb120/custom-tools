# {{ACTIVITY_NAME}}

> Technical findings live in `findings/`; only selected report vulnerabilities in `vulnerabilities/` appear in this deliverable.

## Host inventory

Source of truth: `db/engagement.db` (`host` + `host_ip` + `host_segment`). The DHCP-stable name↔IP map is rendered by `bash db/render.sh`. See `PT_PLAYBOOK.md` § Engagement database for inventory commands.

<!-- db:render hosts -->

| name | dns | mac | current ip | past ips | segment |
| ---- | --- | --- | ---------- | -------- | ------- |
|      |     |     |            |          |         |

<!-- /db:render hosts -->

## Asset inventory

Source of truth: `db/engagement.db` (`asset` + `host` + `host_segment`). Rendered by `bash db/render.sh`; see `PT_PLAYBOOK.md` § Engagement database for inventory commands and saved queries.

<!-- db:render assets -->

### <segment>

| name | current ip | port | protocol | tls | version | technologies | access |
| ---- | ---------- | ---- | -------- | --- | ------- | ------------ | ------ |
|      |            |      |          |     |         |              |        |

<!-- /db:render assets -->

## Valid credentials

Source of truth: `db/engagement.db` (`credential` + `credential_asset`). Rendered by `bash db/render.sh`.

*[User List](<internal-cred-tracking-link>)*

<!-- db:render credentials -->

| Username | Password / Hash | Host | Current IP | Port | Role |
| -------- | --------------- | ---- | ---------- | ---- | ---- |
|          |                 |      |            |      |      |

<!-- /db:render credentials -->

## Vulnerabilities index

Source of truth: `db/engagement.db` (`vulnerabilities`). Only issues explicitly promoted with `db/ptctl.py vulnerability ...` are rendered. Finding files remain internal technical state under `findings/`; report prose lives in `vulnerabilities/<slug>.md`.

<!-- db:render vulnerabilities -->

| ID | Severity | Title | Status | Segment |
|----|----------|-------|--------|---------|

<!-- /db:render vulnerabilities -->


## Executive summary

<short narrative for the report; fill at engagement close>
