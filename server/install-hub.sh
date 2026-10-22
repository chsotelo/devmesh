#!/usr/bin/env bash
# install-hub.sh — build (or re-apply) a devmesh hub on a Debian/Ubuntu VPS. Idempotent.
#
#   HUB_HOST=hub.example.com ACME_EMAIL=me@example.com BACKUP_RECIPIENT=age1... \
#     bash install-hub.sh [--restore state.tar.gz] [--no-web] [--container]
#
# --container (used by docker/hub/entrypoint.sh): no systemd, firewall snapshot, ufw, fail2ban
# or timers; packages come from the image and the entrypoint starts the daemons.
#
# HUB_HOST may also be an IPv4/IPv6 address (no domain): the hub then serves a self-signed
# certificate and the join line carries its public-key pin; ACME_EMAIL is not needed.
#
# Every production-facing change is validated before it is applied (sshd -t, visudo -c,
# nginx -t) and rolled back on failure. The firewall is snapshotted before any change.
set -euo pipefail

IH_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Values given on the command line, captured before common.sh fills in defaults.
declare -A IH_CLI=()
for _k in HUB_HOST WG_IFACE WG_PORT SUBNET_PREFIX NTFY_TOPIC; do
  [[ -n ${!_k:-} ]] && IH_CLI[$_k]=${!_k}
done
unset _k
export DEVMESH_LIB=${DEVMESH_LIB:-/usr/local/lib/devmesh}
# shellcheck source=lib/common.sh
source "$IH_SRC/server/lib/common.sh"
for _f in base network web; do
  # shellcheck source=/dev/null
  source "$IH_SRC/server/install/$_f.sh"
done
unset _f

NGINX_SITE_DIR=${NGINX_SITE_DIR:-/etc/nginx/conf.d}
# Overridable paths (tests run unprivileged against temporary directories).
IH_SSHD=${IH_SSHD:-/usr/sbin/sshd}
IH_SSHD_RUNDIR=${IH_SSHD_RUNDIR:-/run/sshd}
IH_SUDOERS_DIR=${IH_SUDOERS_DIR:-/etc/sudoers.d}
IH_NTFY_ETC=${IH_NTFY_ETC:-/etc/ntfy}
IH_NTFY_LIB=${IH_NTFY_LIB:-/var/lib/ntfy}
IH_NTFY_CACHE=${IH_NTFY_CACHE:-/var/cache/ntfy}
# 1 with --container: nothing is started or enabled through systemd.
IH_CONTAINER=0

ih_log() { printf '\033[1m[install-hub]\033[0m %s\n' "$*" >&2; }
ih_die() {
  printf '\033[31m[install-hub] error:\033[0m %s\n' "$*" >&2
  exit 1
}

# ih_systemctl ARGS — systemctl, except in a container where there is no systemd.
ih_systemctl() {
  ((IH_CONTAINER)) && return 0
  systemctl "$@"
}

# ih_service_reload NAME — reload the service, or start it when it is not running.
ih_service_reload() {
  ih_systemctl reload-or-restart "$1"
}

# ih_conf_set KEY VALUE — persist one setting in hub.conf (root only, holds the ntfy token).
ih_conf_set() {
  local key=$1 value=$2 tmp
  [[ $key =~ ^[A-Z_]+$ ]] || ih_die "bad config key $key"
  [[ $value =~ ^[A-Za-z0-9._:/@+=-]*$ ]] || ih_die "bad value for $key"
  install -d -m 0755 "$DEVMESH_ETC"
  [[ -e $DEVMESH_HUB_CONF ]] || install -m 0600 /dev/null "$DEVMESH_HUB_CONF"
  tmp=$(mktemp "$DEVMESH_HUB_CONF.XXXXXX")
  grep -v "^$key=" "$DEVMESH_HUB_CONF" >"$tmp" || true
  printf '%s=%s\n' "$key" "$value" >>"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$DEVMESH_HUB_CONF"
  printf -v "$key" '%s' "$value"
}

