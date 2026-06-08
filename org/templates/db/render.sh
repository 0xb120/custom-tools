#!/bin/bash
# Regenerate the asset / credentials / findings tables in <activity>.md from
# db/engagement.db. Replaces only the content between matching marker pairs:
#   <!-- db:render <name> -->  ...  <!-- /db:render <name> -->
# Everything outside the markers is preserved.
#
# Run from anywhere — paths resolve relative to this script's location.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
activity_root="$(cd "$script_dir/.." && pwd)"
db="$script_dir/engagement.db"

[ -f "$db" ] || { echo "ERROR: $db not found — run schema.sql first" >&2; exit 1; }

# Locate <activity>.md at the engagement root. Identify it by content, not by
# folder name: it's the only root-level Markdown file carrying the db:render
# markers. (Deriving the name from `basename "$activity_root"` breaks inside the
# devcontainer, where the folder is bind-mounted at /workspace and basename
# would wrongly yield "workspace" instead of the real engagement name.)
marker='<!-- db:render assets -->'
activity_md=""
for f in "$activity_root"/*.md; do
    [ -f "$f" ] || continue                 # literal glob when no .md files exist
    grep -qF "$marker" "$f" || continue
    if [ -n "$activity_md" ]; then
        echo "ERROR: multiple root-level .md files carry the '$marker' marker:" >&2
        printf '         %s\n         %s\n' "$activity_md" "$f" >&2
        echo "       Cannot decide which is the activity file." >&2
        exit 1
    fi
    activity_md="$f"
done
[ -n "$activity_md" ] || {
    echo "ERROR: no <activity>.md carrying the '$marker' marker found in $activity_root" >&2
    exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ---------------------------------------------------------------------------
# Build the three rendered blocks as standalone files under $tmpdir.
# ---------------------------------------------------------------------------

hosts_md="$tmpdir/hosts.md"
echo "" > "$hosts_md"
sqlite3 "$db" -markdown <<'SQL' >> "$hosts_md"
SELECT h.name AS "name",
       COALESCE(h.dns, '') AS "dns",
       COALESCE(h.mac, '') AS "mac",
       COALESCE((SELECT ip FROM host_ip WHERE host_id = h.id AND current = 1), '') AS "current ip",
       COALESCE((SELECT GROUP_CONCAT(ip, ', ') FROM host_ip WHERE host_id = h.id AND current = 0), '') AS "past ips",
       COALESCE((SELECT GROUP_CONCAT(s.name, ', ')
                 FROM host_segment hs JOIN segment s ON s.id = hs.segment_id
                 WHERE hs.host_id = h.id), '') AS "segment"
FROM host h
ORDER BY h.name;
SQL
echo "" >> "$hosts_md"
[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM host;")" -gt 0 ] || \
    printf '\n_No hosts recorded yet — see AGENT.md § Engagement database for write snippets._\n' > "$hosts_md"

assets_md="$tmpdir/assets.md"
: > "$assets_md"
# One sub-table per segment that has at least one asset (via host_segment).
sqlite3 "$db" "SELECT name FROM segment WHERE id IN (SELECT segment_id FROM host_segment) ORDER BY name;" |
while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    {
        echo ""
        echo "### $seg"
        echo ""
        sqlite3 "$db" -markdown <<SQL
SELECT h.name AS "name",
       COALESCE((SELECT ip FROM host_ip WHERE host_id = h.id AND current = 1), '') AS "current ip",
       a.port AS port,
       COALESCE(a.protocol, '') AS protocol,
       CASE a.tls WHEN 1 THEN 'True' WHEN 0 THEN 'False' ELSE '' END AS tls,
       COALESCE(a.version, '') AS version,
       COALESCE(a.technologies, '') AS technologies,
       COALESCE(a.access, '') AS access
FROM asset a
JOIN host h          ON h.id = a.host_id
JOIN host_segment hs ON hs.host_id = h.id
JOIN segment s       ON s.id = hs.segment_id
WHERE s.name = '$seg'
ORDER BY h.name, a.port;
SQL
    } >> "$assets_md"
done
[ -s "$assets_md" ] || echo $'\n_No assets recorded yet — see AGENT.md § Engagement database for write snippets._' > "$assets_md"

credentials_md="$tmpdir/credentials.md"
echo "" > "$credentials_md"
sqlite3 "$db" -markdown <<'SQL' >> "$credentials_md"
SELECT COALESCE(c.username, '') AS Username,
       COALESCE(c.secret, '')   AS "Password / Hash",
       COALESCE(h.name, '')     AS Host,
       COALESCE((SELECT ip FROM host_ip WHERE host_id = h.id AND current = 1), '') AS "Current IP",
       COALESCE(a.port, '')     AS Port,
       COALESCE(c.role, '')     AS Role
FROM credential c
LEFT JOIN credential_asset ca ON ca.credential_id = c.id
LEFT JOIN asset a              ON a.id = ca.asset_id
LEFT JOIN host h               ON h.id = a.host_id
ORDER BY c.username, h.name, a.port;
SQL
echo "" >> "$credentials_md"

findings_md="$tmpdir/findings.md"
echo "" > "$findings_md"
sqlite3 "$db" -markdown <<'SQL' >> "$findings_md"
SELECT 'F' || printf('%02d', f.id) AS ID,
       f.severity                  AS Severity,
       '[' || f.title || '](' || COALESCE(f.evidence_path, 'findings/' || f.slug || '.md') || ')' AS Title,
       f.status                    AS Status,
       COALESCE(s.name, '')        AS Segment
FROM finding f
LEFT JOIN segment s ON s.id = f.segment_id
ORDER BY CASE f.severity
            WHEN 'CRITICAL'      THEN 1
            WHEN 'HIGH'          THEN 2
            WHEN 'MEDIUM'        THEN 3
            WHEN 'LOW'           THEN 4
            WHEN 'INFORMATIONAL' THEN 5
         END,
         f.id;
SQL
echo "" >> "$findings_md"

# ---------------------------------------------------------------------------
# Splice each block into <activity>.md between its marker pair.
# ---------------------------------------------------------------------------

replace_block() {
    local block="$1" content_file="$2" target="$3"
    awk -v block="$block" -v cf="$content_file" '
        $0 == "<!-- db:render " block " -->" {
            print
            while ((getline line < cf) > 0) print line
            close(cf)
            in_block = 1
            next
        }
        $0 == "<!-- /db:render " block " -->" {
            in_block = 0
            print
            next
        }
        !in_block { print }
    ' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
}

replace_block hosts       "$hosts_md"       "$activity_md"
replace_block assets      "$assets_md"      "$activity_md"
replace_block credentials "$credentials_md" "$activity_md"
replace_block findings    "$findings_md"    "$activity_md"

echo "Rendered $activity_md from $db"
