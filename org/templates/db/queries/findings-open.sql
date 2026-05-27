-- Open findings, severity-sorted.
.mode column
.headers on
SELECT f.slug,
       f.severity,
       f.title,
       COALESCE(s.name, '') AS segment
FROM finding f
LEFT JOIN segment s ON s.id = f.segment_id
WHERE f.status = 'open'
ORDER BY CASE f.severity
            WHEN 'CRITICAL'      THEN 1
            WHEN 'HIGH'          THEN 2
            WHEN 'MEDIUM'        THEN 3
            WHEN 'LOW'           THEN 4
            WHEN 'INFORMATIONAL' THEN 5
         END,
         f.id;
