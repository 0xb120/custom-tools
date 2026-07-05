# Single source of truth for every path in the contract. Requires $BASE.
#
# Engagement layout (root = $BASE, scaffolded by the recon DAG):
#   scope.txt                                              # input scope (copied at scaffold)
#   scope/{scope_init,scope_urls,scope_dns,scope_ip}.txt   # scope2surface expansion
#   scans/                                                 # surface artifacts + per-target dirs
#     subdomains.txt  httpx_full_metadata.jsonl  manifest.jsonl
#     findings/takeovers_scope.jsonl
#     raw/<tool>/<run>/                                    # surface-level raw tool output
#     <app_id>/                                            # per-target workspace (see below)
#   poc/  wl/  tmp/  logs/                                 # engagement scaffolding

# scope expansion (scope2surface worker promotes these out of raw/)
scope_dir()      { echo "$BASE/scope"; }
scope_file()     { echo "$(scope_dir)/$1.txt"; }          # scope_init|scope_urls|scope_dns|scope_ip

# scope-level surface artifacts — live at the scans/ root, beside the per-target dirs
surface_dir()    { echo "$BASE/scans"; }
subdomains()     { echo "$(surface_dir)/subdomains.txt"; }
httpx_meta()     { echo "$(surface_dir)/httpx_full_metadata.jsonl"; }
scope_findings() { echo "$(surface_dir)/findings/takeovers_scope.jsonl"; }
surface_raw()    { echo "$(surface_dir)/raw/$1/$2"; }      # tool run

# per-app ($1 = app_id) — workspace lives under scans/<app_id>/
app_dir()        { echo "$(surface_dir)/$1"; }
meta_json()      { echo "$(app_dir "$1")/meta.json"; }
endpoints()      { echo "$(app_dir "$1")/endpoints.txt"; }
subs()           { echo "$(app_dir "$1")/subs.txt"; }
screenshot()     { echo "$(app_dir "$1")/screenshot.png"; }
takeover()       { echo "$(app_dir "$1")/findings/takeover.txt"; }
raw_dir()        { echo "$(app_dir "$1")/raw/$2/$3"; }     # app_id tool run

# manifest file selector: real app_id -> per-app manifest; _surface -> surface manifest
manifest_path()  {
  if [ "$1" = "_surface" ]; then echo "$(surface_dir)/manifest.jsonl"
  else echo "$(app_dir "$1")/manifest.jsonl"; fi
}

# common
new_run()        { date -u +%Y%m%dT%H%M%SZ; }

# workspace enumeration — single source of truth for "which app_ids exist".
# A per-target dir is named by a 12-char app_id hash (sha1(host:port)[:12], see appid.sh);
# the strict 12-hex filter excludes the surface-level siblings under scans/ (raw/, findings/).
app_ids() {
  local d b
  for d in "$BASE"/scans/*/; do
    [ -d "$d" ] || continue
    b="$(basename "$d")"
    case "$b" in *[!0-9a-f]*) continue ;; esac
    [ "${#b}" -eq 12 ] && echo "$b"
  done
}
app_ids_json() { app_ids | jq -R . | jq -s -c .; }   # ["id1","id2"]  (or []  when empty)
