-- Asset count per segment — coarse coverage view.
.mode column
.headers on
SELECT s.name AS segment, COUNT(*) AS n_assets
FROM asset a
JOIN host h          ON h.id = a.host_id
JOIN host_segment hs ON hs.host_id = h.id
JOIN segment s       ON s.id = hs.segment_id
GROUP BY s.name
ORDER BY n_assets DESC;
