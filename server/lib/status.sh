# shellcheck shell=bash
# Status: "ls" for humans, "check" for the alert timer.

# Prints "pubkey epoch" per peer (epoch 0 = never).
wg_handshakes() { wg show "$WG_IFACE" latest-handshakes 2>/dev/null || true; }

handshake_of() {
  awk -v k="$2" '$1 == k {print $2; found=1} END {if (!found) print 0}' <<<"$1"
}

# Reverse tunnel is up when the hub listens on localhost:<port>.
tunnel_up() {
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  [[ -n $(ss -Hltn "sport = :$1" 2>/dev/null) ]]
}

machine_is_up() {
  local hs=$1 port=$2 now
  now=$(now_epoch)
  ((hs > 0 && now - hs < DOWN_AFTER)) && return 0
  tunnel_up "$port"
}

# Client version last reported by the machine's key sync (see devmesh-keys-out).
machine_version() {
  local v
  v=$(cat "$DEVMESH_STATE/home/tunnel/versions/$1" 2>/dev/null || true)
  valid_version "$v" && printf '%s\n' "$v" || printf -- '-\n'
}

cmd_ls() {
  local hs name kind ip port color wg_pub enrolled_at origin hsep tun code sig state
  hs=$(wg_handshakes)
  local trust=0
  signers_exist && trust=1
  printf '%-16s %-7s %-12s %-6s %-10s %-6s %-5s %-8s %s\n' NAME KIND WG-IP PORT WG-SEEN TUNNEL COLOR VERSION ENROLLED
  while IFS=$'\t' read -r name kind ip port color _ _ _ wg_pub _ _ _ enrolled_at origin _ sig; do
    state=""
    ((trust)) && [[ $sig == -* ]] && state=" (pending approval)"
    hsep=$(handshake_of "$hs" "$wg_pub")
    tun=-
    if [[ $kind == machine ]]; then
      tun=DOWN
      tunnel_up "$port" && tun=up
      port=":$port"
    fi
    printf '%-16s %-7s %-12s %-6s %-10s %-6s %-5s %-8s %s from %s\n' "$name" "$kind" "$ip" \
      "$port" "$(fmt_ago "$hsep")" "$tun" "$color" "$(machine_version "$name")" "$enrolled_at" "$origin$state"
  done < <(reg_rows)
  while read -r code; do
    [[ -n $code ]] || continue
    invite_load "$code" || continue
    printf '%-16s %-7s %-12s %-6s pending, expires %s\n' "$INV_NAME" "$INV_KIND" "$INV_IP" "-" "$(fmt_iso "$INV_EXPIRES")"
  done < <(invite_codes)
}

notify() {
  local title=$1 msg=$2 tags=$3
  [[ -n $NTFY_URL ]] || return 0
  # Token through a curl config on stdin, never in argv (visible in ps).
  printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN" |
    curl -fsS -m 10 -K - -H "Title: $title" -H "Tags: $tags" -d "$msg" \
      "$NTFY_URL/$NTFY_TOPIC" >/dev/null || warn "ntfy notification failed"
}

# State per machine in $DEVMESH_STATE/machines/<name>: "up" | "down <since> <alerted> [<up since>]".
check_machine() {
  local name=$1 is_up=$2 file state since alerted up_since now
  file="$DEVMESH_STATE/machines/$name"
  now=$(now_epoch)
  read -r state since alerted up_since 2>/dev/null <"$file" || state=up
  if ((is_up)); then
    if [[ $state != down || ${alerted:-0} != 1 ]]; then
      printf 'up\n' >"$file"
      return 0
    fi
    # "Back" only once it stays up: a sleeping Mac wakes for seconds every few minutes.
    up_since=${up_since:-$now}
    if ((now - up_since >= RECOVER_AFTER)); then
      notify "$name is back" "$name is reachable again" "green_circle"
      printf 'up\n' >"$file"
    else
      printf 'down %s 1 %s\n' "$since" "$up_since" >"$file"
    fi
    return 0
  fi
  if [[ $state != down ]]; then
    printf 'down %s 0\n' "$now" >"$file"
  elif [[ $alerted != 1 ]] && ((now - since >= ALERT_GRACE)); then
    notify "$name is down" "$name: no WireGuard handshake and no tunnel for $(((now - since) / 60)) min" "red_circle"
    printf 'down %s 1\n' "$since" >"$file"
  elif [[ -n $up_since ]]; then
    printf 'down %s %s\n' "$since" "$alerted" >"$file"
  fi
}

cmd_check() {
  local hs name port wg_pub up
  mkdir -p "$DEVMESH_STATE/machines"
  hs=$(wg_handshakes)
  while IFS=$'\t' read -r name _ _ port _ _ _ _ wg_pub _; do
    up=0
    machine_is_up "$(handshake_of "$hs" "$wg_pub")" "$port" && up=1
    check_machine "$name" "$up"
  done < <(reg_rows machine)
}
