# {{ACTIVITY_NAME}}

> Per-finding write-ups live in `findings/<finding_slug>.md`. This file is the index plus the executive narrative for the deliverable.

## Host inventory

Source of truth: `db/engagement.db` (`host` + `host_ip` + `host_segment`). The DHCP-stable name↔IP map — rendered by `bash db/render.sh`. See `AGENT.md` § Engagement database.

<!-- db:render hosts -->

| name | dns | mac | current ip | past ips | segment |
| ---- | --- | --- | ---------- | -------- | ------- |
|      |     |     |            |          |         |

<!-- /db:render hosts -->

## Asset inventory

Source of truth: `db/engagement.db` (`asset` + `host` + `host_segment`). Rendered by `bash db/render.sh` — see `AGENT.md` § Engagement database for write/read snippets.

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

## Findings index

Source of truth: `db/engagement.db` (`finding`). Rendered by `bash db/render.sh`. Per-finding prose stays in `findings/<finding_slug>.md`.

<!-- db:render findings -->

| ID | Severity | Title | Status | Segment |
|----|----------|-------|--------|---------|

<!-- /db:render findings -->


## Executive summary

<short narrative for the report; fill at engagement close>
