-- Assets with no recorded access yet — what's still to crack / vuln-hunt.
.mode column
.headers on
SELECT h.name AS host,
       (SELECT ip FROM host_ip WHERE host_id = h.id AND current = 1) AS current_ip,
       a.port, a.protocol, a.version,
       s.name AS segment
FROM asset a
JOIN host h           ON h.id = a.host_id
LEFT JOIN host_segment hs ON hs.host_id = h.id
LEFT JOIN segment s       ON s.id = hs.segment_id
WHERE a.access IS NULL OR a.access = ''
ORDER BY s.name, h.name, a.port;
