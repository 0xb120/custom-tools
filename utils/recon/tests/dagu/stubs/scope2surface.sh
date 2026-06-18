#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"
mkdir -p "$(surface_dir)"
printf 'a.example.com\nb.example.com\n' > "$(subdomains)"
cat > "$(httpx_meta)" <<'JSON'
{"url":"https://a.example.com","host":"a.example.com","host_ip":"10.0.0.1","title":"App A","webserver":"nginx","content_length":1,"status_code":200,"tech":["React"]}
{"url":"https://b.example.com","host":"b.example.com","host_ip":"10.0.0.2","title":"App B","webserver":"envoy","content_length":2,"status_code":200,"tech":[]}
JSON
manifest_append _surface subdomains subdomains.txt stub-scope2surface stub
manifest_append _surface httpx_meta httpx_full_metadata.jsonl stub-scope2surface stub
