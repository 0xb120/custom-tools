-- Credentials verified on more than one asset — high-value pivots.
.mode column
.headers on
SELECT c.username,
       c.secret,
       c.secret_type,
       COUNT(*) AS n_assets,
       GROUP_CONCAT(a.host || ':' || a.port, ', ') AS hosts
FROM credential c
JOIN credential_asset ca ON ca.credential_id = c.id
JOIN asset a             ON a.id = ca.asset_id
WHERE ca.verified_at IS NOT NULL
GROUP BY c.id
HAVING n_assets > 1
ORDER BY n_assets DESC;
