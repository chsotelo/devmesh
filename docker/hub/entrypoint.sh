#!/usr/bin/env bash
# devmesh hub container entrypoint: install-hub --container, then a small supervisor.
# If any long-running child dies the rest are stopped and the container exits non-zero, so
# the restart policy brings the whole hub back.
set -euo pipefail

SRC=${DEVMESH_SRC:-/opt/devmesh-src}
WG_IFACE_NAME=${WG_IFACE:-devmesh}
TICK_SECONDS=${TICK_SECONDS:-60}
BACKUP_EVERY_TICKS=${BACKUP_EVERY_TICKS:-1440}

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() {
  log "error: $*"
  exit 1
}

declare -A CHILD=() # pid -> name
shutting_down=0

stop_children() {
  local pid
  for pid in "${!CHILD[@]}"; do
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${!CHILD[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

shutdown() {
  local code=$1
  trap '' TERM INT
  stop_children
  wg-quick down "$WG_IFACE_NAME" >/dev/null 2>&1 || true
  exit "$code"
}

on_signal() {
  shutting_down=1
  log "signal received, shutting down"
  shutdown 0
}

# start NAME CMD... — run a daemon in the background and remember it.
start() {
  local name=$1
  shift
  "$@" &
  CHILD[$!]=$name
  log "started $name (pid $!)"
}

wireguard_up() {
  if ip link add dm-wgtest type wireguard 2>/dev/null; then
    ip link del dm-wgtest
  else
    log "kernel WireGuard not available: using wireguard-go (userspace)"
    export WG_QUICK_USERSPACE_IMPLEMENTATION=wireguard-go
  fi
  # A host-network interface outlives a crashed container: start from a clean slate.
  wg-quick down "$WG_IFACE_NAME" >/dev/null 2>&1 || true
  wg-quick up "$WG_IFACE_NAME"
}

# Same work as the devmesh-gc / devmesh-check / devmesh-backup timers.
ticker() {
  local n=0
  while :; do
    sleep "$TICK_SECONDS"
    n=$((n + 1))
    devmesh gc || log "devmesh gc failed"
    devmesh check || log "devmesh check failed"
    if ((n % BACKUP_EVERY_TICKS == 0)); then
      if [[ -n ${BACKUP_RECIPIENT:-} ]]; then
        devmesh backup || log "devmesh backup failed"
      fi
      if [[ -d /etc/letsencrypt/live ]]; then
        certbot renew -q --deploy-hook 'nginx -s reload' || log "certbot renew failed"
      fi
    fi
  done
}

# Domain mode without a certificate: install-hub left an http-only site; get the
# certificate through the running nginx, then install the full site.
obtain_certificate() {
  [[ -e /etc/devmesh/.acme-pending ]] || return 0
  [[ -n ${ACME_EMAIL:-} ]] || die "ACME_EMAIL is required to obtain a certificate"
  log "requesting a Let's Encrypt certificate for $HUB_HOST"
  certbot certonly --webroot -w "${DEVMESH_WEBROOT:-/var/lib/devmesh/www}/acme" -d "$HUB_HOST" \
    -m "$ACME_EMAIL" --agree-tos -n || die "certbot failed (DNS for $HUB_HOST must point here, port 80 open)"
  bash "$SRC/server/install-hub.sh" --container
  nginx -s reload
}

main() {
  [[ -n ${HUB_HOST:-} || -r /etc/devmesh/hub.conf ]] || die "set HUB_HOST (public IP or domain)"
  [[ -c /dev/net/tun ]] || log "warning: /dev/net/tun missing (use --device /dev/net/tun)"
  trap on_signal TERM INT

  bash "$SRC/server/install-hub.sh" --container
  # shellcheck source=/dev/null
  [[ -r /etc/devmesh/hub.conf ]] && source /etc/devmesh/hub.conf

  wireguard_up
  install -d -m 0755 /run/sshd
  start sshd /usr/sbin/sshd -D -e -f /etc/devmesh/sshd_config
  start nginx nginx -g 'daemon off;'
  start ntfy ntfy serve --config /etc/ntfy/server.yml
  start ticker ticker
  obtain_certificate
  log "hub $HUB_HOST is up"

  # Block until one child exits; that is always a failure.
  local pid
  wait -n -p pid || true
  ((shutting_down)) && return 0
  log "${CHILD[${pid:-0}]:-a child} exited: stopping the hub"
  [[ -z ${pid:-} ]] || unset "CHILD[$pid]"
  shutdown 1
}

main "$@"
