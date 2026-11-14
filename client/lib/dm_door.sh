# shellcheck shell=bash
# dm door: a door into a phone or tablet, opened on demand, so an agent on one of your machines
# can see and move its files. Phones are clients only (nothing listens on them); "dm door open"
# starts a private sshd for a limited time that:
#   - listens only on the device's mesh address (not on WiFi or mobile data),
#   - accepts only the client keys of machines an approver signed (verified bundle, signed mode
#     only), each pinned to that machine's mesh address, with no forwarding, agent or pty,
#   - presents the device's own approver-signed client key as its host key, so machines check it
#     against the signed bundle (alias "<device>-door", no trust on first use),
#   - closes by itself when the time is up (and when Termux is killed: it dies with it).
# A machine that enters gets a shell as the Termux user (rsync needs one), so it can read this
# device's own key: the door refuses to open on an approver device, whose key signs devices.

readonly DM_DOOR_PORT=8022
readonly DM_DOOR_MAX=$((4 * 3600))

dm_door_dir() { printf '%s/door\n' "$(dirname "$(dm_conf_file)")"; }

# dm_door_seconds 30m|2h -> seconds (1 minute to 4 hours).
dm_door_seconds() {
  local n unit s
  [[ $1 =~ ^([0-9]{1,3})([mh])$ ]] || return 1
  n=$((10#${BASH_REMATCH[1]}))
  unit=${BASH_REMATCH[2]}
  if [[ $unit == h ]]; then s=$((n * 3600)); else s=$((n * 60)); fi
  ((s >= 60 && s <= DM_DOOR_MAX)) || return 1
  printf '%s\n' "$s"
}

# dm_door_authorized VERIFIED HOSTS — authorized_keys lines: the client key of every machine
# whose host key an approver signed (VERIFIED: tr_process_bundle output), pinned to the mesh
# address the device list gives for it. A machine without a valid address gets no line.
dm_door_authorized() {
  local verified=$1 hosts=$2 kind name key machines="" ip
  while read -r kind name key; do
    [[ $kind == host ]] && machines+=" $name "
  done <<<"$verified"
  while read -r kind name key; do
    [[ $kind == client || $kind == signer ]] || continue
    [[ $machines == *" $name "* ]] || continue
    ip=$(awk -F'\t' -v n="$name" '$1 == n && $2 == "machine" {print $3; exit}' "$hosts")
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || continue
    printf 'from="%s",restrict %s devmesh-door:%s\n' "$ip" "$key" "$name"
  done <<<"$verified" | awk '!seen[$0]++'
}

dm_door_sftp() {
  local p
  for p in "${PREFIX:-/usr}/libexec/sftp-server" /usr/lib/openssh/sftp-server /usr/libexec/sftp-server /usr/libexec/openssh/sftp-server; do
    [[ -x $p ]] && {
      printf '%s\n' "$p"
      return 0
    }
  done
  return 1
}

# dm_door_sshd_config DIR IP HOSTKEY
dm_door_sshd_config() {
  local dir=$1 ip=$2 hostkey=$3 sftp
  cat <<EOF
# Written by "dm door open". Removed by "dm door close".
Port $DM_DOOR_PORT
ListenAddress $ip
HostKey $hostkey
PidFile $dir/sshd.pid
AuthorizedKeysFile $dir/authorized_keys
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowTcpForwarding no
AllowStreamLocalForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 30
ClientAliveCountMax 3
EOF
  if sftp=$(dm_door_sftp); then printf 'Subsystem sftp %s\n' "$sftp"; fi
}

# dm_door_cmdline PID — the process's command line ("" when it is gone).
dm_door_cmdline() {
  if [[ -r /proc/$1/cmdline ]]; then
    tr '\0' ' ' <"/proc/$1/cmdline"
  else
    ps -o args= -p "$1" 2>/dev/null || true
  fi
}

# dm_door_owned FILE MARK — the pid in FILE, only while that process is still ours (its command
# line holds MARK). A pid file left by a killed Termux may name a reused pid: never trust it.
dm_door_owned() {
  local pid
  pid=$(cat "$1" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] && ((pid > 1)) || return 1
  [[ $(dm_door_cmdline "$pid") == *"$2"* ]] || return 1
  printf '%s\n' "$pid"
}

dm_door_pid() { dm_door_owned "$(dm_door_dir)/sshd.pid" "$(dm_door_dir)/sshd_config"; }

# dm_door_tree PID — PID and all its descendants (sessions, shells, rsync, sftp-server).
dm_door_tree() {
  local c
  printf '%s\n' "$1"
  for c in $(pgrep -P "$1" 2>/dev/null); do dm_door_tree "$c"; done
}

dm_door_open() {
  local dur=${1:-30m} secs dir hostkey sshd verified keys pid until
  [[ $(dm_platform) == termux || -n ${DM_DOOR_ANY_PLATFORM:-} ]] ||
    dm_die "dm door open runs on a phone or tablet (Termux); from a machine use: ssh <device>-door"
  secs=$(dm_door_seconds "$dur") || dm_die "invalid time '$dur' (use 30m, 2h; from 1m to 8h)"
  dm_trust_active || dm_die "the door needs signed mode (dm trust status): only approver-signed machines may enter"
  [[ ${DM_IP:-} =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || dm_die "this device has no mesh address in its config"
  hostkey=$(dm_trust_key_file)
  [[ -r $hostkey ]] || dm_die "missing $hostkey"
  sshd=$(command -v sshd) || dm_die "sshd is not installed (pkg install openssh)"
  dm_trust_is_approver &&
    dm_die "this device is an approver: a machine let in could copy its signing key. Open the door on a non-approver device"
  dm_door_stop
  dir=$(dm_door_dir)
  install -d -m 0700 "$dir"
  dm_refresh >/dev/null || dm_die "cannot refresh the device list from the hub"
  ssh "${DM_SSH_PROBE[@]}" hub-admin bundle >"$dir/bundle" || {
    rm -f "$dir/bundle"
    dm_die "cannot fetch the signed bundle"
  }
  verified=$(tr_process_bundle "$(dm_allowed_signers)" "$dir/bundle" 1) || {
    rm -f "$dir/bundle"
    dm_die "the signed bundle does not verify; the door stays closed"
  }
  rm -f "$dir/bundle"
  keys=$(dm_door_authorized "$verified" "$DM_CACHE/hosts.tsv")
  [[ -n $keys ]] || dm_die "no approved machine to let in; the door stays closed"
  (umask 077 && printf '%s\n' "$keys" >"$dir/authorized_keys")
  (umask 077 && dm_door_sshd_config "$dir" "$DM_IP" "$hostkey" >"$dir/sshd_config")
  # The closer starts before the door: whatever happens next, it closes on time. It compares the
  # clock (not a sleep, which stops while the device sleeps) and is detached from inherited fds.
  until=$(($(date +%s) + secs))
  printf '%s\n' "$until" >"$dir/until"
  # shellcheck disable=SC2016 # expanded by the timer's own shell
  nohup bash -c 'while (($(date +%s) < $1)); do sleep 15; done; exec "$2" door close' \
    dm-door-timer "$until" "$DM_SELF" "$dir" </dev/null >/dev/null 2>&1 3>&- &
  printf '%s\n' "$!" >"$dir/timer.pid"
  trap 'dm_door_stop; exit 130' INT TERM HUP
  "$sshd" -f "$dir/sshd_config" -E "$dir/sshd.log" || {
    dm_door_stop
    dm_die "sshd did not start (is the WireGuard tunnel on? see $dir/sshd.log)"
  }
  pid=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pid=$(dm_door_pid) && break
    sleep 0.3
  done
  [[ -n $pid ]] || {
    dm_door_stop
    dm_die "sshd did not stay up (is the WireGuard tunnel on? see $dir/sshd.log)"
  }
  trap - INT TERM HUP
  if command -v termux-wake-lock >/dev/null; then termux-wake-lock || true; fi
  dm_info "door open on $DM_IP:$DM_DOOR_PORT for $dur ($(awk '{print $NF}' <<<"$keys" | sed 's/^devmesh-door://' | paste -sd, -))"
  dm_info "host key $(ssh-keygen -lf "$hostkey.pub" | awk '{print $2}')"
  dm_info "from a machine: ssh $DM_NAME-door   ·   close now: dm door close"
}

# dm_door_stop — sshd, every session it started, the timer, keys and config go away. Only
# processes that are still ours are signalled (dm_door_owned); the timer is stopped before its
# sleep, so it cannot run a late "door close" against a door opened again.
dm_door_stop() {
  local dir pid timer procs
  dir=$(dm_door_dir)
  [[ -d $dir ]] || return 0
  rm -f "$dir/authorized_keys"
  if timer=$(dm_door_owned "$dir/timer.pid" dm-door-timer) && [[ $timer != "$$" ]]; then
    procs=$(dm_door_tree "$timer")
    # shellcheck disable=SC2086 # a list of pids
    kill $procs 2>/dev/null || true
  fi
  if pid=$(dm_door_pid); then
    procs=$(dm_door_tree "$pid")
    # shellcheck disable=SC2086 # a list of pids
    kill $procs 2>/dev/null || true
  fi
  rm -f "$dir/sshd.pid" "$dir/timer.pid" "$dir/until" "$dir/sshd_config" "$dir/bundle"
}

dm_door_close() {
  local was=0
  dm_door_pid >/dev/null && was=1
  dm_door_stop
  if ((was)); then
    if command -v termux-wake-unlock >/dev/null; then termux-wake-unlock || true; fi
    dm_info "door closed"
  else
    dm_info "the door was not open"
  fi
}

dm_door_status() {
  local until left
  if [[ $(dm_platform) != termux && -z ${DM_DOOR_ANY_PLATFORM:-} ]]; then
    dm_door_list
    return
  fi
  if dm_door_pid >/dev/null; then
    until=$(cat "$(dm_door_dir)/until" 2>/dev/null || printf 0)
    left=$(((until - $(date +%s)) / 60))
    ((left >= 0)) || left=0
    printf 'open on %s:%s, closes in %s min\n' "$DM_IP" "$DM_DOOR_PORT" "$left"
  else
    printf 'closed\n'
  fi
}

# On a machine: every phone/tablet alias and whether its door is open right now.
dm_door_list() {
  local name state
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    if ssh -o BatchMode=yes -o ConnectTimeout=4 "$name-door" true </dev/null >/dev/null 2>&1; then
      state=open
    else
      state=closed
    fi
    printf '%-14s ssh %s-door   %s\n' "$name" "$name" "$state"
  done < <(dm_hosts phone | cut -f1)
}

# dm_door_ssh_config HOSTS — ~/.ssh/config.d/devmesh-door: "<device>-door" for every phone or
# tablet, checked against the device's signed client key (known_hosts alias devmesh-door-<name>).
dm_door_ssh_config() {
  local hosts=$1 name kind ip tmp aliases=""
  tmp=$(mktemp)
  printf '# Generated by dm refresh: doors into phones and tablets (dm door). Do not edit.\n' >"$tmp"
  while IFS=$'\t' read -r name kind ip _; do
    [[ $kind == phone && $name =~ ^[a-z][a-z0-9-]{0,15}$ && $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || continue
    printf 'Host %s-door\n  HostName %s\n  HostKeyAlias devmesh-door-%s\n' "$name" "$ip" "$name" >>"$tmp"
    aliases+=" $name-door"
  done <"$hosts"
  if [[ -n $aliases ]]; then
    cat >>"$tmp" <<EOF
Host${aliases}
  Port $DM_DOOR_PORT
  ConnectTimeout 6
  IdentityFile ~/.ssh/id_devmesh
  IdentitiesOnly yes
  UserKnownHostsFile ~/.ssh/devmesh_known_hosts
  StrictHostKeyChecking yes
  ServerAliveInterval 15
  ServerAliveCountMax 3
EOF
  fi
  mkdir -p "$HOME/.ssh/config.d"
  install -m 0600 "$tmp" "$HOME/.ssh/config.d/devmesh-door"
  rm -f "$tmp"
  dm_ssh_include devmesh-door
}

dm_door() {
  local sub=${1:-status}
  shift || true
  case $sub in
    open) dm_door_open "$@" ;;
    close) dm_door_close ;;
    status | ls) dm_door_status ;;
    *) dm_die "usage: dm door [open [30m|2h]|close|status]" ;;
  esac
}
