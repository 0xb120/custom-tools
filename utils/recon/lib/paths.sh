# Single source of truth for every path in the contract. Requires $BASE.
# scope-level
surface_dir()    { echo "$BASE/att_surface"; }
subdomains()     { echo "$(surface_dir)/subdomains.txt"; }
httpx_meta()     { echo "$(surface_dir)/httpx_full_metadata.jsonl"; }
scope_findings() { echo "$(surface_dir)/findings/takeovers_scope.jsonl"; }
surface_raw()    { echo "$(surface_dir)/raw/$1/$2"; }      # tool run

# per-app ($1 = app_id)
app_dir()        { echo "$BASE/targets/$1"; }
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

# workspace enumeration — single source of truth for "which app_ids exist"
app_ids()      { for d in "$BASE"/targets/*/; do [ -d "$d" ] && basename "$d"; done; }
app_ids_json() { app_ids | jq -R . | jq -s -c .; }   # ["id1","id2"]  (or []  when empty)
