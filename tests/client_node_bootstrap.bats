#!/usr/bin/env bats
# Machine helper (devmesh-node) and enrollment bootstrap, including the client<->hub protocol.

load helpers

node_env() {
  export NODE_ETC="$BATS_TEST_TMPDIR/node" NODE_STATE="$BATS_TEST_TMPDIR/nstate"
  mkdir -p "$NODE_ETC"
  cat >"$NODE_ETC/node.conf" <<EOF
DM_NAME=lap
DM_PORT=2202
DM_HUB_HOST=hub.example.test
DM_HUB_WG_PUB=$(new_wg_pub)
DM_WG_IFACE=devmesh
DM_WG_PORT=51820
DM_WATCH_TOPIC=devmesh-topic
EOF
  # shellcheck source=/dev/null
  source "$REPO/client/sbin/devmesh-node"
  node_load
}

setup() {
  setup_hub
  node_env
}

@test "node: key list must be bare tagged ed25519 keys" {
  k=$(new_ssh_pub "$BATS_TEST_TMPDIR/k")
  printf '%s devmesh:lap\n%s devmesh:tablet\n' "$k" "$k" >"$BATS_TEST_TMPDIR/ok"
  node_valid_keys "$BATS_TEST_TMPDIR/ok"
  printf 'command="sh" %s devmesh:lap\n' "$k" >"$BATS_TEST_TMPDIR/bad1"
  ! node_valid_keys "$BATS_TEST_TMPDIR/bad1"
  printf '%s someone-else\n' "$k" >"$BATS_TEST_TMPDIR/bad2"
  ! node_valid_keys "$BATS_TEST_TMPDIR/bad2"
  : >"$BATS_TEST_TMPDIR/empty"
  ! node_valid_keys "$BATS_TEST_TMPDIR/empty"
}

@test "node: reresolve only when the hub handshake is stale" {
  printf '%s %s\n' "$DM_HUB_WG_PUB" "$(date +%s)" >"$BATS_TEST_TMPDIR/hs"
  STUB_WG_HANDSHAKES="$BATS_TEST_TMPDIR/hs" node_reresolve
  ! grep -q 'wg set' "$STUB_LOG"
  printf '%s %s\n' "$DM_HUB_WG_PUB" "$(($(date +%s) - 600))" >"$BATS_TEST_TMPDIR/hs"
  STUB_WG_HANDSHAKES="$BATS_TEST_TMPDIR/hs" node_reresolve
  grep -q "wg set devmesh peer $DM_HUB_WG_PUB endpoint hub.example.test:51820" "$STUB_LOG"
}

@test "node: hubwatch alerts after 3 failures, once, then on recovery" {
  node_hub_ok() { return 1; }
  node_hubwatch
  node_hubwatch
  ! grep -q '^curl' "$STUB_LOG"
  node_hubwatch
  node_hubwatch
  [ "$(grep -c 'hub is down' "$STUB_LOG")" -eq 1 ]
  grep -q 'https://ntfy.sh/devmesh-topic' "$STUB_LOG"
  node_hub_ok() { return 0; }
  node_hubwatch
  grep -q 'hub is back' "$STUB_LOG"
}

@test "bootstrap: client WireGuard config routes only the devmesh subnet" {
  export DM_IP=10.73.0.9 DM_HUB_WG_PUB=PUB DM_HUB_HOST=hub.example.test DM_WG_PORT=51820 DM_SUBNET_PREFIX=10.73.0
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_common.sh"
  run bs_wg_conf PRIV 1280
  [[ $output == *"Address = 10.73.0.9/24"* ]]
  [[ $output == *"MTU = 1280"* ]]
  [[ $output == *"AllowedIPs = 10.73.0.0/24"* ]]
  [[ $output == *"PersistentKeepalive = 25"* ]]
  [[ $output != *"0.0.0.0/0"* ]]
}

