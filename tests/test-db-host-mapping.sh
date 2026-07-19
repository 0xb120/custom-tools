#!/usr/bin/env bash
# Tests for the host-identity DB model (org/templates/db/). Each section builds
# a throwaway DB or scaffolds a throwaway engagement under mktemp -d so the
# working tree stays clean. Style mirrors tests/test-newPT.sh.
set -eo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SCHEMA="$ROOT/org/templates/db/schema.sql"
NEWPT="$ROOT/org/newPT.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ===========================================================================
# Section A — schema (Task 1)
# ===========================================================================
db="$TMP/a.db"
sqlite3 "$db" < "$SCHEMA" || fail "schema.sql failed to apply"

have_table() { sqlite3 "$db" ".tables" | tr ' ' '\n' | grep -qx "$1"; }
have_table host         || fail "table 'host' missing"
have_table host_ip      || fail "table 'host_ip' missing"
have_table host_segment || fail "table 'host_segment' missing"
sqlite3 "$db" ".tables" | tr ' ' '\n' | grep -qx asset_segment && \
    fail "table 'asset_segment' should be gone"
pass "host / host_ip / host_segment exist; asset_segment removed"

# asset has host_id and no longer has a host column
cols="$(sqlite3 "$db" "SELECT name FROM pragma_table_info('asset');")"
echo "$cols" | grep -qx host_id || fail "asset.host_id missing"
echo "$cols" | grep -qx host    && fail "asset.host should be removed"
pass "asset reworked to host_id"

# A host can be inserted, renamed in place, and keeps its id (stable identity)
sqlite3 "$db" "INSERT INTO host (name) VALUES ('10.0.0.5');"
hid="$(sqlite3 "$db" "SELECT id FROM host WHERE name='10.0.0.5';")"
sqlite3 "$db" "UPDATE host SET name='DC01' WHERE id=$hid;"
[ "$(sqlite3 "$db" "SELECT id FROM host WHERE name='DC01';")" = "$hid" ] || \
    fail "host id changed on rename — identity not stable"
pass "host renamed in place, identity preserved"

# host_ip ledger: one current IP per host (partial unique index)
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid, '10.0.0.5');"
if sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid, '10.0.0.9');" 2>/dev/null; then
    fail "two current IPs for one host should violate idx_host_ip_one_current"
fi
pass "at most one current IP per host enforced"

# Retiring the old lease lets a new current IP land
sqlite3 "$db" "UPDATE host_ip SET current=0 WHERE host_id=$hid AND ip='10.0.0.5';"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid, '10.0.0.9');" || \
    fail "could not record new current IP after retiring old lease"
pass "lease rotation works"

# one current owner per IP across hosts
sqlite3 "$db" "INSERT INTO host (name) VALUES ('PC02');"
hid2="$(sqlite3 "$db" "SELECT id FROM host WHERE name='PC02';")"
if sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES ($hid2, '10.0.0.9');" 2>/dev/null; then
    fail "two hosts currently owning 10.0.0.9 should violate idx_host_ip_one_owner"
fi
pass "at most one current owner per IP enforced"

echo "Section A passed."

# ===========================================================================
# Section B — host-dossier.sql resolves by name AND by historical IP (Task 2)
# ===========================================================================
DOSSIER="$ROOT/org/templates/db/queries/host-dossier.sql"
db="$TMP/b.db"
sqlite3 "$db" < "$SCHEMA"
sqlite3 "$db" "INSERT INTO segment (name) VALUES ('server');"
sqlite3 "$db" "INSERT INTO host (name, dns) VALUES ('DC01', 'dc01.corp.local');"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1, '10.0.0.5', 0);"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1, '10.0.0.9', 1);"
sqlite3 "$db" "INSERT INTO host_segment (host_id, segment_id) VALUES (1, 1);"
sqlite3 "$db" "INSERT INTO asset (host_id, port, protocol) VALUES (1, 445, 'smb');"

out_by_name="$(sqlite3 "$db" ".param set :host 'DC01'"      ".read $DOSSIER")"
out_by_oldip="$(sqlite3 "$db" ".param set :host '10.0.0.5'" ".read $DOSSIER")"

