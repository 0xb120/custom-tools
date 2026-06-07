-- Host dossier: everything the DB knows about one host, across all its ports —
-- the asset row(s), the segments it sits in, credentials verified against it,
-- and findings that touch it. Bound the :host parameter before reading.
--
-- Standalone:
--   sqlite3 db/engagement.db ".param set :host '10.0.0.5'" ".read db/queries/host-dossier.sql"
-- Or via the wrapper that also folds in journal history + raw scan hits:
--   bash db/whatweknow.sh 10.0.0.5
.mode column
.headers on

.print '-- assets --'
SELECT a.port,
       COALESCE(a.protocol, '')                                   AS protocol,
       CASE a.tls WHEN 1 THEN 'tls' WHEN 0 THEN '-' ELSE '' END    AS tls,
       COALESCE(a.version, '')                                     AS version,
       COALESCE(a.technologies, '')                                AS technologies,
       COALESCE(a.access, '')                                      AS access,
       a.last_seen,
       COALESCE(a.notes, '')                                       AS notes
FROM asset a
WHERE a.host = :host
ORDER BY a.port;

.print ''
.print '-- segments --'
SELECT s.name AS segment, COALESCE(s.description, '') AS description
FROM segment s
JOIN asset_segment ass ON ass.segment_id = s.id
JOIN asset a           ON a.id = ass.asset_id
WHERE a.host = :host
GROUP BY s.name, s.description
ORDER BY s.name;

.print ''
.print '-- credentials --'
SELECT COALESCE(c.username, '')    AS username,
       COALESCE(c.secret, '')      AS secret,
       c.secret_type,
       COALESCE(c.role, '')        AS role,
       COALESCE(c.source, '')      AS source,
       COALESCE(ca.verified_at,'') AS verified_at
FROM credential c
JOIN credential_asset ca ON ca.credential_id = c.id
JOIN asset a             ON a.id = ca.asset_id
WHERE a.host = :host
ORDER BY ca.verified_at, c.username;

.print ''
.print '-- findings --'
SELECT f.severity, f.status, f.slug, f.title, f.evidence_path
FROM finding f
JOIN finding_asset fa ON fa.finding_id = f.id
JOIN asset a          ON a.id = fa.asset_id
WHERE a.host = :host
ORDER BY CASE f.severity
            WHEN 'CRITICAL'      THEN 1
            WHEN 'HIGH'          THEN 2
            WHEN 'MEDIUM'        THEN 3
            WHEN 'LOW'           THEN 4
            WHEN 'INFORMATIONAL' THEN 5
         END, f.id;
