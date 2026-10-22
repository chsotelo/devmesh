# shellcheck shell=bash
# Shared helpers for the devmesh hub: paths, config, logging, validation, locking.
# Globals defined here are consumed by the other hub modules sourced alongside.
# shellcheck disable=SC2034

# --- Paths (overridable for tests) -------------------------------------------
DEVMESH_ETC=${DEVMESH_ETC:-/etc/devmesh}
DEVMESH_LIB=${DEVMESH_LIB:-/usr/local/lib/devmesh}
DEVMESH_SHARE=${DEVMESH_SHARE:-/usr/local/share/devmesh}
DEVMESH_SBIN=${DEVMESH_SBIN:-/usr/local/sbin}
DEVMESH_WG_DIR=${DEVMESH_WG_DIR:-/etc/wireguard}
DEVMESH_WEBROOT=${DEVMESH_WEBROOT:-/var/www/devmesh}
DEVMESH_STATE=${DEVMESH_STATE:-/var/lib/devmesh}
DEVMESH_BACKUP_DIR=${DEVMESH_BACKUP_DIR:-/var/backups/devmesh}
# devmesh runs its own sshd (port HUB_SSH_PORT) with its own host key; the system sshd
# of the host is never touched.
DEVMESH_HOST_KEY_PUB=${DEVMESH_HOST_KEY_PUB:-/etc/devmesh/ssh_host_ed25519_key.pub}

DEVMESH_REGISTRY="$DEVMESH_ETC/registry.tsv"
DEVMESH_INVITES="$DEVMESH_ETC/invites"
DEVMESH_SSH_KEYS="$DEVMESH_ETC/ssh"
DEVMESH_HUB_KEY="$DEVMESH_ETC/hub.key"
DEVMESH_CLIENTS_PUB="$DEVMESH_ETC/clients.pub"
# Signed key bundle ("keys2") and the approver list (see trust.sh).
DEVMESH_BUNDLE="$DEVMESH_ETC/clients.bundle"
DEVMESH_SIGNERS="$DEVMESH_ETC/signers.tsv"
# Signed revocations: name<TAB>pubkey<TAB>sig of "devmesh-revoke-v1 <name> <pubkey>".
DEVMESH_REVOKED="$DEVMESH_ETC/revoked.tsv"
# serial<TAB>hash<TAB>signer<TAB>sig of the revocation set (see trust.sh).
DEVMESH_EPOCH="$DEVMESH_ETC/epoch.tsv"
DEVMESH_HUB_CONF="$DEVMESH_ETC/hub.conf"
# IP mode only: self-signed certificate (inside DEVMESH_ETC, so backup and restore carry it).
DEVMESH_TLS_DIR="$DEVMESH_ETC/tls"

# --- Config defaults (hub.conf overrides) ------------------------------------
HUB_HOST=${HUB_HOST:-}
# base64(sha256(SPKI)) of the hub certificate; set by install-hub in IP mode only.
HUB_PIN=${HUB_PIN:-}
WG_IFACE=${WG_IFACE:-devmesh}
WG_PORT=${WG_PORT:-51820}
HUB_SSH_PORT=${HUB_SSH_PORT:-2222}
# IP mode only: devmesh's own HTTPS port, so a server that already runs websites keeps its
# 80/443 (and their default server) untouched. Domain mode shares 443 by server_name.
HUB_HTTPS_PORT=${HUB_HTTPS_PORT:-8443}
SUBNET_PREFIX=${SUBNET_PREFIX:-10.73.0}
TUNNEL_PORT_BASE=${TUNNEL_PORT_BASE:-2200}
INVITE_TTL=${INVITE_TTL:-900}
DOWN_AFTER=${DOWN_AFTER:-180}
ALERT_GRACE=${ALERT_GRACE:-60}
NTFY_URL=${NTFY_URL:-}
NTFY_TOPIC=${NTFY_TOPIC:-devmesh}
NTFY_TOKEN=${NTFY_TOKEN:-}
BACKUP_KEEP=${BACKUP_KEEP:-14}
COLOR_PALETTE=${COLOR_PALETTE:-"22 24 88 94 54 30 130 166 25 61"}

readonly DEVMESH_CODE_ALPHABET="23456789ABCDEFGHJKMNPQRSTUVWXYZ"
readonly DEVMESH_CODE_LEN=12

