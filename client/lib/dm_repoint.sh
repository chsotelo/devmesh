# shellcheck shell=bash
# dm repoint: follow the hub to a new address (IP-mode hub moved to another VPS).
# Rewrites DM_HUB_HOST in node.conf, the WireGuard endpoint and the hub entries of the
# ssh config, then runs "dm refresh". Refuses unless the new address presents the same
# SSH host key this device already pinned for the hub.

dm_repoint_valid_host() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]]; }

# "type key" pinned for HOST in the devmesh known_hosts (comma-separated host lists).
dm_repoint_pinned_key() {
  awk -v h="$1" '{n = split($1, a, ","); for (i = 1; i <= n; i++) if (a[i] == h) {print $2 " " $3; exit}}' \
    "$HOME/.ssh/devmesh_known_hosts" 2>/dev/null
}

# "type key" the hub at HOST:PORT presents now.
dm_repoint_scanned_key() {
  ssh-keyscan -T 8 -p "$2" -t ed25519 "$1" 2>/dev/null |
    awk '$1 !~ /^#/ && $2 == "ssh-ed25519" {print $2 " " $3; exit}'
}

# dm_repoint_edit FILE SED_ARGS... — in-place edit that keeps the file's owner and mode.
dm_repoint_edit() {
  local file=$1 tmp
  shift
  tmp=$(mktemp)
  if sed "$@" "$file" >"$tmp" && cat "$tmp" >"$file"; then
    rm -f "$tmp"
  else
    rm -f "$tmp"
    return 1
  fi
}

# known_hosts used by devmesh-node (machines only).
dm_repoint_node_known_hosts() {
  if [[ $(dm_platform) == macos && -e $HOME/.config/devmesh/known_hosts ]]; then
    printf '%s\n' "$HOME/.config/devmesh/known_hosts"
  elif [[ $(dm_platform) == linux && -e /etc/devmesh/node.conf ]]; then
    printf '/etc/devmesh/known_hosts\n'
  fi
}

# WireGuard config files of this device that hold the hub endpoint.
dm_repoint_wg_conf() {
  if [[ -n ${DM_WG_CONF:-} ]]; then
    printf '%s\n' "$DM_WG_CONF"
  elif [[ $(dm_platform) == linux ]]; then
    printf '/etc/wireguard/%s.conf\n' "${DM_WG_IFACE:-devmesh}"
  elif [[ $(dm_platform) == macos ]]; then
    printf '%s/wireguard/devmesh.conf\n' "$(dirname "$(dm_conf_file)")"
  fi
}

dm_repoint() {
  local new=${1:-} old=${DM_HUB_HOST:-} port=${DM_HUB_SSH_PORT:-2222}
  local conf wg pinned scanned endpoint cfg root_cmds=()
  [[ -n $new ]] || dm_die "usage: dm repoint <ip-or-host>"
  dm_repoint_valid_host "$new" || dm_die "invalid address: $new"
  conf=$(dm_conf_file)

  pinned=$(dm_repoint_pinned_key "$old")
  [[ -n $pinned ]] || dm_die "no pinned hub host key for $old in ~/.ssh/devmesh_known_hosts"
  scanned=$(dm_repoint_scanned_key "$new" "$port")
  [[ -n $scanned ]] || dm_die "cannot read the SSH host key of $new (port $port)"
  [[ $scanned == "$pinned" ]] ||
    dm_die "the SSH host key of $new differs from the one pinned for the hub: not changing anything"
  dm_info "host key of $new matches the pinned hub key"

  # The old pin belongs to the old certificate; a new one is not trusted blindly.
  if [[ -w $conf ]]; then
    dm_repoint_edit "$conf" -e "s|^DM_HUB_HOST=.*|DM_HUB_HOST=$new|" -e '/^DM_HUB_PIN=/d'
  else
    root_cmds+=("sudo sed -i.bak -e 's|^DM_HUB_HOST=.*|DM_HUB_HOST=$new|' -e '/^DM_HUB_PIN=/d' $conf")
  fi

  endpoint=$new
  [[ $new == *:* ]] && endpoint="[$new]"
  wg=$(dm_repoint_wg_conf)
  # /etc/wireguard is root-only (0700): on Linux the file exists even if we cannot see it.
  if [[ -n $wg && (-e $wg || $(dm_platform) == linux) ]]; then
    if [[ -w $wg ]]; then
      dm_repoint_edit "$wg" -E "s|^(Endpoint = ).*(:[0-9]+)\$|\\1$endpoint\\2|"
      [[ $(dm_platform) != macos ]] || dm_info "re-import $wg in the WireGuard app"
    else
      root_cmds+=("sudo sed -i.bak -E 's|^(Endpoint = ).*(:[0-9]+)\$|\\1$endpoint\\2|' $wg")
      root_cmds+=("sudo systemctl restart wg-quick@${DM_WG_IFACE:-devmesh}")
    fi
  elif [[ $(dm_platform) == termux ]]; then
    dm_info "WireGuard app: change the peer Endpoint to $endpoint:${DM_WG_PORT:-51820}"
  fi

  # The node services (tunnel, key sync) check the hub against their own known_hosts, keyed
  # by the hub address: same key, new address.
  local nkh old_re
  old_re=$(printf '%s' "$old" | sed 's/[.]/\\./g')
  nkh=$(dm_repoint_node_known_hosts)
  if [[ -n $nkh ]]; then
    if [[ -w $nkh ]]; then
      dm_repoint_edit "$nkh" -E "s#^([^ ]*,)?$old_re([, ])#\\1$new\\2#"
    else
      root_cmds+=("sudo sed -i.bak -E 's#^([^ ]*,)?$old_re([, ])#\\1$new\\2#' $nkh")
    fi
  fi

  # The hub entries of ssh_config keep their HostKeyAlias, so the pinned key still applies.
  cfg=$HOME/.ssh/config.d/devmesh
  if [[ -w $cfg ]]; then
    dm_repoint_edit "$cfg" -E "s|^( *HostName )$(printf '%s' "$old" | sed 's/[.]/\\./g')\$|\\1$new|"
  fi

  # The new address presents the pinned key (checked above): pin that same key under the new
  # name too, and refresh as the new hub (node.conf may only change later, through sudo).
  printf '%s %s\n' "$new" "$pinned" >>"$HOME/.ssh/devmesh_known_hosts"
  DM_HUB_HOST=$new
  dm_refresh
  if ((${#root_cmds[@]})); then
    dm_info "root-owned files remain. Run:"
    printf '  %s\n' "${root_cmds[@]}" >&2
  fi
}
