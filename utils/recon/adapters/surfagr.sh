#!/usr/bin/env bash
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB/paths.sh"; source "$LIB/manifest.sh"; source "$LIB/appid.sh"

run_surfagr() {   # echoes run id
  # NOTE: surfagr.sh also invokes run-screenshotter.sh internally (known coupling).
  local run raw; run="$(new_run)"; raw="$(surface_raw surfagr "$run")"
  mkdir -p "$raw"
  "$WORKER/surfagr.sh" "$(httpx_meta)" "$raw" >&2
  echo "$run"
}

# Pure-bash parse of "scheme://host[:port]/..." -> sets REPL_HOST, REPL_PORT
_parse_authority() {  # url
  local url="$1" scheme authority
  scheme="${url%%://*}"
  authority="${url#*://}"; authority="${authority%%/*}"
  REPL_HOST="${authority%%:*}"
  if [ "$authority" != "$REPL_HOST" ]; then REPL_PORT="${authority##*:}"
  elif [ "$scheme" = "https" ]; then REPL_PORT=443
  else REPL_PORT=80; fi
}

normalize_surfagr() {   # run id  -- fan-out promoter, enforces stable app_id (§5)
  local run raw d hosts best title ip ws status tech_csv tech_json hosts_json app_id
  run="$1"; raw="$(surface_raw surfagr "$run")"
  for d in "$raw"/targets/*/; do
    [ -d "$d" ] || continue
    hosts="${d%/}/hosts.txt"
    # representative host: first non-IP URL, else first URL (mirrors pipeline-recon BEST_HOST)
    best="$(grep -vE '^https?://([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?(/|$)' "$hosts" | head -n1)"
    [ -n "$best" ] || best="$(head -n1 "$hosts")"
    _parse_authority "$best"
    app_id="$(app_id_for "$REPL_HOST" "$REPL_PORT")"
    title="$(sed -n 's/^Title: //p' "${d%/}/info.txt" | head -n1)"
    ip="$(sed -n 's/^IP: //p' "${d%/}/info.txt" | head -n1)"
    ws="$(sed -n 's/^Webserver: //p' "${d%/}/info.txt" | head -n1)"
    status="$(sed -n 's/^Status-Code: //p' "${d%/}/info.txt" | head -n1)"
    tech_csv="$(sed -n 's/^Tech Stack: //p' "${d%/}/info.txt" | head -n1)"
    tech_json="$(printf '%s' "$tech_csv" | jq -R 'if . == "None detected" or . == "" then [] else split(", ") end')"
    hosts_json="$(jq -R . < "$hosts" | jq -s .)"
    mkdir -p "$(app_dir "$app_id")"
    jq -n \
      --arg app_id "$app_id" --arg host "$REPL_HOST" --arg port "$REPL_PORT" \
      --arg base_url "$best" --arg title "$title" --arg ip "$ip" \
      --arg webserver "$ws" --arg status "$status" \
      --argjson tech "$tech_json" --argjson cluster_hosts "$hosts_json" \
      '{app_id:$app_id, host:$host, port:$port, base_url:$base_url, title:$title,
        host_ip:$ip, webserver:$webserver, status_code:$status,
        tech:$tech, cluster_hosts:$cluster_hosts}' > "$(meta_json "$app_id")"
    manifest_append "$app_id" meta meta.json surfagr "att_surface/raw/surfagr/$run/targets/$(basename "${d%/}")/"
  done
}

main() { local run; run="$(run_surfagr)"; normalize_surfagr "$run"; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