@test "bootstrap: ssh Include goes first and edits are idempotent" {
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_common.sh"
  cfg="$BATS_TEST_TMPDIR/sshhome/config"
  mkdir -p "${cfg%/*}"
  printf 'Host *\n  User x\n' >"$cfg"
  bs_ensure_include "$cfg"
  bs_ensure_include "$cfg"
  [ "$(head -n1 "$cfg")" = "Include config.d/devmesh" ]
  [ "$(grep -c Include "$cfg")" -eq 1 ]
  bs_ensure_line "$BATS_TEST_TMPDIR/rc" "source x"
  bs_ensure_line "$BATS_TEST_TMPDIR/rc" "source x"
  [ "$(grep -c 'source x' "$BATS_TEST_TMPDIR/rc")" -eq 1 ]
}

@test "bootstrap: sshd adds the LAN address only while on a trusted LAN" {
  export DM_DIST_DIR="$REPO/client" DM_IP=10.73.0.9 BS_RUN=$BATS_TEST_TMPDIR/run
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_linux.sh"
  run linux_sshd_conf dev
  [[ $output != *"ListenAddress 192.168"* ]]
  [[ $output != *"0.0.0.0"* ]]
  mkdir -p "$BS_RUN"
  printf '192.168.18.26 192.168.18.0/24 wlp1s0\n' >"$BS_RUN/lan"
  run linux_sshd_conf dev
  [[ $output == *$'ListenAddress 10.73.0.9\nListenAddress 127.0.0.1\nListenAddress 192.168.18.26'* ]]
  printf '010.0.0.1 x y\n' >"$BS_RUN/lan"
  run linux_sshd_conf dev
  [[ $output != *"010.0.0.1"* ]]
}

# refresh_env SSHD_OK — an enrolled machine's sshd drop-in (old format) and an sshd stub.
refresh_env() {
  export DM_DIST_DIR="$REPO/client" BS_SSHD_DIR="$BATS_TEST_TMPDIR/sshd" BS_ETC="$NODE_ETC"
  export BS_RUN=$BATS_TEST_TMPDIR/run
  export BS_POLKIT_DIR=$BATS_TEST_TMPDIR/polkit/rules.d
  mkdir -p "$BS_RUN"
  printf '192.168.18.26 192.168.18.0/24 wlp1s0\n' >"$BS_RUN/lan"
  unset DM_IP
  printf 'DM_IP=10.73.0.9\n' >>"$NODE_ETC/node.conf"
  mkdir -p "$BS_SSHD_DIR/sshd_config.d" "$BATS_TEST_TMPDIR/bin"
  printf '# old\nListenAddress 10.73.0.9\nListenAddress 127.0.0.1\nMatch User dev\n    AuthorizedKeysFile x\nMatch all\n' \
    >"$BS_SSHD_DIR/sshd_config.d/10-devmesh.conf"
  printf '#!/bin/sh\necho "sshd $*" >>"$STUB_LOG"\nexit %s\n' "$1" >"$BATS_TEST_TMPDIR/bin/sshd"
  printf '#!/bin/sh\n' >"$BATS_TEST_TMPDIR/bin/install"
  chmod +x "$BATS_TEST_TMPDIR/bin/sshd" "$BATS_TEST_TMPDIR/bin/install"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_linux.sh"
}

@test "update: the sshd drop-in is re-rendered for its user and sshd restarted once" {
  refresh_env 0
  linux_sshd_refresh
  dropin=$BS_SSHD_DIR/sshd_config.d/10-devmesh.conf
  grep -qxF "ListenAddress 192.168.18.26" "$dropin"
  grep -qxF "ListenAddress 10.73.0.9" "$dropin"
  grep -qxF "Match User dev" "$dropin"
  [ "$(grep -c 'systemctl restart' "$STUB_LOG")" -eq 1 ]
  linux_sshd_refresh
  [ "$(grep -c 'systemctl restart' "$STUB_LOG")" -eq 1 ]
}

@test "update: a drop-in sshd rejects is rolled back and sshd is not restarted" {
  refresh_env 1
  cp "$BS_SSHD_DIR/sshd_config.d/10-devmesh.conf" "$BATS_TEST_TMPDIR/before"
  run linux_sshd_refresh
  [ "$status" -eq 0 ]
  [[ $output == *"kept the previous one"* ]]
  cmp "$BS_SSHD_DIR/sshd_config.d/10-devmesh.conf" "$BATS_TEST_TMPDIR/before"
  ! grep -q 'systemctl restart' "$STUB_LOG"
}

