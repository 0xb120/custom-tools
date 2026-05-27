-- Asset count per segment — coarse coverage view.
.mode column
.headers on
SELECT s.name AS segment, COUNT(*) AS n_assets
FROM asset a
JOIN asset_segment ass ON ass.asset_id = a.id
JOIN segment s         ON s.id = ass.segment_id
GROUP BY s.name
ORDER BY n_assets DESC;