echo "$out_by_name"  | grep -q "dc01.corp.local" || fail "dossier-by-name should show dns"
echo "$out_by_name"  | grep -qw "445"             || fail "dossier-by-name should list the smb asset"
echo "$out_by_name"  | grep -q "10.0.0.5"         || fail "dossier-by-name should show historical IP 10.0.0.5"
echo "$out_by_oldip" | grep -q "DC01"             || fail "dossier resolved by an OLD ip should still find DC01"
pass "host-dossier resolves by name and by historical IP, shows IP history + assets"

# Recycled IP: 10.0.0.5 is retired on DC01 but later becomes PC02's CURRENT
# lease — a constraint-legal DHCP reuse (idx_host_ip_one_owner only forbids two
# CURRENT owners). Querying that IP is ambiguous, so the dossier intentionally
# spans both machines; the identity section names each.
sqlite3 "$db" "INSERT INTO host (name) VALUES ('PC02');"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (2, '10.0.0.5', 1);"
out_recycled="$(sqlite3 "$db" ".param set :host '10.0.0.5'" ".read $DOSSIER")"
echo "$out_recycled" | grep -q "DC01" || fail "recycled-IP dossier should still include the retired owner DC01"
echo "$out_recycled" | grep -q "PC02" || fail "recycled-IP dossier should include the current owner PC02"
pass "recycled IP resolves to both retired and current owners (documented multi-host behavior)"

# ===========================================================================
# Section C — saved queries run on the new schema (Task 3)
# ===========================================================================
QDIR="$ROOT/org/templates/db/queries"
db="$TMP/c.db"
sqlite3 "$db" < "$SCHEMA"
sqlite3 "$db" "INSERT INTO segment (name) VALUES ('server');"
sqlite3 "$db" "INSERT INTO host (name) VALUES ('DC01');"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip) VALUES (1, '10.0.0.9');"
sqlite3 "$db" "INSERT INTO host_segment (host_id, segment_id) VALUES (1, 1);"
sqlite3 "$db" "INSERT INTO asset (host_id, port, protocol) VALUES (1, 445, 'smb');"
sqlite3 "$db" "INSERT INTO asset (host_id, port, protocol) VALUES (1, 3389, 'rdp');"
sqlite3 "$db" "INSERT INTO credential (username, secret, secret_type) VALUES ('admin','x','password');"
sqlite3 "$db" "INSERT INTO credential_asset (credential_id, asset_id, verified_at) VALUES (1, 1, CURRENT_TIMESTAMP);"
sqlite3 "$db" "INSERT INTO credential_asset (credential_id, asset_id, verified_at) VALUES (1, 2, CURRENT_TIMESTAMP);"

for q in assets-by-segment assets-no-access creds-multi-host findings-open hosts; do
    sqlite3 "$db" < "$QDIR/$q.sql" >/dev/null 2>"$TMP/q.err" || \
        { echo "--- $q stderr ---" >&2; cat "$TMP/q.err" >&2; fail "$q.sql failed on new schema"; }
done
pass "all saved queries run clean on the new schema"

# assets-by-segment counts the server segment's assets
sqlite3 "$db" < "$QDIR/assets-by-segment.sql" | grep -q "server" || \
    fail "assets-by-segment should report the 'server' segment"
# hosts map shows the name and its current IP
hosts_out="$(sqlite3 "$db" < "$QDIR/hosts.sql")"
echo "$hosts_out" | grep -q "DC01"     || fail "hosts.sql should list DC01"
echo "$hosts_out" | grep -q "10.0.0.9" || fail "hosts.sql should show current IP 10.0.0.9"
# creds-multi-host concatenates by host name, not by a (gone) asset.host column
sqlite3 "$db" < "$QDIR/creds-multi-host.sql" | grep -q "DC01:445" || \
    fail "creds-multi-host should group by host name (DC01:445)"
pass "queries reflect host joins (segment count, host map, cred pivots)"

