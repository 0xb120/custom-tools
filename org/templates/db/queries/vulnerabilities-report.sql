-- Explicit report allowlist, severity-sorted, with technical provenance.
.headers on
.mode column
SELECT 'V' || printf('%02d', v.id) AS id,
       v.severity,
       v.status,
       v.title,
       s.name AS segment,
       GROUP_CONCAT('F' || printf('%02d', vf.finding_id), ', ') AS source_findings,
       v.evidence_path
FROM vulnerabilities v
JOIN segment s ON s.id=v.segment_id
LEFT JOIN vulnerability_finding vf ON vf.vulnerability_id=v.id
GROUP BY v.id
ORDER BY CASE v.severity
           WHEN 'CRITICAL' THEN 1
           WHEN 'HIGH' THEN 2
           WHEN 'MEDIUM' THEN 3
           WHEN 'LOW' THEN 4
           ELSE 5
         END,
         v.id;
