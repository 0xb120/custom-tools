# Stable workspace key. Hash the DNS hostname + port (NOT the IP, NOT the title).
app_id_for() {  # host port
  printf '%s:%s' "$1" "$2" | sha1sum | cut -c1-12
}