# ===========================================================================
# Section D — whatweknow.sh folds in scans captured under an OLD IP (Task 4)
# ===========================================================================
cd "$TMP"
rm -rf eng-d
bash "$NEWPT" none eng-d >/dev/null || fail "scaffold eng-d failed"
db="eng-d/db/engagement.db"
sqlite3 "$db" "INSERT INTO host (name, dns) VALUES ('DC01', 'dc01.corp.local');"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1, '10.0.0.5', 0);"  # old DHCP lease
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1, '10.0.0.9', 1);"  # current lease
# a scan captured yesterday, labelled by the OLD ip
mkdir -p eng-d/scans/nmap
printf '10.0.0.5 445/tcp open microsoft-ds\n' > eng-d/scans/nmap/hosts.txt
# a journal entry tagged by the current name
printf '## 2026-06-08\n#observation @DC01 smb signing disabled\n' > eng-d/journal.md

out="$(bash eng-d/db/whatweknow.sh DC01)" || fail "whatweknow.sh DC01 exited non-zero"
echo "$out" | grep -q "dc01.corp.local"            || fail "dossier section missing (DB view)"
echo "$out" | grep -q "10.0.0.5"                    || fail "should surface the OLD ip from the ledger"
echo "$out" | grep -q "microsoft-ds"                || fail "should fold in the scan captured under the OLD ip"
echo "$out" | grep -q "smb signing disabled"        || fail "should fold in the @DC01 journal entry"
pass "whatweknow.sh DC01 folds DB + journal + scans across every historical IP"

# Injection guard: a bogus arg with shell/SQL metachars is rejected, not run
if bash eng-d/db/whatweknow.sh "DC01; rm -rf /" 2>/tmp/wwk.err; then
    fail "whatweknow.sh should reject an arg with invalid characters"
fi
grep -q "invalid host" /tmp/wwk.err || fail "stderr should explain the invalid-host rejection"
pass "whatweknow.sh rejects args outside the host charset"
rm -f /tmp/wwk.err

# Regression (Task 4 review): a large scan file must not abort the dossier via
# grep|head SIGPIPE under pipefail, and a leading-dash token (host name/dns are
# free TEXT) must not be misparsed as a grep option. Both truncated/aborted the
# dossier before the `--` and `|| true` fixes.
cd "$TMP"
rm -rf eng-d2
bash "$NEWPT" none eng-d2 >/dev/null || fail "scaffold eng-d2 failed"
db="eng-d2/db/engagement.db"
sqlite3 "$db" "INSERT INTO host (name, dns) VALUES ('DC01', '-weird.corp');"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1, '10.0.0.5', 1);"
mkdir -p eng-d2/scans/nmap
seq 1 5000 | sed 's/^/10.0.0.5 port /' > eng-d2/scans/nmap/big.txt   # >64KB of matching lines
out2="$(bash eng-d2/db/whatweknow.sh DC01)" || fail "whatweknow.sh aborted on a large scan file / leading-dash token"
echo "$out2" | grep -q "RAW SCANS" || fail "dossier should still reach the RAW SCANS section"
pass "whatweknow.sh survives large scan files and leading-dash tokens"

# ===========================================================================
# Section E — render.sh emits the hosts map + host-keyed asset/cred tables (Task 5)
# ===========================================================================
cd "$TMP"
rm -rf eng-e
bash "$NEWPT" none eng-e >/dev/null || fail "scaffold eng-e failed"
db="eng-e/db/engagement.db"
sqlite3 "$db" "INSERT INTO segment (name) VALUES ('server');"
sqlite3 "$db" "INSERT INTO host (name, dns) VALUES ('DC01','dc01.corp.local');"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1,'10.0.0.5',0);"
sqlite3 "$db" "INSERT INTO host_ip (host_id, ip, current) VALUES (1,'10.0.0.9',1);"
sqlite3 "$db" "INSERT INTO host_segment (host_id, segment_id) VALUES (1,1);"
sqlite3 "$db" "INSERT INTO asset (host_id, port, protocol) VALUES (1,445,'smb');"
sqlite3 "$db" "INSERT INTO credential (username, secret, secret_type) VALUES ('admin','x','password');"
sqlite3 "$db" "INSERT INTO credential_asset (credential_id, asset_id, verified_at) VALUES (1,1,CURRENT_TIMESTAMP);"

