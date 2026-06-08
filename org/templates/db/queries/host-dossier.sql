-- Host dossier: everything the DB knows about a machine, resolved from its
-- stable name, its dns, OR any IP it has ever held. Bind :host before reading.
--
-- An IP argument matches every machine that has EVER held it (current OR
-- retired). If an IP was recycled across hosts during the engagement, the
-- dossier may therefore span more than one machine — the `-- identity --`
-- section names each. Query by the stable name to scope to exactly one
-- machine. This is deliberate: a retired IP must still resolve to its old
-- machine so that machine's scan artifacts stay reachable (the point of the
-- host_ip ledger).
--
-- Standalone:
--   sqlite3 db/engagement.db ".param set :host 'DC01'" ".read db/queries/host-dossier.sql"
-- Or via the wrapper that also folds in journal history + raw scan hits:
--   bash db/whatweknow.sh DC01
.mode column
.headers on

-- The :host arg may be a name, a dns, or any historical IP. Every section below
-- resolves it to host id(s) with the same UNION subquery.
.print '-- identity --'
SELECT h.name,
       COALESCE(h.dns,  '') AS dns,
       COALESCE(h.mac,  '') AS mac,
       COALESCE(h.notes,'') AS notes,
       h.first_seen,
       h.last_seen
FROM host h
WHERE h.id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
);

.print ''
.print '-- ip history --'
SELECT hi.ip,
       CASE hi.current WHEN 1 THEN 'current' ELSE '' END AS state,
       hi.first_seen,
       hi.last_seen
FROM host_ip hi
WHERE hi.host_id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
)
ORDER BY hi.current DESC, hi.last_seen DESC;

.print ''
.print '-- assets --'
SELECT a.port,
       COALESCE(a.protocol, '')                                    AS protocol,
       CASE a.tls WHEN 1 THEN 'tls' WHEN 0 THEN '-' ELSE '' END     AS tls,
       COALESCE(a.version, '')                                      AS version,
       COALESCE(a.technologies, '')                                 AS technologies,
       COALESCE(a.access, '')                                       AS access,
       a.last_seen,
       COALESCE(a.notes, '')                                        AS notes
FROM asset a
WHERE a.host_id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
)
ORDER BY a.port;

.print ''
.print '-- segments --'
SELECT s.name AS segment, COALESCE(s.description, '') AS description
FROM segment s
JOIN host_segment hs ON hs.segment_id = s.id
WHERE hs.host_id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
)
ORDER BY s.name;

.print ''
.print '-- credentials --'
SELECT COALESCE(c.username, '')    AS username,
       COALESCE(c.secret, '')      AS secret,
       c.secret_type,
       COALESCE(c.role, '')        AS role,
       COALESCE(c.source, '')      AS source,
       a.port                      AS port,
       COALESCE(ca.verified_at,'') AS verified_at
FROM credential c
JOIN credential_asset ca ON ca.credential_id = c.id
JOIN asset a             ON a.id = ca.asset_id
WHERE a.host_id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
)
ORDER BY ca.verified_at, c.username;

.print ''
.print '-- findings --'
SELECT f.severity, f.status, f.slug, f.title, f.evidence_path
FROM finding f
JOIN finding_asset fa ON fa.finding_id = f.id
JOIN asset a          ON a.id = fa.asset_id
WHERE a.host_id IN (
    SELECT id      FROM host    WHERE name = :host OR dns = :host
    UNION
    SELECT host_id FROM host_ip WHERE ip = :host
)
ORDER BY CASE f.severity
            WHEN 'CRITICAL'      THEN 1
            WHEN 'HIGH'          THEN 2
            WHEN 'MEDIUM'        THEN 3
            WHEN 'LOW'           THEN 4
            WHEN 'INFORMATIONAL' THEN 5
         END, f.id;