@test "power: update writes a polkit rule for the enrolled user only, once" {
  refresh_env 0
  mkdir -p "$BS_POLKIT_DIR"
  linux_sshd_refresh
  rule=$BS_POLKIT_DIR/50-devmesh-power.rules
  grep -qF 'subject.user == "dev"' "$rule"
  grep -qF '"org.freedesktop.login1.suspend"' "$rule"
  grep -qF '"org.freedesktop.login1.power-off"' "$rule"
  ! grep -q 'multiple-sessions' "$rule"
  [ "$(grep -c 'login1' "$rule")" -eq 2 ]
  [ "$(stat -c %a "$rule" 2>/dev/null || stat -f %Lp "$rule")" = 644 ]
  cp "$rule" "$BATS_TEST_TMPDIR/rule.before"
  run linux_power_refresh
  [[ $output != *polkit* ]]
  cmp "$rule" "$BATS_TEST_TMPDIR/rule.before"
}

@test "power: no polkit on the machine, nothing is written" {
  refresh_env 0
  linux_sshd_refresh
  [ ! -e "$BS_POLKIT_DIR/50-devmesh-power.rules" ]
}

@test "power: an invalid user name never reaches the rule" {
  refresh_env 0
  mkdir -p "$BS_POLKIT_DIR"
  printf 'Match User dev"; evil()\n' >"$BS_SSHD_DIR/sshd_config.d/10-devmesh.conf"
  linux_power_refresh
  [ ! -e "$BS_POLKIT_DIR/50-devmesh-power.rules" ]
  linux_polkit 'a b'
  linux_polkit 'Root'
  [ ! -e "$BS_POLKIT_DIR/50-devmesh-power.rules" ]
}

@test "power: only the active WiFi connection gets magic wake-on-wlan, other profiles are left alone" {
  refresh_env 0
  u1=11111111-1111-4111-8111-111111111111
  u2=22222222-2222-4222-8222-222222222222
  printf '%s:802-11-wireless\n%s:802-3-ethernet\n' "$u1" "$u2" >"$BATS_TEST_TMPDIR/cons"
  u3=33333333-3333-4333-8333-333333333333
  printf '%s:802-11-wireless\n%s:802-3-ethernet\n%s:802-11-wireless\n' "$u1" "$u2" "$u3" >"$BATS_TEST_TMPDIR/cons"
  printf '%s:802-11-wireless\n%s:802-3-ethernet\n' "$u1" "$u2" >"$BATS_TEST_TMPDIR/active"
  export STUB_NMCLI_CONS=$BATS_TEST_TMPDIR/cons STUB_NMCLI_ACTIVE=$BATS_TEST_TMPDIR/active STUB_IW_PHY=1 STUB_IW_CAP=1 STUB_IW_ON=0
  linux_power_refresh
  grep -qxF "nmcli connection modify uuid $u1 802-11-wireless.wake-on-wlan magic" "$STUB_LOG"
  ! grep -q "modify uuid $u2" "$STUB_LOG"
  ! grep -q "modify uuid $u3" "$STUB_LOG"
  grep -qxF "iw phy phy0 wowlan enable magic-packet" "$STUB_LOG"
}

@test "power: off a trusted LAN nothing is armed" {
  refresh_env 0
  u1=11111111-1111-4111-8111-111111111111
  printf '%s:802-11-wireless\n' "$u1" >"$BATS_TEST_TMPDIR/cons"
  export STUB_NMCLI_CONS=$BATS_TEST_TMPDIR/cons STUB_IW_PHY=1 STUB_IW_CAP=1 STUB_IW_ON=0
  rm -f "$BS_RUN/lan"
  linux_power_refresh
  ! grep -q 'connection modify' "$STUB_LOG"
  ! grep -q 'wowlan enable' "$STUB_LOG"
  printf 'garbage x y\n' >"$BS_RUN/lan"
  linux_power_refresh
  ! grep -q 'connection modify' "$STUB_LOG"
  ! grep -q 'wowlan enable' "$STUB_LOG"
}