# --- Logging -----------------------------------------------------------------
log() { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Audit trail in syslog when available; never fails the caller.
audit() {
  command -v logger >/dev/null 2>&1 && logger -t devmesh -- "$*" 2>/dev/null
  return 0
}

load_hub_conf() {
  if [[ -r $DEVMESH_HUB_CONF ]]; then
    # shellcheck source=/dev/null
    source "$DEVMESH_HUB_CONF"
  fi
  [[ -n $HUB_HOST ]] || die "HUB_HOST is not set (configure $DEVMESH_HUB_CONF)"
  HUB_IP="$SUBNET_PREFIX.1"
}

require_root() {
  [[ ${DEVMESH_ALLOW_NONROOT:-0} == 1 || $EUID -eq 0 ]] || die "must run as root"
}

# --- TLS (IP mode) --------------------------------------------------------------
# tls_pin CERT — base64(sha256(DER SubjectPublicKeyInfo)), the value curl takes as
# --pinnedpubkey 'sha256//<pin>'.
tls_pin() {
  openssl x509 -in "$1" -pubkey -noout | openssl pkey -pubin -outform der |
    openssl dgst -sha256 -binary | base64 | tr -d '\n'
  printf '\n'
}

# tls_ensure_selfsigned IP — self-signed ECDSA P-256 certificate (10 years, SAN IP:<ip>)
# in $DEVMESH_TLS_DIR. Created only when absent or issued for another IP: re-running
# keeps the certificate (and therefore the pin handed to devices).
tls_ensure_selfsigned() {
  local ip=$1 dir=$DEVMESH_TLS_DIR tmp
  if [[ -s $dir/cert.pem && -s $dir/key.pem && $(cat "$dir/ip" 2>/dev/null) == "$ip" ]]; then
    return 0
  fi
  command -v openssl >/dev/null 2>&1 || die "openssl is required for IP mode"
  install -d -m 0700 "$dir"
  tmp=$(mktemp -d "$dir/.gen.XXXXXX")
  (
    umask 077
    printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=devmesh-hub\n[ext]\nsubjectAltName=IP:%s\nbasicConstraints=CA:FALSE\n' "$ip" >"$tmp/req.cnf"
    openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/key.pem" 2>/dev/null &&
      openssl req -new -x509 -days 3650 -key "$tmp/key.pem" -config "$tmp/req.cnf" -out "$tmp/cert.pem" 2>/dev/null
  ) || {
    rm -rf "$tmp"
    die "could not generate the self-signed certificate"
  }
  chmod 0600 "$tmp/key.pem"
  chmod 0644 "$tmp/cert.pem"
  printf '%s\n' "$ip" >"$tmp/ip"
  mv -f "$tmp/key.pem" "$dir/key.pem"
  mv -f "$tmp/cert.pem" "$dir/cert.pem"
  mv -f "$tmp/ip" "$dir/ip"
  rm -rf "$tmp"
}

# hub_pin — the pin printed in IP-mode invites: hub.conf value, else computed from the cert.
hub_pin() {
  if [[ -n $HUB_PIN ]]; then
    printf '%s\n' "$HUB_PIN"
  elif [[ -s $DEVMESH_TLS_DIR/cert.pem ]]; then
    tls_pin "$DEVMESH_TLS_DIR/cert.pem"
  else
    die "IP mode but no certificate pin (run install-hub to create $DEVMESH_TLS_DIR)"
  fi
}

# --- Time ----------------------------------------------------------------------
now_epoch() { printf '%s\n' "${DEVMESH_NOW:-$(date +%s)}"; }

# OpenSSH authorized_keys expiry-time, in the hub's local time and WITHOUT the "Z"
# suffix: OpenSSH 8.2 (Ubuntu 20.04) rejects "Z" and silently ignores the key.
fmt_expiry() {
  local epoch=$1
  date -d "@$epoch" +%Y%m%d%H%M 2>/dev/null || date -r "$epoch" +%Y%m%d%H%M
}

fmt_iso() {
  local epoch=$1
  date -u -d "@$epoch" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$epoch" +%Y-%m-%dT%H:%MZ
}

# Human "time ago" for a past epoch (0 = never).
fmt_ago() {
  local then=$1 now delta
  [[ $then =~ ^[0-9]+$ && $then -gt 0 ]] || {
    printf 'never\n'
    return
  }
  now=$(now_epoch)
  delta=$((now - then))
  ((delta < 0)) && delta=0
  if ((delta < 60)); then
    printf '%ss ago\n' "$delta"
  elif ((delta < 3600)); then
    printf '%sm ago\n' $((delta / 60))
  elif ((delta < 86400)); then
    printf '%sh ago\n' $((delta / 3600))
  else
    printf '%sd ago\n' $((delta / 86400))
  fi
}

# --- Validation ----------------------------------------------------------------
# "-b" suffix is reserved for path-B ssh aliases ("lap-b"); "hub*" for hub aliases.
valid_name() { [[ $1 =~ ^[a-z][a-z0-9-]{0,15}$ && $1 != hub* && $1 != *-b ]]; }
# machine: Linux box others connect to | phone: Termux | client: controls others (macOS)
valid_kind() { [[ $1 == machine || $1 == phone || $1 == client ]]; }
valid_os() { [[ $1 == linux || $1 == macos || $1 == android ]]; }
valid_user() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_lan() { [[ $1 == - || $1 =~ ^[a-z0-9][a-z0-9-]{0,15}$ ]]; }
valid_mac() { [[ $1 == - || $1 =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; }
valid_code() { [[ $1 =~ ^[${DEVMESH_CODE_ALPHABET}]{${DEVMESH_CODE_LEN}}$ ]]; }
valid_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_ipv4_strict() {
  local o
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for o in ${1//./ }; do ((10#$o <= 255)) || return 1; done
}
# Plain IPv6 literal (hex groups, at most one "::"); IPv4-mapped tails are not accepted.
valid_ipv6() {
  local a=$1 head tail g
  local -a h=() t=()
  [[ $a =~ ^[0-9a-fA-F:]+$ && $a == *:*:* && $a != *:::* ]] || return 1
  if [[ $a == *::* ]]; then
    [[ ${a#*::} != *::* ]] || return 1
    head=${a%%::*}
    tail=${a#*::}
    IFS=: read -ra h <<<"$head"
    IFS=: read -ra t <<<"$tail"
    ((${#h[@]} + ${#t[@]} <= 7)) || return 1
  else
    IFS=: read -ra h <<<"$a"
    ((${#h[@]} == 8)) || return 1
  fi
  for g in "${h[@]}" "${t[@]}"; do
    [[ $g =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
  done
}
# IP mode: HUB_HOST (or the argument) is an IPv4/IPv6 literal instead of a domain.
valid_ip() { valid_ipv4_strict "$1" || valid_ipv6 "$1"; }
hub_ip_mode() { valid_ip "${1:-$HUB_HOST}"; }
# Host as it appears in a URL: IPv6 literals need brackets.
url_host() { if [[ $1 == *:* ]]; then printf '[%s]\n' "$1"; else printf '%s\n' "$1"; fi; }
valid_origin() { [[ $1 =~ ^[0-9a-fA-F:.]{2,45}$ ]]; }
valid_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# WireGuard keys are 32 bytes base64: 43 chars + '='; the last char encodes 4 bits.
valid_wg_key() { [[ $1 =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$ ]]; }

# Only bare ed25519 public keys ("type base64"), no options, no comment.
# The blob is always 51 bytes -> 68 base64 chars, no padding.
valid_ssh_pubkey() { [[ $1 =~ ^ssh-ed25519\ AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}$ ]]; }

# Strip comment from "type base64 comment" -> "type base64".
ssh_key_bare() {
  local type key
  read -r type key _ <<<"$1"
  printf '%s %s\n' "$type" "$key"
}

# in_list NEEDLE < list — exact line match. Reads all input first: "producer | grep -q"
# under pipefail can report SIGPIPE (141) and silently skip a "&& die".
in_list() {
  local list
  list=$(cat)
  grep -qxF -- "$1" <<<"$list"
}

# --- Files -------------------------------------------------------------------
# atomic_write PATH MODE < content
atomic_write() {
  local path=$1 mode=$2 tmp
  tmp=$(mktemp "${path}.XXXXXX") || die "cannot create temp file for $path"
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    die "cannot write $path"
  fi
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# --- Cleanup -------------------------------------------------------------------
# One EXIT trap for the whole process; callers register paths to remove.
# Installed lazily so sourcing this file never replaces a caller's own EXIT trap.
DEVMESH_CLEANUP=()
devmesh_on_exit() {
  local p
  for p in "${DEVMESH_CLEANUP[@]}"; do
    rm -rf -- "$p"
  done
}
cleanup_add() {
  ((${#DEVMESH_CLEANUP[@]})) || trap devmesh_on_exit EXIT
  DEVMESH_CLEANUP+=("$1")
}

# --- Locking -------------------------------------------------------------------
# Serialize every hub mutation. flock on Linux; mkdir spin lock elsewhere (tests).
DEVMESH_LOCK_HELD=0
lock_acquire() {
  ((DEVMESH_LOCK_HELD)) && return 0
  local lock="$DEVMESH_ETC/.lock"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock"
    flock -w 30 9 || die "another devmesh operation is running"
  else
    local tries=0
    until mkdir "$lock.d" 2>/dev/null; do
      ((++tries > 300)) && die "another devmesh operation is running"
      sleep 0.1
    done
    cleanup_add "$lock.d"
  fi
  DEVMESH_LOCK_HELD=1
}

# --- Random --------------------------------------------------------------------
# Uniform code from the alphabet using rejection sampling on /dev/urandom bytes.
random_code() {
  local alpha=$DEVMESH_CODE_ALPHABET n=${#DEVMESH_CODE_ALPHABET} out="" byte
  local limit=$((256 - 256 % n))
  while ((${#out} < DEVMESH_CODE_LEN)); do
    for byte in $(od -An -N32 -tu1 /dev/urandom); do
      ((byte >= limit)) && continue
      out+=${alpha:byte%n:1}
      ((${#out} == DEVMESH_CODE_LEN)) && break
    done
  done
  printf '%s\n' "$out"
}

format_code() { printf '%s-%s-%s\n' "${1:0:4}" "${1:4:4}" "${1:8:4}"; }

# host[:port] for https:// URLs to this hub: the IP mode serves on its own port.
hub_url_authority() {
  if hub_ip_mode; then
    printf '%s:%s\n' "$(url_host "$HUB_HOST")" "$HUB_HTTPS_PORT"
  else
    printf '%s\n' "$HUB_HOST"
  fi
}