step_config() {
  # Saved config first, then anything passed on the command line wins.
  local k
  if [[ -r $DEVMESH_HUB_CONF ]]; then
    # shellcheck source=/dev/null
    source "$DEVMESH_HUB_CONF"
  fi
  for k in "${!IH_CLI[@]}"; do
    printf -v "$k" '%s' "${IH_CLI[$k]}"
  done
  [[ -n $HUB_HOST ]] || ih_die "set HUB_HOST (e.g. HUB_HOST=hub.example.com)"
  # An IPv4/IPv6 literal selects IP mode (self-signed certificate); anything else is a domain.
  hub_ip_mode "$HUB_HOST" || [[ $HUB_HOST =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || ih_die "invalid HUB_HOST"
  [[ $SUBNET_PREFIX =~ ^10\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || ih_die "SUBNET_PREFIX must look like 10.73.0"
  for k in HUB_HOST WG_IFACE WG_PORT SUBNET_PREFIX NTFY_TOPIC; do
    ih_conf_set "$k" "${!k}"
  done
  if [[ -n ${BACKUP_RECIPIENT:-} ]]; then
    [[ $BACKUP_RECIPIENT =~ ^age1[a-z0-9]{58}$ ]] || ih_die "BACKUP_RECIPIENT must be an age1... public key"
    printf '%s\n' "$BACKUP_RECIPIENT" | (umask 022 && cat >"$DEVMESH_ETC/backup.recipients")
  fi
}

step_timers() {
  if ((IH_CONTAINER)); then
    ih_log "container: gc, check and backup run from the entrypoint loop"
    return 0
  fi
  ih_log "timers: gc, check, backup"
  install -m 0644 "$IH_SRC"/server/systemd/devmesh-*.service "$IH_SRC"/server/systemd/devmesh-*.timer /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now devmesh-gc.timer devmesh-check.timer >/dev/null
  if [[ -s $DEVMESH_ETC/backup.recipients ]]; then
    systemctl enable --now devmesh-backup.timer >/dev/null
  else
    ih_log "no BACKUP_RECIPIENT yet: backups disabled (rerun with BACKUP_RECIPIENT=age1...)"
  fi
}

main() {
  local restore="" web=1
  while (($#)); do
    case $1 in
      --restore)
        restore=${2:-}
        shift
        ;;
      --no-web) web=0 ;;
      --container) IH_CONTAINER=1 ;;
      *) ih_die "unknown option $1" ;;
    esac
    shift
  done
  [[ ${DEVMESH_ALLOW_NONROOT:-0} == 1 || $EUID -eq 0 ]] || ih_die "run as root"
  ((IH_CONTAINER)) || command -v apt-get >/dev/null || ih_die "hub install supports Debian/Ubuntu only"

  step_config
  step_packages
  install -d -m 0700 "$DEVMESH_BACKUP_DIR"
  ((IH_CONTAINER)) || step_firewall_snapshot
  step_files
  step_hub_keys
  step_users
  step_sudoers
  step_sshd
  step_fail2ban
  if [[ -n $restore ]]; then
    local new_host=$HUB_HOST
    "$DEVMESH_SBIN/devmesh" restore "$restore"
    # The restored hub.conf carries the old host (and, in IP mode, the old pin).
    ih_conf_set HUB_HOST "$new_host"
    # Load the restored devmesh host key so clients keep their pinned key.
    ih_systemctl restart devmesh-sshd.service
  fi
  step_wireguard
  if ((web)); then
    step_nginx
    step_ntfy
  fi
  step_age
  step_timers
  ((IH_CONTAINER)) || step_firewall_report
  if [[ -n $restore ]] && hub_ip_mode; then
    ih_log "IP mode: devices still point at the old hub address. On each device run once: dm repoint $HUB_HOST"
  fi
  ih_log "done. hub: $HUB_HOST  wg: $WG_IFACE $SUBNET_PREFIX.1/24 udp/$WG_PORT"
  "$DEVMESH_SBIN/devmesh" ls
}

main "$@"