@test "power: a profile that already has magic is not modified again" {
  refresh_env 0
  u1=11111111-1111-4111-8111-111111111111
  printf '%s:802-11-wireless\n' "$u1" >"$BATS_TEST_TMPDIR/cons"
  export STUB_NMCLI_CONS=$BATS_TEST_TMPDIR/cons STUB_IW_PHY=1 STUB_IW_CAP=1 STUB_IW_ON=1 STUB_NMCLI_WOWLAN=magic
  linux_power_refresh
  ! grep -q 'connection modify' "$STUB_LOG"
  ! grep -q 'wowlan enable' "$STUB_LOG"
}

@test "power: no WiFi card or no magic-packet support, nothing is touched" {
  refresh_env 0
  u1=11111111-1111-4111-8111-111111111111
  printf '%s:802-11-wireless\n' "$u1" >"$BATS_TEST_TMPDIR/cons"
  export STUB_NMCLI_CONS=$BATS_TEST_TMPDIR/cons STUB_IW_PHY=0
  linux_power_refresh
  ! grep -q 'connection modify' "$STUB_LOG"
  export STUB_IW_PHY=1 STUB_IW_CAP=0
  linux_power_refresh
  ! grep -q 'wowlan enable' "$STUB_LOG"
}

@test "bootstrap: sshd drop-in listens on devmesh IP + localhost and resets Match" {
  export DM_DIST_DIR="$REPO/client" DM_IP=10.73.0.9 BS_RUN=$BATS_TEST_TMPDIR/norun
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_linux.sh"
  run linux_sshd_conf dev
  [[ ${lines[2]} == "ListenAddress 10.73.0.9" ]]
  [[ ${lines[3]} == "ListenAddress 127.0.0.1" ]]
  [[ $output == *"PasswordAuthentication no"* ]]
  [[ $output == *"Match User dev"* ]]
  [ "${lines[-1]}" = "Match all" ]
}

@test "bootstrap: reboot windows are staggered by devmesh IP" {
  export DM_DIST_DIR="$REPO/client"
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_linux.sh"
  a=$(DM_IP=10.73.0.2 linux_reboot_time)
  b=$(DM_IP=10.73.0.3 linux_reboot_time)
  [ "$a" = "03:40" ]
  [ "$b" = "04:00" ]
  [[ $(DM_IP=10.73.0.254 linux_reboot_time) =~ ^0[345]:[0-5][0-9]$ ]]
}

@test "protocol: a Linux machine's enrollment fields are accepted by the hub" {
  devmesh invite pc9 >/dev/null
  code=$(invite_code)
  export DM_DIST_DIR="$REPO/client" BS_ETC="$BATS_TEST_TMPDIR/bs-etc" BS_SSHD_DIR="$BATS_TEST_TMPDIR/bs-ssh"
  mkdir -p "$BS_ETC" "$BS_SSHD_DIR" "$BATS_TEST_TMPDIR/u/.ssh"
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_linux.sh"
  bs_wg_key "$BS_ETC/wg.key"
  bs_ssh_keygen "$BS_ETC/tunnel_ed25519" t
  bs_ssh_keygen "$BATS_TEST_TMPDIR/u/.ssh/id_devmesh" c
  ssh-keygen -q -t ed25519 -N '' -f "$BS_SSHD_DIR/ssh_host_ed25519_key"
  export DM_NAME=pc9 DM_KIND=machine DM_HUB_HOST=hub.example.test DM_ENROLL_KEY_FILE="$BATS_TEST_TMPDIR/ek"
  ssh-keygen -q -t ed25519 -N pw -f "$DM_ENROLL_KEY_FILE"
  export DM_ENROLL_PASS=pw
  export STUB_ENROLL_CMD="bash '$REPO/server/sbin/devmesh' _enroll $code"
  bs_enroll /dev/null < <(linux_enroll_fields dev "$BATS_TEST_TMPDIR/u")
  run awk -F'\t' '$1 == "pc9" {print $2, $6}' "$DEVMESH_ETC/registry.tsv"
  [ "$output" = "machine dev" ]
  # Port and color come back from the hub to the bootstrap (no subshell loses them).
  [[ $DM_PORT =~ ^22[0-9]{2}$ && $DM_COLOR =~ ^[0-9]+$ ]]
}

