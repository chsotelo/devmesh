# shellcheck shell=bash
# install-hub: WireGuard hub interface, Docker-safe forwarding, firewall opening.

step_firewall_snapshot() {
  IH_FW_BEFORE="$DEVMESH_BACKUP_DIR/iptables-before-$(date -u +%Y%m%dT%H%M%SZ).rules"
  iptables-save >"$IH_FW_BEFORE"
  chmod 0600 "$IH_FW_BEFORE"
  ih_log "firewall snapshot: $IH_FW_BEFORE"
}

step_wireguard() {
  ih_log "WireGuard hub $WG_IFACE on UDP $WG_PORT ($SUBNET_PREFIX.0/24)"
  if ((IH_CONTAINER)); then
    # The sysctl belongs to the host; with host networking it may be writable, else the
    # host must enable net.ipv4.ip_forward itself.
    { printf 1 >/proc/sys/net/ipv4/ip_forward; } 2>/dev/null ||
      ih_log "could not enable net.ipv4.ip_forward; set it on the host (VPN peers cannot reach each other without it)"
    "$DEVMESH_SBIN/devmesh" apply
    ih_log "container: wg-quick is started by the entrypoint"
    return 0
  fi
  # Docker already turns this on; set it explicitly for hosts without Docker.
  printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.d/90-devmesh.conf
  sysctl -q -p /etc/sysctl.d/90-devmesh.conf
  if systemctl cat docker.service >/dev/null 2>&1; then
    install -d "/etc/systemd/system/wg-quick@$WG_IFACE.service.d"
    install -m 0644 "$IH_SRC/server/systemd/wg-quick-after-docker.conf" \
      "/etc/systemd/system/wg-quick@$WG_IFACE.service.d/after-docker.conf"
  fi
  "$DEVMESH_SBIN/devmesh" apply
  systemctl daemon-reload
  systemctl enable "wg-quick@$WG_IFACE" >/dev/null
  if systemctl is-active --quiet "wg-quick@$WG_IFACE"; then
    "$DEVMESH_SBIN/devmesh" apply
    # syncconf does not run PostUp: bring the (possibly new) firewall rules in line now.
    "$DEVMESH_SBIN/devmesh-fw" up "$WG_IFACE"
  else
    systemctl start "wg-quick@$WG_IFACE"
  fi
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow "$WG_PORT/udp" comment devmesh >/dev/null
  fi
}

# Show what changed in the firewall; only devmesh lines are expected.
step_firewall_report() {
  local after
  after=$(mktemp)
  iptables-save | grep -v '^#' >"$after"
  ih_log "firewall changes (expect only $WG_IFACE / DEVMESH-HUB-IN / $WG_PORT rules):"
  local changes
  changes=$(diff <(grep -v '^#' "$IH_FW_BEFORE" | sed 's/\[[0-9]*:[0-9]*\]//') \
    <(sed 's/\[[0-9]*:[0-9]*\]//' "$after") | grep '^[<>]' || true)
  if [[ -n $changes ]]; then
    printf '%s\n' "$changes" >&2
  else
    ih_log "  (no changes)"
  fi
  rm -f "$after"
  # Keep the 10 most recent snapshots.
  find "$DEVMESH_BACKUP_DIR" -maxdepth 1 -name 'iptables-before-*.rules' | sort -r | tail -n +11 | xargs -r rm -f
}
