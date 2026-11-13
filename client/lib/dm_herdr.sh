# shellcheck shell=bash
# Herdr (https://herdr.dev) on top of the mesh. devmesh never installs Herdr: it only
#   - puts the Herdr mobile app's SSH key on every machine, usable only from that device's
#     mesh address ("dm herdr allow|revoke|ls"; "dm rm" revokes too), and
#   - "dm use": wakes a machine when it is asleep and starts a Herdr terminal on it.

# authorized_keys lines devmesh manages end with this comment plus ":<device>".
readonly DM_HERDR_TAG=devmesh-herdr
readonly DM_HERDR_KEY_RE='(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa) [A-Za-z0-9+/]{40,}={0,3}'
# Herdr signs in to run herdr-core over stdin/stdout: it needs no forwarding of any kind.
readonly DM_HERDR_KEY_OPTS='no-agent-forwarding,no-port-forwarding,no-X11-forwarding'

dm_herdr_valid_device() { [[ ${1:-} =~ ^[a-z][a-z0-9-]{0,15}$ ]]; }
dm_herdr_valid_ip() { [[ ${1:-} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# dm_herdr_key_from TEXT — the "type base64" of the first public key in TEXT. TEXT may be the
# whole line the app shows ("mkdir -p ~/.ssh && echo 'ssh-ed25519 AAAA… herdr' >> …").
dm_herdr_key_from() {
  grep -oE "$DM_HERDR_KEY_RE" <<<"$1" | head -n 1
}

# --- machine side: dm _herdr add|rm|ls|hc|run|attach -------------------------------------

dm_herdr_keys_file() { printf '%s/.ssh/authorized_keys\n' "$HOME"; }

# dm_herdr_rewrite DEVICE BODY — authorized_keys without the lines of DEVICE and without any
# line carrying key BODY (the base64 part), written atomically with the same mode.
dm_herdr_rewrite() {
  local device=$1 body=$2 file tmp
  file=$(dm_herdr_keys_file)
  # Replacing a symlink with a file would silently cut it from wherever it points.
  [[ ! -L $file ]] || dm_die "$file is a symlink here: add the key to its target by hand"
  install -d -m 0700 "$HOME/.ssh"
  [[ -e $file ]] || { : >"$file" && chmod 0600 "$file"; }
  tmp=$(mktemp "$HOME/.ssh/.authorized_keys.XXXXXX")
  awk -v tag=" $DM_HERDR_TAG:$device" -v body="$body" '
    (length($0) >= length(tag) && substr($0, length($0) - length(tag) + 1) == tag) { next }
    (body != "" && index($0, " " body) > 0) { next }
    { print }' "$file" >"$tmp"
  chmod 0600 "$tmp"
  printf '%s\n' "$tmp"
}

# dm_herdr_sshd_up — something answers on port 22 here (macOS: Remote Login is on).
dm_herdr_sshd_up() { (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null; }

dm_herdr_hc() {
  if command -v hc >/dev/null 2>&1; then
    command -v hc
  elif [[ -x $HOME/.local/bin/hc ]]; then
    printf '%s\n' "$HOME/.local/bin/hc"
  else
    return 1
  fi
}

dm_remote_herdr() {
  local action=${1:-} device=${2:-} ip=${3:-} type=${4:-} body=${5:-} tmp hc
  case $action in
    add)
      dm_herdr_valid_device "$device" || dm_die "invalid device name"
      dm_herdr_valid_ip "$ip" || dm_die "invalid address"
      [[ "$type $body" =~ ^$DM_HERDR_KEY_RE$ ]] || dm_die "invalid public key"
      tmp=$(dm_herdr_rewrite "$device" "$body") || exit 1
      printf 'from="%s",%s %s %s %s:%s\n' "$ip" "$DM_HERDR_KEY_OPTS" "$type" "$body" "$DM_HERDR_TAG" "$device" >>"$tmp"
      mv "$tmp" "$(dm_herdr_keys_file)"
      if dm_herdr_sshd_up; then printf 'ok\n'; else printf 'ok no-sshd\n'; fi
      ;;
    rm)
      dm_herdr_valid_device "$device" || dm_die "invalid device name"
      [[ -e $(dm_herdr_keys_file) ]] || {
        printf 'ok\n'
        return 0
      }
      tmp=$(dm_herdr_rewrite "$device" "") || exit 1
      mv "$tmp" "$(dm_herdr_keys_file)"
      printf 'ok\n'
      ;;
    ls)
      [[ -r $(dm_herdr_keys_file) ]] || return 0
      awk -v tag="$DM_HERDR_TAG:" '{
        n = split($NF, p, ":")
        if (index($NF, tag) == 1 && n == 2) print p[2] "\t" $(NF - 2) "\t" substr($(NF - 1), 1, 16) "…"
      }' "$(dm_herdr_keys_file)"
      ;;
    hc) dm_herdr_hc || exit 3 ;;
    run)
      shift
      hc=$(dm_herdr_hc) || dm_die "herdr-core is not installed here"
      exec "$hc" run --bg --no-parent "$@"
      ;;
    attach)
      [[ $device =~ ^t[0-9a-z]{1,8}$ ]] || dm_die "invalid terminal address"
      hc=$(dm_herdr_hc) || dm_die "herdr-core is not installed here"
      exec "$hc" attach "$device"
      ;;
    *) dm_die "usage: dm _herdr add|rm|ls|hc|run|attach" ;;
  esac
}