@test "protocol: a Termux device's enrollment fields are accepted by the hub" {
  devmesh invite tab9 --phone >/dev/null
  code=$(invite_code)
  export DM_DIST_DIR="$REPO/client" HOME="$BATS_TEST_TMPDIR/th" TX_CONF_DIR="$BATS_TEST_TMPDIR/th/.config/devmesh"
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_termux.sh"
  export DM_NAME=tab9 DM_KIND=phone DM_HUB_HOST=hub.example.test DM_HUB_IP=10.73.0.1 DM_HUB_HOST_KEY=x
  export DM_ENROLL_KEY_FILE="$BATS_TEST_TMPDIR/ek"
  ssh-keygen -q -t ed25519 -N pw -f "$DM_ENROLL_KEY_FILE"
  export DM_ENROLL_PASS=pw
  termux_keys
  export STUB_ENROLL_CMD="bash '$REPO/server/sbin/devmesh' _enroll $code"
  bs_enroll /dev/null < <(termux_enroll_fields)
  grep -q '^tab9	phone' "$DEVMESH_ETC/registry.tsv"
}

@test "enrollment needs the secret printed by invite" {
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_common.sh"
  export DM_ENROLL_KEY_FILE="$BATS_TEST_TMPDIR/ek" DM_NAME=x DM_HUB_HOST=h
  ssh-keygen -q -t ed25519 -N right -f "$DM_ENROLL_KEY_FILE"
  run env DM_ENROLL_PASS=wrong bash -c "source '$REPO/client/lib/bootstrap_common.sh'; bs_enroll /dev/null </dev/null"
  [ "$status" -ne 0 ]
  [[ $output == *"wrong enrollment secret"* ]]
  run env -u DM_ENROLL_PASS bash -c "source '$REPO/client/lib/bootstrap_common.sh'; bs_enroll /dev/null </dev/null"
  [[ $output == *"missing enrollment secret"* ]]
}

@test "universal join script: refuses without the secret, unpacks and dispatches by platform" {
  devmesh invite any9 >/dev/null
  script="$DEVMESH_WEBROOT/j/$(invite_code)"
  run sh "$script"
  [ "$status" -ne 0 ]
  [[ $output == *"missing secret"* ]]
  # Forced to Termux on a non-Termux host: the embedded client is unpacked, the Termux
  # bootstrap is sourced and refuses this context before touching anything.
  run env -u TERMUX_VERSION DM_FORCE_PLATFORM=termux sh "$script" SECRET
  [ "$status" -ne 0 ]
  [[ $output == *"this bootstrap is for Termux"* ]]
  # Piped like the real one-liner (curl | sh -s SECRET).
  run sh -c "env -u TERMUX_VERSION DM_FORCE_PLATFORM=termux sh -s SECRET < '$script'"
  [[ $output == *"this bootstrap is for Termux"* ]]
}

@test "node: key sync exits cleanly when nothing changed (EXIT trap under set -u)" {
  k=$(new_ssh_pub "$BATS_TEST_TMPDIR/k")
  printf '%s devmesh:lap\n' "$k" >"$NODE_ETC/clients.pub"
  export STUB_SSH_DIR="$BATS_TEST_TMPDIR/replies"
  mkdir -p "$STUB_SSH_DIR/tunnel@hub.example.test"
  cp "$NODE_ETC/clients.pub" "$STUB_SSH_DIR/tunnel@hub.example.test/keys_$(cat "$REPO/VERSION")"
  export STUB_SSH_DIR NODE_SHARE="$REPO"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -eq 0 ]
  [ -z "$(find "$NODE_ETC" -name 'clients.pub.*')" ]
}

