#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/assert.sh"
export BASE="$(mktemp -d)"
source "$DIR/../lib/appid.sh"                 # for computing expected app_id in the test
source "$DIR/../adapters/surfagr.sh"

run="20260617T000000Z"
raw="$(surface_raw surfagr "$run")"

# Cluster 1: domain host on default https port
mkdir -p "$raw/targets/login.example.com_acme_login"
printf 'https://login.example.com/\nhttps://10.0.0.5/\n' > "$raw/targets/login.example.com_acme_login/hosts.txt"
printf 'Title: ACME Login\nIP: 10.0.0.5\nWebserver: nginx\nTech Stack: React, Nginx\nContent-Length: 1234\nStatus-Code: 200\n' \
  > "$raw/targets/login.example.com_acme_login/info.txt"

# Cluster 2: explicit port
mkdir -p "$raw/targets/api.example.com_8443_api"
printf 'https://api.example.com:8443/\n' > "$raw/targets/api.example.com_8443_api/hosts.txt"
printf 'Title: API\nIP: 10.0.0.6\nWebserver: envoy\nTech Stack: None detected\nContent-Length: 0\nStatus-Code: 404\n' \
  > "$raw/targets/api.example.com_8443_api/info.txt"

# Cluster 3: all-IP hosts -> exercises the "else first URL" fallback (must not abort)
mkdir -p "$raw/targets/10.0.0.9_iponly"
printf 'https://10.0.0.9/\nhttps://10.0.0.10/\n' > "$raw/targets/10.0.0.9_iponly/hosts.txt"
printf 'Title: IP Only\nIP: 10.0.0.9\nWebserver: nginx\nTech Stack: None detected\nContent-Length: 5\nStatus-Code: 200\n' \
  > "$raw/targets/10.0.0.9_iponly/info.txt"

normalize_surfagr "$run"

id1="$(app_id_for login.example.com 443)"
id2="$(app_id_for api.example.com 8443)"
id3="$(app_id_for 10.0.0.9 443)"

assert_file_exists "$(meta_json "$id1")" "cluster 1 meta.json created at app_id dir"
assert_file_exists "$(meta_json "$id2")" "cluster 2 meta.json created at app_id dir"
assert_file_exists "$(meta_json "$id3")" "all-IP cluster falls back to first URL (no abort)"
assert_eq "login.example.com" "$(jq -r .host "$(meta_json "$id1")")" "cluster 1 host parsed (domain over IP)"
assert_eq "443"               "$(jq -r .port "$(meta_json "$id1")")" "cluster 1 default port"
assert_eq "8443"              "$(jq -r .port "$(meta_json "$id2")")" "cluster 2 explicit port"
assert_eq "10.0.0.9"          "$(jq -r .host "$(meta_json "$id3")")" "all-IP cluster host is first IP"
assert_eq "443"               "$(jq -r .port "$(meta_json "$id3")")" "all-IP cluster default port"
assert_eq "2"                 "$(jq '.cluster_hosts | length' "$(meta_json "$id1")")" "cluster 1 keeps all hosts"
assert_eq "2"                 "$(jq '.tech | length' "$(meta_json "$id1")")" "cluster 1 tech split into array"
assert_eq "0"                 "$(jq '.tech | length' "$(meta_json "$id2")")" "cluster 2 'None detected' -> empty array"
assert_contains "$(manifest_path "$id1")" '"role":"meta"' "cluster 1 meta manifest row"
rm -rf "$BASE"
assert_summary
