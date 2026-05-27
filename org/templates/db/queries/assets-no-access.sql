-- Assets with no recorded access yet — what's still to crack / vuln-hunt.
.mode column
.headers on
SELECT a.host, a.port, a.protocol, a.version, s.name AS segment
FROM asset a
LEFT JOIN asset_segment ass ON ass.asset_id = a.id
LEFT JOIN segment s         ON s.id = ass.segment_id
WHERE a.access IS NULL OR a.access = ''
ORDER BY s.name, a.host, a.port;
