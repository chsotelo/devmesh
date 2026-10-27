# shellcheck shell=bash
# Enrollment of a Linux machine. Sourced by the hub-generated bootstrap (run with sudo).
# Idempotent: re-running after a successful enrollment only re-applies local config.

# shellcheck source=bootstrap_common.sh
source "$DM_DIST_DIR/lib/bootstrap_common.sh"

BS_ETC=${BS_ETC:-/etc/devmesh}
BS_PREFIX=${BS_PREFIX:-/usr/local}
BS_SSHD_DIR=${BS_SSHD_DIR:-/etc/ssh}
BS_SYSTEMD=${BS_SYSTEMD:-/etc/systemd}
BS_WG_DIR=${BS_WG_DIR:-/etc/wireguard}
BS_RUN=${BS_RUN:-/run/devmesh}

linux_pkg_install() {
  bs_log "installing packages"
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends wireguard-tools openssh-server mosh tmux fzf python3 iproute2 curl
  elif command -v dnf >/dev/null; then
    dnf install -y -q --setopt=install_weak_deps=False wireguard-tools openssh-server mosh tmux fzf python3 iproute curl
  elif command -v pacman >/dev/null; then
    pacman -Sy --needed --noconfirm wireguard-tools openssh mosh tmux fzf python iproute2 curl
  elif command -v zypper >/dev/null; then
    zypper -n install wireguard-tools openssh mosh tmux fzf python3 iproute2 curl
  else
    bs_die "unsupported package manager (need apt, dnf, pacman or zypper)"
  fi
}

linux_default_mac() {
  local dev
  dev=$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  [[ -n $dev && -r /sys/class/net/$dev/address ]] && tr 'A-F' 'a-f' <"/sys/class/net/$dev/address"
}

# linux_enroll_fields USER HOME — the public half of every key, plus identity facts.
linux_enroll_fields() {
  local user=$1 home=$2 mac
  printf 'wg %s\n' "$(wg pubkey <"$BS_ETC/wg.key")"
  printf 'client %s\n' "$(bs_pub_bare "$home/.ssh/id_devmesh.pub")"
  printf 'tunnel %s\n' "$(bs_pub_bare "$BS_ETC/tunnel_ed25519.pub")"
  printf 'host %s\n' "$(bs_pub_bare "$BS_SSHD_DIR/ssh_host_ed25519_key.pub")"
  printf 'user %s\n' "$user"
  printf 'os linux\n'
  mac=$(linux_default_mac || true)
  [[ -n $mac ]] && printf 'mac %s\n' "$mac"
  return 0
}

linux_keys() {
  local user=$1 home=$2
  bs_log "generating device keys locally"
  install -d -m 0755 "$BS_ETC"
  install -d -m 0700 -o "$user" -g "$(id -gn "$user")" "$home/.ssh"
  bs_wg_key "$BS_ETC/wg.key"
  bs_ssh_keygen "$BS_ETC/tunnel_ed25519" "devmesh-tunnel:$DM_NAME"
  bs_ssh_keygen "$home/.ssh/id_devmesh" "devmesh:$DM_NAME" "$user"
  [[ -s $BS_SSHD_DIR/ssh_host_ed25519_key.pub ]] || ssh-keygen -A
  bs_hub_known_hosts >"$BS_ETC/known_hosts"
}