# --- controller side ----------------------------------------------------------------------

# dm_herdr_on HOST CMD-WORDS… — "dm _herdr …" on HOST. Its output, or "offline" (no answer) or
# "outdated" (it answers but its devmesh has no _herdr yet: dm update there), with status 1.
dm_herdr_on() {
  local m=$1 out
  shift
  if out=$(dm_run "$m" dm _herdr "$@" </dev/null 2>/dev/null); then
    printf '%s\n' "$out"
  elif dm_is_self "$m" || dm_path "$m" >/dev/null 2>&1; then
    printf 'outdated\n'
    return 1
  else
    printf 'offline\n'
    return 1
  fi
}

# dm_herdr_each CMD-WORDS… — run "dm _herdr …" on every machine: "machine<TAB>first line".
dm_herdr_each() {
  local m out
  for m in $(dm_machines); do
    out=$(dm_herdr_on "$m" "$@") || true
    printf '%s\t%s\n' "$m" "${out%%$'\n'*}"
  done
}

dm_herdr_allow() {
  local device=${1:-} key ip kind m res missed=0
  shift || true
  dm_herdr_valid_device "$device" || dm_die "usage: dm herdr allow <device> <ssh-public-key>"
  key=$(dm_herdr_key_from "$*")
  [[ -n $key ]] || dm_die "no SSH public key in what you passed (paste the line the Herdr app shows)"
  kind=$(dm_host_field "$device" kind)
  [[ -n $kind ]] || dm_die "no device '$device' (dm devices)"
  ip=$(dm_host_field "$device" ip)
  dm_herdr_valid_ip "$ip" || dm_die "device '$device' has no mesh address"
  dm_require_machines
  while IFS=$'\t' read -r m res; do
    case $res in
      ok) dm_info "$m: ok" ;;
      "ok no-sshd") dm_info "$m: key added, but nothing answers on port 22 (macOS: turn on System Settings › General › Sharing › Remote Login)" ;;
      outdated)
        dm_info "$m: its devmesh is too old for this, not updated (run dm update there)"
        missed=1
        ;;
      *)
        dm_info "$m: offline, not updated"
        missed=1
        ;;
    esac
  done < <(dm_herdr_each add "$device" "$ip" "${key%% *}" "${key#* }")
  dm_info "the Herdr app on $device signs in from $ip as each machine's user"
  ((missed == 0)) || dm_info "run it again when the offline machines are back (it is safe to repeat)"
}

dm_herdr_revoke() {
  local device=${1:-} m res missed=0
  dm_herdr_valid_device "$device" || dm_die "usage: dm herdr revoke <device>"
  while IFS=$'\t' read -r m res; do
    if [[ $res == ok ]]; then dm_info "$m: revoked"; else
      dm_info "$m: $res, not updated"
      missed=1
    fi
  done < <(dm_herdr_each rm "$device")
  return "$missed"
}