bash eng-e/db/render.sh >/dev/null || fail "render.sh failed"
md="eng-e/eng-e.md"
# hosts map block rendered with name, current + past IP
awk '/<!-- db:render hosts -->/{f=1} f; /<!-- \/db:render hosts -->/{f=0}' "$md" > "$TMP/hosts.block"
grep -q "DC01"     "$TMP/hosts.block" || fail "hosts block should list DC01"
grep -q "10.0.0.9" "$TMP/hosts.block" || fail "hosts block should show current IP"
grep -q "10.0.0.5" "$TMP/hosts.block" || fail "hosts block should show past IP"
# assets block keyed by host name + current IP
awk '/<!-- db:render assets -->/{f=1} f; /<!-- \/db:render assets -->/{f=0}' "$md" > "$TMP/assets.block"
grep -q "DC01" "$TMP/assets.block" || fail "assets block should show host name DC01"
grep -q "445"  "$TMP/assets.block" || fail "assets block should list port 445"
pass "render.sh emits hosts map + host-keyed asset table"

# ===========================================================================
# Section F — AGENTS.md docs describe the host model, not the dropped one (Task 6)
# ===========================================================================
AGENT="$ROOT/org/templates/AGENTS.md"
grep -q "asset_segment" "$AGENT" && fail "AGENTS.md still references the removed asset_segment table"
grep -qE "INSERT INTO host\b"     "$AGENT" || fail "AGENTS.md should document INSERT INTO host"
grep -q "host_ip"                  "$AGENT" || fail "AGENTS.md should document the host_ip ledger"
grep -q "host_segment"             "$AGENT" || fail "AGENTS.md should document host_segment"
grep -q "whatweknow.sh"            "$AGENT" || fail "AGENTS.md should keep the whatweknow.sh reference"
grep -q "target by name"           "$AGENT" || fail "AGENTS.md should tell the model to prefer name over IP for scans/invocations"
pass "AGENTS.md documents the host-identity model"

# ===========================================================================
# Section G — the documented "Common writes" snippets execute and link rows
# (regression guard for last_insert_rowid() being 0 across separate sqlite3
# processes — it silently produced host_id=0 / credential_id=0 orphans). (Task 6)
# ===========================================================================
cd "$TMP"
rm -rf eng-g
bash "$NEWPT" none eng-g >/dev/null || fail "scaffold eng-g failed"
AGENT="$ROOT/org/templates/AGENTS.md"
# Extract the bash code fences in the "Common writes" subsection.
awk '/\*\*Common writes\*\*/{insec=1}
     /\*\*Common reads\*\*/{insec=0}
     insec && /^```bash$/{inblk=1; next}
     insec && /^```$/{inblk=0}
     insec && inblk{print}' "$AGENT" > "$TMP/writes.sh"
[ -s "$TMP/writes.sh" ] || fail "could not extract Common writes snippets from AGENTS.md"
( cd eng-g && bash -e "$TMP/writes.sh" ) || fail "documented Common writes snippets errored when executed"
gdb="eng-g/db/engagement.db"
[ "$(sqlite3 "$gdb" "SELECT COUNT(*) FROM host_ip WHERE host_id NOT IN (SELECT id FROM host);")" = 0 ] \
    || fail "host_ip has rows pointing at a non-existent host (last_insert_rowid bug)"
[ "$(sqlite3 "$gdb" "SELECT COUNT(*) FROM credential_asset WHERE credential_id NOT IN (SELECT id FROM credential);")" = 0 ] \
    || fail "credential_asset has rows pointing at a non-existent credential (last_insert_rowid bug)"
[ "$(sqlite3 "$gdb" "SELECT COUNT(*) FROM asset a JOIN host h ON h.id=a.host_id WHERE h.name='DC01' AND a.port=445;")" = 1 ] \
    || fail "expected the documented DC01:445 asset to exist"
[ "$(sqlite3 "$gdb" "SELECT COUNT(*) FROM credential_asset;")" -ge 1 ] \
    || fail "expected at least one credential linked to an asset"
pass "AGENTS.md Common writes snippets execute and link rows correctly (no last_insert_rowid orphans)"

echo "All tests passed."
