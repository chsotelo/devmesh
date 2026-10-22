# shellcheck shell=bash
# Registry: one TSV line per enrolled device, the single source of truth.
# Pending invites live in $DEVMESH_INVITES/<code>.env and reserve IP/port/color.

# Column order of registry.tsv (1-based for awk).
# os: linux | macos | android (macOS machines are reached through the hub tunnel only).
# sig: "-" pending approval | "legacy" enrolled before approvals existed (no signature yet) |
# "owner" first approver | <client-sig-b64>[:<host-sig-b64>]
# (base64 of the armored ssh-keygen -Y signature; see trust.sh). "owner:<host-sig>" is an
# owner machine whose host key is signed.
readonly REG_COLS=(name kind ip port color user lan mac wg_pub client_pub tunnel_pub host_pub enrolled_at enrolled_from os sig)

reg_init() {
  mkdir -p "$DEVMESH_ETC" "$DEVMESH_INVITES" "$DEVMESH_SSH_KEYS"
  [[ -e $DEVMESH_REGISTRY ]] || : >"$DEVMESH_REGISTRY"
  chmod 0600 "$DEVMESH_REGISTRY"
  reg_migrate
}

# v0.2 rows have 14 columns: add "os" (linux for machines, android for phones, macos for
# clients); 15-column rows (<= 0.7) gain "sig" = "-" (pending). Idempotent, rewrites only
# when needed.
reg_migrate() {
  awk -F'\t' 'NF == 14 || NF == 15 {bad = 1} END {exit !bad}' "$DEVMESH_REGISTRY" 2>/dev/null || return 0
  [[ -w $DEVMESH_REGISTRY ]] || return 0
  awk -F'\t' -v OFS='\t' '
    NF == 14 {os = ($2 == "phone") ? "android" : ($2 == "client") ? "macos" : "linux"; $0 = $0 OFS os}
    NF == 15 {$0 = $0 OFS "-"}
    {print}' "$DEVMESH_REGISTRY" | atomic_write "$DEVMESH_REGISTRY" 0600
}

reg_col_index() {
  local want=$1 i
  for i in "${!REG_COLS[@]}"; do
    [[ ${REG_COLS[$i]} == "$want" ]] && {
      printf '%s\n' $((i + 1))
      return 0
    }
  done
  die "unknown registry column: $want"
}

# reg_rows [kind] -> registry lines (optionally filtered by kind)
reg_rows() {
  local kind=${1:-}
  awk -F'\t' -v k="$kind" 'NF >= 16 && $1 !~ /^#/ && (k == "" || $2 == k)' "$DEVMESH_REGISTRY"
}

reg_get() {
  awk -F'\t' -v n="$1" '$1 == n {print; found=1} END {exit !found}' "$DEVMESH_REGISTRY"
}

reg_exists() { reg_get "$1" >/dev/null; }

# reg_field LINE COLUMN
reg_field() {
  local idx
  idx=$(reg_col_index "$2")
  awk -F'\t' -v i="$idx" '{print $i}' <<<"$1"
}

# reg_column COLUMN [kind] -> values of one column
reg_column() {
  local idx
  idx=$(reg_col_index "$1")
  reg_rows "${2:-}" | awk -F'\t' -v i="$idx" '{print $i}'
}

reg_add() {
  local line=$1 name ip port
  name=$(reg_field "$line" name)
  ip=$(reg_field "$line" ip)
  port=$(reg_field "$line" port)
  [[ $(awk -F'\t' '{print NF}' <<<"$line") -eq ${#REG_COLS[@]} ]] || die "registry line has wrong column count"
  reg_exists "$name" && die "device already exists: $name"
  reg_column ip | in_list "$ip" && die "IP already in use: $ip"
  if [[ $port != - ]] && reg_column port | in_list "$port"; then
    die "tunnel port already in use: $port"
  fi
  { cat "$DEVMESH_REGISTRY" && printf '%s\n' "$line"; } | atomic_write "$DEVMESH_REGISTRY" 0600
}

reg_remove() {
  reg_exists "$1" || die "no such device: $1"
  awk -F'\t' -v n="$1" '$1 != n' "$DEVMESH_REGISTRY" | atomic_write "$DEVMESH_REGISTRY" 0600
}

# reg_set_sig NAME VALUE — replace the sig column of one device.
reg_set_sig() {
  local idx
  idx=$(reg_col_index sig)
  reg_exists "$1" || die "no such device: $1"
  awk -F'\t' -v OFS='\t' -v n="$1" -v i="$idx" -v v="$2" '$1 == n {$i = v} {print}' "$DEVMESH_REGISTRY" |
    atomic_write "$DEVMESH_REGISTRY" 0600
}

# --- Invites -------------------------------------------------------------------
invite_path() { printf '%s/%s.env\n' "$DEVMESH_INVITES" "$1"; }

# Invite files are written by devmesh itself (KEY=value, values pre-validated).
# shellcheck disable=SC2034 # INV_* are read by callers after loading
invite_load() {
  local file
  file=$(invite_path "$1")
  [[ -r $file ]] || return 1
  INV_NAME="" INV_KIND="" INV_IP="" INV_PORT="" INV_COLOR="" INV_LAN="" INV_WATCH="" INV_EXPIRES="" INV_PUB="" INV_OWNER=0
  # shellcheck source=/dev/null
  source "$file"
}

invite_codes() {
  local f
  for f in "$DEVMESH_INVITES"/*.env; do
    [[ -e $f ]] || continue
    f=${f##*/}
    printf '%s\n' "${f%.env}"
  done
}

# Values of one invite field across all pending invites (for allocation).
invite_values() {
  local field=$1 code
  while read -r code; do
    [[ -n $code ]] || continue
    invite_load "$code" || continue
    printf '%s\n' "${!field}"
  done < <(invite_codes)
}

invite_name_taken() { invite_values INV_NAME | in_list "$1"; }

# --- Allocation ------------------------------------------------------------------
alloc_ip() {
  local used octet
  used=$({
    reg_column ip
    invite_values INV_IP
  } | sort -u)
  for octet in $(seq 2 254); do
    grep -qxF "$SUBNET_PREFIX.$octet" <<<"$used" || {
      printf '%s\n' "$SUBNET_PREFIX.$octet"
      return 0
    }
  done
  die "no free IP in $SUBNET_PREFIX.0/24"
}

# Tunnel port is derived from the IP's last octet: 10.73.0.11 -> 2211.
port_for_ip() { printf '%s\n' $((TUNNEL_PORT_BASE + ${1##*.})); }

alloc_color() {
  local used c palette
  read -ra palette <<<"$COLOR_PALETTE"
  used=$({
    reg_column color machine
    invite_values INV_COLOR
  } | grep -v '^-$' | sort -u)
  for c in "${palette[@]}"; do
    grep -qxF "$c" <<<"$used" || {
      printf '%s\n' "$c"
      return 0
    }
  done
  # Palette exhausted: reuse in order.
  printf '%s\n' "${palette[$(($(grep -c . <<<"$used") % ${#palette[@]}))]}"
}
