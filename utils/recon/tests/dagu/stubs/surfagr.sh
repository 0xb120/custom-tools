#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../lib" && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"; source "$LIB/appid.sh"
[ -f "$(httpx_meta)" ] || { echo "stub surfagr: missing httpx_meta input" >&2; exit 1; }
while read -r line; do
  [ -n "$line" ] || continue
  host="$(jq -r .host <<<"$line")"; url="$(jq -r .url <<<"$line")"
  title="$(jq -r .title <<<"$line")"; ip="$(jq -r .host_ip <<<"$line")"
  port=443; app_id="$(app_id_for "$host" "$port")"
  mkdir -p "$(app_dir "$app_id")"
  jq -n --arg app_id "$app_id" --arg host "$host" --arg port "$port" \
        --arg base_url "$url" --arg title "$title" --arg ip "$ip" \
    '{app_id:$app_id,host:$host,port:$port,base_url:$base_url,title:$title,
      host_ip:$ip,webserver:"stub",status_code:"200",tech:[],cluster_hosts:[$base_url]}' \
    > "$(meta_json "$app_id")"
  manifest_append "$app_id" meta meta.json stub-surfagr stub
done < "$(httpx_meta)"
