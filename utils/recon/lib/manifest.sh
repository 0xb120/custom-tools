# Append one role->path+provenance row to the workspace manifest.
# Requires lib/paths.sh sourced first (manifest_path).
manifest_append() {  # app_id|_surface  role  rel_path  tool  input
  local mf ts
  mf="$(manifest_path "$1")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$(dirname "$mf")"
  jq -c -n \
    --arg role "$2" --arg path "$3" --arg tool "$4" --arg input "$5" --arg ts "$ts" \
    '{role:$role, path:$path, tool:$tool, input:$input, ts:$ts}' >> "$mf"
}
