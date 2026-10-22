# shellcheck shell=bash
# _enroll <code>: forced command of the "enroll" user (via sudo). Reads public keys on
# stdin, validates everything, registers the device and burns the invite.
#
# stdin protocol, one "field value" per line:
#   kind <machine|phone|client>      (all; what the device detected itself to be)
#   wg <wireguard public key>        (all)
#   client <ssh-ed25519 public key>  (all; user key to reach machines and hub-admin)
#   tunnel <ssh-ed25519 public key>  (machine; root key for the reverse tunnel)
#   host <ssh-ed25519 public key>    (machine; sshd host key, pinned by clients)
#   user <login user>                (machine)
#   mac <aa:bb:cc:dd:ee:ff>          (machine, optional; Wake-on-LAN)
#   os <linux|macos|android>         (optional; default from kind)

readonly ENROLL_MAX_LINES=16
readonly ENROLL_MAX_LINE=512
readonly ENROLL_MAX_BYTES=4096
ENROLL_TIMEOUT=${ENROLL_TIMEOUT:-10}

# enroll_set VAR VALIDATOR VALUE LABEL
enroll_set() {
  "$2" "$3" || die "invalid $4"
  printf -v "$1" '%s' "$3"
}

# Bounded in size and time, and read BEFORE taking the hub lock: a silent or endless
# client must not be able to block "remove" (revocation) or exhaust memory.
enroll_slurp() {
  local input
  input=$(timeout "$ENROLL_TIMEOUT" head -c "$ENROLL_MAX_BYTES") || true
  ((${#input} < ENROLL_MAX_BYTES)) || die "input too large"
  printf '%s\n' "$input"
}

enroll_read_input() {
  local n=0 line field value
  E_KIND="" E_OS="" E_WG="" E_CLIENT="" E_TUNNEL="" E_HOST="" E_USER="" E_MAC=-
  while IFS= read -r line || [[ -n $line ]]; do
    ((++n <= ENROLL_MAX_LINES)) || die "too many input lines"
    ((${#line} <= ENROLL_MAX_LINE)) || die "input line too long"
    [[ -z $line ]] && continue
    field=${line%% *}
    value=${line#* }
    case $field in
      kind) enroll_set E_KIND valid_kind "$value" "kind" ;;
      os) enroll_set E_OS valid_os "$value" "os" ;;
      wg) enroll_set E_WG valid_wg_key "$value" "wg key" ;;
      client) enroll_set E_CLIENT valid_ssh_pubkey "$value" "client key" ;;
      tunnel) enroll_set E_TUNNEL valid_ssh_pubkey "$value" "tunnel key" ;;
      host) enroll_set E_HOST valid_ssh_pubkey "$value" "host key" ;;
      user) enroll_set E_USER valid_user "$value" "user" ;;
      mac) enroll_set E_MAC valid_mac "${value,,}" "mac" ;;
      *) die "unknown field: $field" ;;
    esac
  done
}

enroll_check_required() {
  [[ -n $E_KIND ]] || die "missing device kind"
  [[ $INV_KIND == auto || $INV_KIND == "$E_KIND" ]] || die "this code is for a $INV_KIND, not a $E_KIND"
  [[ -n $E_WG && -n $E_CLIENT ]] || die "missing wg or client key"
  if [[ -z $E_OS ]]; then
    case $E_KIND in phone) E_OS=android ;; client) E_OS=macos ;; *) E_OS=linux ;; esac
  fi
  if [[ $E_KIND == machine ]]; then
    [[ -n $E_TUNNEL && -n $E_HOST && -n $E_USER ]] || die "machine needs tunnel, host and user"
    [[ $E_TUNNEL != "$E_CLIENT" ]] || die "tunnel and client keys must differ"
  else
    E_TUNNEL=- E_HOST=- E_USER=- E_MAC=-
  fi
}

enroll_check_unique() {
  local ssh_keys
  reg_column wg_pub | in_list "$E_WG" && die "wg key already registered"
  ssh_keys=$(reg_column client_pub && reg_column tunnel_pub)
  in_list "$E_CLIENT" <<<"$ssh_keys" && die "client key already registered"
  if [[ $E_TUNNEL != - ]]; then
    in_list "$E_TUNNEL" <<<"$ssh_keys" && die "tunnel key already registered"
  fi
  return 0
}

cmd_enroll() {
  local code=${1:-} origin=- input
  valid_code "$code" || die "invalid code"
  input=$(enroll_slurp)
  lock_acquire
  invite_load "$code" || die "unknown or used code"
  (($(now_epoch) < INV_EXPIRES)) || {
    invite_drop "$code"
    apply_all
    die "code expired"
  }
  enroll_read_input <<<"$input"
  enroll_check_required
  enroll_check_unique
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    origin=${SSH_CONNECTION%% *}
    valid_origin "$origin" || origin=-
  fi

  # Machines get a reverse-tunnel port (derived from the IP) and a color; others do not.
  local fields line port=- color=- sig=-
  if [[ $E_KIND == machine ]]; then
    port=$(port_for_ip "$INV_IP")
    color=$(alloc_color)
  fi
  [[ ${INV_OWNER:-0} == 1 ]] && sig=owner
  fields=("$INV_NAME" "$E_KIND" "$INV_IP" "$port" "$color" "$E_USER" "$INV_LAN" "$E_MAC"
    "$E_WG" "$E_CLIENT" "$E_TUNNEL" "$E_HOST" "$(fmt_iso "$(now_epoch)")" "$origin" "$E_OS" "$sig")
  line=$(IFS=$'\t' && printf '%s' "${fields[*]}")
  # First approver: its own key is the root of trust (checked again under the lock).
  [[ ${INV_OWNER:-0} == 1 ]] && signers_exist && die "this hub already has an approver"
  reg_add "$line"
  [[ ${INV_OWNER:-0} == 1 ]] && signer_add "$INV_NAME" "$E_CLIENT" owner
  invite_drop "$code"
  apply_all
  audit "enrolled $INV_NAME kind=$E_KIND ip=$INV_IP from=$origin"
  printf 'OK %s %s %s %s\n' "$INV_NAME" "$INV_IP" "$port" "$color"
}