dm_herdr_ls() {
  local m out dev type key
  printf '%-16s %-16s %-22s %s\n' MACHINE DEVICE TYPE KEY
  for m in $(dm_machines); do
    if ! out=$(dm_herdr_on "$m" ls); then
      printf '%-16s (%s)\n' "$m" "$out"
      continue
    fi
    [[ -n $out ]] || printf '%-16s (none)\n' "$m"
    # A machine's answer is untrusted: only well-formed fields reach this terminal.
    while IFS=$'\t' read -r dev type key; do
      [[ -n $dev ]] || continue
      if dm_herdr_valid_device "$dev" && [[ $type =~ ^[a-z0-9@.-]{1,40}$ && $key =~ ^[A-Za-z0-9+/=]{1,16}…?$ ]]; then
        printf '%-16s %-16s %-22s %s\n' "$m" "$dev" "$type" "$key"
      else
        printf '%-16s (unreadable line)\n' "$m"
      fi
    done <<<"$out"
  done
}

dm_herdr() {
  local sub=${1:-}
  shift || true
  case $sub in
    allow) dm_herdr_allow "$@" ;;
    revoke) dm_herdr_revoke "$@" || dm_info "run it again when the offline machines are back" ;;
    ls) dm_herdr_ls ;;
    *) dm_die "usage: dm herdr allow <device> <ssh-public-key> | revoke <device> | ls" ;;
  esac
}

# dm_use_wait HOST — wake HOST and wait until it answers (DM_USE_WAIT seconds, default 180).
dm_use_wait() {
  local host=$1 waited=0 max=${DM_USE_WAIT:-180}
  dm_info "$host is not answering: waking it"
  dm_power "$host" wake
  until dm_path "$host" >/dev/null 2>&1; do
    ((waited < max)) || dm_die "$host did not come back within ${max}s"
    sleep 5
    waited=$((waited + 5))
  done
  dm_info "$host is up"
}

# dm use HOST [--cwd DIR] [--attach] [-- COMMAND...]
dm_use() {
  local host="" cwd="" attach=0 out addr q=""
  local -a cmd=() args=(run)
  while (($#)); do
    case $1 in
      --cwd)
        cwd=${2:-}
        [[ -n $cwd ]] || dm_die "--cwd needs a folder"
        shift
        ;;
      --attach | -a) attach=1 ;;
      --)
        shift
        cmd=("$@")
        break
        ;;
      -*) dm_die "unknown option $1 (usage: dm use <machine> [--cwd DIR] [--attach] [-- command...])" ;;
      *)
        if [[ -z $host ]]; then host=$1; else
          cmd=("$@")
          break
        fi
        ;;
    esac
    shift
  done
  dm_require_machines
  [[ -n $host ]] || host=$(dm_machines | dm_pick "machine") || return 0
  [[ $(dm_host_field "$host" kind) == machine ]] || dm_die "no machine '$host' (dm devices)"
  dm_is_self "$host" || dm_path "$host" >/dev/null 2>&1 || dm_use_wait "$host"
  dm_run "$host" dm _herdr hc >/dev/null 2>&1 ||
    dm_die "herdr-core is not on $host. Herdr is optional; to add it from a machine that has it: hc machine add $host"
  [[ -z $cwd ]] || args+=(--cwd "$cwd")
  ((${#cmd[@]} == 0)) || args+=(-- "${cmd[@]}")
  if dm_is_self "$host"; then
    out=$(dm_remote_herdr "${args[@]}") || dm_die "herdr-core here did not start it"
  else
    # ssh joins its arguments into one line for the remote shell: quote each word for it.
    printf -v q '%q ' "${args[@]}"
    # shellcheck disable=SC2086 # q is a list of words quoted for the remote shell
    out=$(dm_run "$host" dm _herdr $q) || dm_die "herdr-core on $host did not start it"
  fi
  addr=$(grep -oE '"address":"t[0-9a-z]{1,8}"' <<<"$out" | head -n 1 | cut -d'"' -f4)
  [[ -n $addr ]] || dm_die "herdr-core on $host gave no terminal address"
  if ((attach)); then
    dm_tty "$host" "dm _herdr attach $addr"
  else
    dm_info "started $addr on $host: open it in Herdr (machine $host)"
  fi
}
