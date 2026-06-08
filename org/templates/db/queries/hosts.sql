-- Host map: every machine with its current IP, the IPs it has previously held,
-- and the segment(s) it sits in. The DHCP-stable name↔IP view.
.mode column
.headers on
SELECT h.name,
       COALESCE(h.dns, '') AS dns,
       COALESCE(h.mac, '') AS mac,
       COALESCE((SELECT ip FROM host_ip WHERE host_id = h.id AND current = 1), '') AS current_ip,
       COALESCE((SELECT GROUP_CONCAT(ip, ', ') FROM host_ip WHERE host_id = h.id AND current = 0), '') AS past_ips,
       COALESCE((SELECT GROUP_CONCAT(s.name, ', ')
                 FROM host_segment hs JOIN segment s ON s.id = hs.segment_id
                 WHERE hs.host_id = h.id), '') AS segments
FROM host h
ORDER BY h.name;