@test "node: a revoked machine stops retrying (no fail2ban ban of the home IP)" {
  export STUB_SSH_DENY="tunnel@hub.example.test" NODE_SHARE="$REPO"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -ne 0 ]
  [ -s "$NODE_STATE/revoked" ]
  : >"$STUB_LOG"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -eq 0 ]
  ! grep -q '^ssh ' "$STUB_LOG"
  # After the back-off window it tries again, and a successful login clears the marker.
  printf '%s\n' "$(($(date +%s) - 4000))" >"$NODE_STATE/revoked"
  unset STUB_SSH_DENY
  k=$(new_ssh_pub "$BATS_TEST_TMPDIR/k2")
  export STUB_SSH_DIR="$BATS_TEST_TMPDIR/replies"
  mkdir -p "$STUB_SSH_DIR/tunnel@hub.example.test"
  printf '%s devmesh:lap\n' "$k" >"$STUB_SSH_DIR/tunnel@hub.example.test/keys_$(cat "$REPO/VERSION")"
  run bash "$REPO/client/sbin/devmesh-node" keys-sync
  [ "$status" -eq 0 ]
  [ ! -e "$NODE_STATE/revoked" ]
}

@test "node: ssh to the hub uses the devmesh port" {
  [[ " ${node_ssh_opts[*]} " == *" -p 2222 "* ]]
}

@test "protocol: a Mac enrolls as a machine without sudo (tunnel + host keys, os=macos)" {
  [[ $(uname -s) == Darwin ]] || skip "macOS only"
  devmesh invite mac9 >/dev/null
  code=$(invite_code)
  export DM_DIST_DIR="$REPO/client" HOME="$BATS_TEST_TMPDIR/mh" MX_CONF_DIR="$BATS_TEST_TMPDIR/mh/.config/devmesh"
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_macos.sh"
  export DM_NAME=mac9 DM_KIND=machine DM_HUB_HOST=hub.example.test DM_HUB_IP=10.73.0.1 DM_HUB_HOST_KEY=x
  export DM_ENROLL_KEY_FILE="$BATS_TEST_TMPDIR/ek" DM_ENROLL_PASS=pw
  ssh-keygen -q -t ed25519 -N pw -f "$DM_ENROLL_KEY_FILE"
  macos_keys
  export STUB_ENROLL_CMD="bash '$REPO/server/sbin/devmesh' _enroll $code"
  bs_enroll /dev/null < <(macos_enroll_fields)
  run awk -F'\t' '$1 == "mac9" {print $2, $15}' "$DEVMESH_ETC/registry.tsv"
  [ "$output" = "machine macos" ]
  [[ $DM_PORT =~ ^22[0-9]{2}$ ]]
}

@test "macOS: user-level sshd config is localhost-only, keys-only and valid for the real sshd" {
  [[ $(uname -s) == Darwin ]] || skip "macOS only"
  export DM_DIST_DIR="$REPO/client" HOME="$BATS_TEST_TMPDIR/mh4" MX_CONF_DIR="$BATS_TEST_TMPDIR/mh4/.config/devmesh" MX_BIN=/opt/homebrew/bin
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_macos.sh"
  mkdir -p "$MX_CONF_DIR"
  ssh-keygen -q -t ed25519 -N '' -f "$MX_CONF_DIR/ssh_host_ed25519_key"
  run macos_sshd_config
  [[ $output == *$'Port 2223\nListenAddress 127.0.0.1'* ]]
  [[ $output == *"AuthenticationMethods publickey"* && $output == *"AllowUsers $(id -un)"* ]]
  printf '%s\n' "$output" >"$MX_CONF_DIR/sshd_config"
  run /usr/sbin/sshd -t -f "$MX_CONF_DIR/sshd_config"
  [ "$status" -eq 0 ] || echo "$output"
}

@test "macOS: launchd agents are well-formed plists" {
  [[ $(uname -s) == Darwin ]] || skip "macOS only"
  export DM_DIST_DIR="$REPO/client" MX_CONF_DIR="$BATS_TEST_TMPDIR/c" MX_SHARE="$BATS_TEST_TMPDIR/s" MX_BIN=/opt/homebrew/bin
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_macos.sh"
  macos_plist net.devmesh.test '  <key>KeepAlive</key><true/>' /bin/sh -c "echo a & b" >"$BATS_TEST_TMPDIR/p.plist"
  run plutil -lint "$BATS_TEST_TMPDIR/p.plist"
  [ "$status" -eq 0 ] || echo "$output"
}