linux_install_client() {
  bs_log "installing devmesh client $DM_VERSION"
  install -d "$BS_PREFIX/bin" "$BS_PREFIX/sbin" "$BS_PREFIX/share/devmesh"
  install -m 0755 "$DM_DIST_DIR/bin/dm" "$BS_PREFIX/bin/dm"
  install -m 0755 "$DM_DIST_DIR/sbin/devmesh-node" "$DM_DIST_DIR/sbin/devmesh-node-fw" "$BS_PREFIX/sbin/"
  rm -rf "$BS_PREFIX/share/devmesh/lib" "$BS_PREFIX/share/devmesh/tmux" \
    "$BS_PREFIX/share/devmesh/shell" "$BS_PREFIX/share/devmesh/hooks"
  cp -R "$DM_DIST_DIR/lib" "$DM_DIST_DIR/tmux" "$DM_DIST_DIR/shell" "$DM_DIST_DIR/hooks" "$BS_PREFIX/share/devmesh/"
  printf '%s\n' "$DM_VERSION" >"$BS_PREFIX/share/devmesh/VERSION"
  chmod -R u=rwX,go=rX "$BS_PREFIX/share/devmesh"
  bs_install_tui "$DM_DIST_DIR/bin" "$BS_PREFIX/share/devmesh/bin"
  install -d "$BS_SYSTEMD/system" "$BS_SYSTEMD/user"
  install -m 0644 "$DM_DIST_DIR"/systemd/* "$BS_SYSTEMD/system/"
  install -m 0644 "$DM_DIST_DIR"/systemd-user/* "$BS_SYSTEMD/user/"
  linux_mesh_firewall
}

# Unattended updates (devmesh-node update): installs only bundles an approver signed.
linux_enable_update() {
  systemctl daemon-reload
  systemctl enable --now devmesh-update.timer >/dev/null 2>&1 || bs_log "could not enable devmesh-update.timer"
  systemctl enable --now devmesh-lan.timer >/dev/null 2>&1 || bs_log "could not enable devmesh-lan.timer"
  systemctl start devmesh-lan.service >/dev/null 2>&1 || true
}

# WireGuard interface name of this machine: node.conf, else the enrollment environment.
linux_wg_iface() {
  local iface=""
  [[ -r $BS_ETC/node.conf ]] && iface=$(sed -n 's/^DM_WG_IFACE=//p' "$BS_ETC/node.conf")
  iface=${iface:-${DM_WG_IFACE:-devmesh}}
  [[ $iface =~ ^[a-z][a-z0-9]{0,14}$ ]] || return 1
  printf '%s\n' "$iface"
}

# Mesh firewall hooks: devmesh-node-fw runs as PostUp/PostDown of the WireGuard interface.
# Added once (a config that already names devmesh-node-fw is left alone) and applied now when
# the interface is already up, so "dm update" protects machines enrolled before this existed.
# Never fatal: a machine without iptables joins exactly as before.
linux_mesh_firewall() {
  local iface conf fw="$BS_PREFIX/sbin/devmesh-node-fw" tmp
  iface=$(linux_wg_iface) || {
    bs_log "warning: invalid WireGuard interface name; mesh firewall not configured"
    return 0
  }
  conf="$BS_WG_DIR/$iface.conf"
  command -v iptables >/dev/null || {
    bs_log "warning: iptables not found; the mesh firewall is off (install iptables, then run: dm update)"
    return 0
  }
  # Second layer of path L; sshd binds the LAN only on a trusted one (devmesh-node lan).
  NODE_ETC=$BS_ETC NODE_RUN=$BS_RUN "$fw" lan || bs_log "warning: could not apply the LAN firewall (see above)"
  [[ -f $conf ]] || return 0
  if ! grep -q 'devmesh-node-fw' "$conf"; then
    tmp=$(mktemp)
    awk -v up="PostUp = $fw up %i || true" -v down="PostDown = $fw down %i || true" \
      '{ print } !done && /^\[Interface\][[:space:]]*$/ { print up; print down; done = 1 }' "$conf" >"$tmp"
    # cat keeps the mode and owner of the original file.
    cat "$tmp" >"$conf"
    rm -f "$tmp"
  fi
  if wg show "$iface" >/dev/null 2>&1; then
    "$fw" up "$iface" || bs_log "warning: could not apply the mesh firewall (see above)"
  fi
  return 0
}

# sshd: the devmesh IP and localhost (reverse tunnel) always; the machine's LAN address too,
# but only while it is on a LAN its owner trusted ($BS_RUN/lan, "devmesh-node lan"). On any
# other network sshd is not bound there at all, whatever happens to the firewall.
linux_sshd_listen() {
  local lan=""
  [[ -r $BS_RUN/lan ]] && read -r lan _ <"$BS_RUN/lan"
  printf '# Generated by devmesh. sshd listens on the devmesh IP, localhost (reverse tunnel)\n'
  printf '# and, on a trusted LAN only, the LAN address (path L).\n'
  printf 'ListenAddress %s\nListenAddress 127.0.0.1\n' "$DM_IP"
  if [[ ${lan:-} =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]]; then
    printf 'ListenAddress %s\n' "$lan"
  fi
  return 0
}

linux_sshd_conf() {
  local user=$1
  linux_sshd_listen
  cat <<EOF
ClientAliveInterval 15
ClientAliveCountMax 3
PasswordAuthentication no
KbdInteractiveAuthentication no
Match User $user
    AuthorizedKeysFile .ssh/authorized_keys $BS_ETC/clients.pub
Match all
EOF
}

# Debian/Ubuntu call it "ssh"; Fedora/Arch/openSUSE "sshd".
linux_sshd_service() {
  if systemctl cat ssh.service >/dev/null 2>&1; then
    printf 'ssh\n'
  else
    printf 'sshd\n'
  fi
}

linux_sshd() {
  local user=$1 main="$BS_SSHD_DIR/sshd_config" dropin="$BS_SSHD_DIR/sshd_config.d/10-devmesh.conf" svc
  bs_log "configuring sshd (devmesh IP + localhost, trusted LAN only, keys only)"
  install -d "$BS_SSHD_DIR/sshd_config.d"
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$main"; then
    cp -p "$main" "$main.devmesh-bak"
    {
      printf 'Include /etc/ssh/sshd_config.d/*.conf\n'
      cat "$main.devmesh-bak"
    } >"$main"
  fi
  # Bind the devmesh IP even before the WireGuard interface is up.
  printf 'net.ipv4.ip_nonlocal_bind = 1\n' >/etc/sysctl.d/90-devmesh.conf
  sysctl -q -p /etc/sysctl.d/90-devmesh.conf
  [[ -e $BS_ETC/clients.pub ]] || install -m 0644 /dev/null "$BS_ETC/clients.pub"
  linux_sshd_conf "$user" >"$dropin"
  # With socket activation (Ubuntu >= 22.10) sshd has not run yet and "sshd -t" needs this.
  install -d -m 0755 /run/sshd
  if ! sshd -t; then
    rm -f "$dropin"
    bs_die "sshd rejected the devmesh config; nothing was changed"
  fi
  # Socket activation ignores ListenAddress (Ubuntu >= 22.10): use the plain service.
  if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    systemctl disable --now ssh.socket
  fi
  svc=$(linux_sshd_service)
  systemctl enable "$svc" >/dev/null 2>&1 || true
  systemctl restart "$svc"
}

# linux_sshd_refresh — dm update and "devmesh-node lan": re-render the sshd drop-in of an
# enrolled machine (user from its Match line) and restart sshd only when it changed. A drop-in
# that sshd rejects, or that it cannot restart with, is rolled back: never left without ssh.
linux_sshd_refresh() {
  local dropin="$BS_SSHD_DIR/sshd_config.d/10-devmesh.conf" user new svc
  [[ -r $dropin ]] || return 0
  user=$(sed -n 's/^Match User //p' "$dropin" | head -n1)
  [[ $user =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] || return 0
  DM_IP=${DM_IP:-$(sed -n 's/^DM_IP=//p' "$BS_ETC/node.conf" 2>/dev/null)}
  [[ $DM_IP =~ ^[0-9.]+$ ]] || return 0
  new=$(linux_sshd_conf "$user")
  [[ $new == "$(cat "$dropin")" ]] && return 0
  svc=$(linux_sshd_service)
  cp -p "$dropin" "$dropin.prev"
  printf '%s\n' "$new" >"$dropin"
  install -d -m 0755 /run/sshd
  if ! sshd -t; then
    mv -f "$dropin.prev" "$dropin"
    bs_log "warning: sshd rejected the new devmesh config; kept the previous one"
    return 0
  fi
  if ! systemctl restart "$svc"; then
    mv -f "$dropin.prev" "$dropin"
    systemctl restart "$svc" || true
    bs_log "warning: sshd did not restart with the new devmesh config; back to the previous one"
    return 0
  fi
  rm -f "$dropin.prev"
}

# R28: security-only automatic updates; reboots allowed in a nightly window, staggered by
# the devmesh IP so two machines never reboot at the same time.
linux_reboot_time() {
  local octet=${DM_IP##*.} minutes
  minutes=$((180 + (octet * 20) % 180)) # 03:00..05:59, 20 min apart
  printf '%02d:%02d\n' $((minutes / 60)) $((minutes % 60))
}

linux_auto_updates() {
  if ! command -v apt-get >/dev/null; then
    bs_log "automatic updates: configure your distro's tool (dnf-automatic, ...) with a nightly reboot window"
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends unattended-upgrades >/dev/null
  cat >/etc/apt/apt.conf.d/52devmesh-upgrades <<EOF
// Generated by devmesh (R28): security updates, staggered reboot window.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "$(linux_reboot_time)";
EOF
  bs_log "automatic security updates on; reboot window $(linux_reboot_time)"
}

linux_services() {
  bs_log "enabling WireGuard, tunnel and timers"
  systemctl daemon-reload
  systemctl enable --now "wg-quick@$DM_WG_IFACE"
  systemctl enable --now devmesh-tunnel.service devmesh-keys.timer devmesh-reresolve.timer devmesh-update.timer
  systemctl enable --now devmesh-lan.timer
  if [[ ${DM_WATCH_TOPIC:--} != - ]]; then
    systemctl enable --now devmesh-hubwatch.timer
  fi
  devmesh-node keys-sync || true
}

linux_user_setup() {
  local user=$1 home=$2 group rc line wants="$2/.config/systemd/user/default.target.wants"
  group=$(id -gn "$user")
  bs_log "user setup for $user (tmux, shell, ssh)"
  loginctl enable-linger "$user" || true
  install -d -o "$user" -g "$group" "$home/.config" "$home/.config/systemd" "$home/.config/systemd/user" "$wants"
  ln -sf "$BS_SYSTEMD/user/devmesh-tmux.service" "$wants/devmesh-tmux.service"
  chown -h "$user:$group" "$wants/devmesh-tmux.service"

  cat >"$home/.tmux.devmesh.conf" <<EOF
# Generated by devmesh for $DM_NAME.
set -g @dm_name "$DM_NAME"
set -g status-style "bg=colour$DM_COLOR,fg=white"
set -g @dm_color "$DM_COLOR"
source-file $BS_PREFIX/share/devmesh/tmux/base.conf
EOF
  bs_ensure_line "$home/.tmux.conf" "source-file -q ~/.tmux.devmesh.conf"

  line="[ -r $BS_PREFIX/share/devmesh/shell/devmesh.sh ] && . $BS_PREFIX/share/devmesh/shell/devmesh.sh"
  [[ -f $home/.bashrc || ! -f $home/.zshrc ]] && bs_ensure_line "$home/.bashrc" "$line"
  [[ -f $home/.zshrc ]] && bs_ensure_line "$home/.zshrc" "$line"

  bs_hub_known_hosts >"$home/.ssh/devmesh_known_hosts"
  bs_ensure_include "$home/.ssh/config"
  bs_ssh_bootstrap_config >"$home/.ssh/config.d/devmesh"
  for rc in .tmux.devmesh.conf .tmux.conf .bashrc .zshrc .ssh; do
    [[ -e $home/$rc ]] && chown -R "$user:$group" "$home/$rc"
  done

  # systemctl --user -M needs systemd >= 248; the XDG_RUNTIME_DIR form works on older ones.
  local uid
  uid=$(id -u "$user")
  for _ in 1 2 3 4 5; do
    [[ -d /run/user/$uid ]] && break
    sleep 1
  done
  sudo -u "$user" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user daemon-reload >/dev/null 2>&1 || true
  sudo -u "$user" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user start devmesh-tmux.service >/dev/null 2>&1 ||
    bs_log "tmux keeper will start at next login/boot"
  sudo -u "$user" -H "$BS_PREFIX/bin/dm" refresh || bs_log "dm refresh failed; run it later as $user"
}

bootstrap_main() {
  bs_require_env
  # Installed files must be world-readable; secrets are created with explicit modes.
  umask 022
  [[ $EUID -eq 0 ]] || bs_die "run this with sudo"
  local user=${DM_USER:-${SUDO_USER:-}} home
  [[ -n $user && $user != root ]] || bs_die "run with sudo from your normal user account"
  home=$(getent passwd "$user" | cut -d: -f6)
  [[ -d $home ]] || bs_die "no home directory for $user"

  linux_pkg_install
  linux_keys "$user" "$home"
  bs_trust_setup "$BS_ETC/allowed_signers" "$home/.ssh/id_devmesh.pub"
  if bs_already_enrolled "$BS_ETC/node.conf"; then
    bs_log "already enrolled as $DM_NAME; re-applying local config"
  else
    # Not a pipe: bs_enroll must run in this shell to keep the port/color the hub assigns.
    bs_enroll "$BS_ETC/known_hosts" < <(linux_enroll_fields "$user" "$home")
    # The code is burned now: record it before anything else can fail, so a rerun resumes.
    bs_node_conf >"$BS_ETC/node.conf"
  fi
  install -d -m 0700 /etc/wireguard
  bs_wg_conf "$(cat "$BS_ETC/wg.key")" | (umask 077 && cat >"/etc/wireguard/$DM_WG_IFACE.conf")
  linux_install_client
  bs_node_conf >"$BS_ETC/node.conf"
  linux_sshd "$user"
  linux_services
  linux_auto_updates
  linux_user_setup "$user" "$home"
  printf '\n\033[32m%s ✓\033[0m  wg %s · tunnel :%s · color %s · key %s\n' "$DM_NAME" "$DM_IP" "$DM_PORT" \
    "$DM_COLOR" "$(ssh-keygen -lf "$home/.ssh/id_devmesh.pub" | awk '{print $2}')"
  bs_approve_hint "$home/.ssh/id_devmesh.pub" "$BS_SSHD_DIR/ssh_host_ed25519_key.pub"
  printf 'Next: open a new terminal (it starts inside tmux) or run "dm".\n'
}