@test "macOS: WireGuard config stays private under ~/.config and routes only the mesh" {
  export DM_DIST_DIR="$REPO/client" HOME="$BATS_TEST_TMPDIR/mh2" MX_CONF_DIR="$BATS_TEST_TMPDIR/mh2/.config/devmesh"
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_macos.sh"
  export DM_IP=10.73.0.9 DM_HUB_WG_PUB=PUB DM_HUB_HOST=hub.example.test DM_WG_PORT=51820 DM_SUBNET_PREFIX=10.73.0
  mkdir -p "$MX_CONF_DIR"
  wg genkey >"$MX_CONF_DIR/wg.key"
  f=$(macos_wireguard_conf)
  [ "$f" = "$MX_CONF_DIR/wireguard/devmesh.conf" ]
  grep -qx 'AllowedIPs = 10.73.0.0/24' "$f"
  [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 600 ]
}

@test "dm re-executes under bash >= 4 when started by macOS bash 3.2" {
  [[ -x /bin/bash && $(/bin/bash -c 'echo ${BASH_VERSINFO[0]}') -lt 4 ]] || skip "no bash 3 here"
  run env DM_CONF=/nonexistent /bin/bash "$REPO/client/bin/dm" help
  [ "$status" -eq 0 ]
  [[ $output == *"dm new"* ]]
}

@test "macOS: client install succeeds whether or not ~/.bashrc exists (set -e)" {
  export DM_DIST_DIR="$REPO/client" HOME="$BATS_TEST_TMPDIR/mh3" MX_SHARE="$BATS_TEST_TMPDIR/mh3/share" MX_BIN="$BATS_TEST_TMPDIR/mh3/bin" DM_VERSION=0.1.0
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/stub"
  printf '#!/bin/sh\necho "$@" >>"%s/launchctl.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/stub/launchctl"
  chmod +x "$BATS_TEST_TMPDIR/stub/launchctl"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH" run bash -c "set -euo pipefail; source '$REPO/client/lib/bootstrap_macos.sh'; macos_install_client"
  [ "$status" -eq 0 ]
  grep -q 'devmesh.sh' "$HOME/.zshrc"
  [ ! -e "$HOME/.bashrc" ]
  # The idle-session reaper agent: every 5 minutes, loaded on install/update.
  p="$HOME/Library/LaunchAgents/net.devmesh.claude-reap.plist"
  grep -q '<integer>300</integer>' "$p"
  grep -q '<string>_claude_reap</string>' "$p"
  grep -q 'net.devmesh.claude-reap' "$BATS_TEST_TMPDIR/launchctl.log"
  if [[ $(uname -s) == Darwin ]]; then plutil -lint "$p"; fi
  [ -x "$MX_BIN/dm" ]
}

@test "Linux: the idle-session reaper is a user timer every 5 minutes, enabled for all users on update" {
  u="$REPO/client/systemd-user"
  grep -q '^ExecStart=/usr/local/bin/dm _claude_reap$' "$u/devmesh-claude-reap.service"
  grep -q '^OnUnitActiveSec=5min$' "$u/devmesh-claude-reap.timer"
  grep -q '^WantedBy=timers.target$' "$u/devmesh-claude-reap.timer"
  run grep -c 'linux_enable_reap' "$REPO/client/lib/bootstrap_linux.sh"
  [ "$output" -ge 3 ]
  mkdir -p "$BATS_TEST_TMPDIR/lstub"
  printf '#!/bin/sh\necho "$@" >>"%s/sc.log"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/lstub/systemctl"
  printf '#!/bin/sh\n' >"$BATS_TEST_TMPDIR/lstub/loginctl"
  chmod +x "$BATS_TEST_TMPDIR/lstub/"*
  PATH="$BATS_TEST_TMPDIR/lstub:$PATH" run bash -c "source '$REPO/client/lib/bootstrap_linux.sh'; linux_enable_reap"
  [ "$status" -eq 0 ]
  grep -qx -- '--global enable devmesh-claude-reap.timer' "$BATS_TEST_TMPDIR/sc.log"
}
