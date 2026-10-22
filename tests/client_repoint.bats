#!/usr/bin/env bats
# dm repoint: follow an IP-mode hub to a new address, only if its SSH host key is the pinned one.

load helpers

KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPinnedPinnedPinnedPinnedPinnedPinnedPinnedPinn'

setup() {
  setup_client
  printf 'DM_NAME=tablet\nDM_KIND=phone\nDM_HUB_HOST=203.0.113.10\nDM_HUB_PIN=oldpin=\nDM_WG_IFACE=devmesh\n' >"$DM_CONF"
  dm_load_conf
  printf '203.0.113.10,10.73.0.1 %s\n' "$KEY" >"$HOME/.ssh/devmesh_known_hosts"
  mkdir -p "$HOME/.ssh/config.d"
  printf 'Host hub-admin\n  HostName 203.0.113.10\n  HostKeyAlias 203.0.113.10\nHost lap\n  HostName 10.73.0.2\n' >"$HOME/.ssh/config.d/devmesh"
  export DM_WG_CONF="$BATS_TEST_TMPDIR/devmesh.conf"
  printf '[Peer]\nPublicKey = abc\nEndpoint = 203.0.113.10:51820\nAllowedIPs = 10.73.0.0/24\n' >"$DM_WG_CONF"
  # The moved hub renders its new address as its HostKeyAlias.
  ssh_reply hub-admin ssh-config "$(DM_HUB_HOST=198.51.100.7 min_cfg 198.51.100.7)"
  ssh_reply hub-admin known-hosts "198.51.100.7,10.73.0.1 $KEY"
  ssh_reply hub-admin hosts "$(printf 'lap\tmachine\t10.73.0.2\t2202\t22\tdev\thome\t-\n')"
}

@test "repoint refuses when the new hub presents another host key" {
  STUB_KEYSCAN_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherOtherOtherOtherOtherOtherOtherOtherOth' run dm_repoint 198.51.100.7
  [ "$status" -ne 0 ]
  [[ $output == *"differs"* ]]
  grep -qx 'DM_HUB_HOST=203.0.113.10' "$DM_CONF"
  grep -q 'Endpoint = 203.0.113.10:51820' "$DM_WG_CONF"
  ! grep -q '^ssh ' "$STUB_LOG"
}

@test "repoint refuses when the new hub does not answer" {
  run dm_repoint 198.51.100.7
  [ "$status" -ne 0 ]
  [[ $output == *"cannot read"* ]]
  grep -qx 'DM_HUB_HOST=203.0.113.10' "$DM_CONF"
}

@test "repoint rewrites node.conf, the WireGuard endpoint and the hub ssh entries on a key match" {
  STUB_KEYSCAN_KEY=$KEY run dm_repoint 198.51.100.7
  [ "$status" -eq 0 ]
  grep -q 'ssh-keyscan .*-p 2222 .*198.51.100.7' "$STUB_LOG"
  grep -qx 'DM_HUB_HOST=198.51.100.7' "$DM_CONF"
  ! grep -q 'DM_HUB_PIN' "$DM_CONF"
  grep -qx 'Endpoint = 198.51.100.7:51820' "$DM_WG_CONF"
  grep -q '^ssh .*hub-admin ssh-config' "$STUB_LOG"
  grep -qx '  HostName 198.51.100.7' "$HOME/.ssh/config.d/devmesh"
  [[ $output == *"refreshed"* ]]
}

@test "repoint puts IPv6 endpoints in brackets" {
  STUB_KEYSCAN_KEY=$KEY run dm_repoint 2001:db8::7
  [ "$status" -eq 0 ]
  grep -qx 'Endpoint = \[2001:db8::7\]:51820' "$DM_WG_CONF"
}

@test "repoint prints the sudo commands for root-owned files instead of escalating" {
  chmod 0444 "$DM_CONF" "$DM_WG_CONF"
  [ ! -w "$DM_CONF" ] || skip "running as root"
  STUB_KEYSCAN_KEY=$KEY run dm_repoint 198.51.100.7
  [ "$status" -eq 0 ]
  [[ $output == *"sudo sed"*"$DM_CONF"* ]]
  [[ $output == *"sudo systemctl restart wg-quick@devmesh"* ]]
  grep -qx 'DM_HUB_HOST=203.0.113.10' "$DM_CONF"
}

@test "repoint validates its argument" {
  run dm_repoint
  [ "$status" -ne 0 ]
  run dm_repoint '1.2.3.4;rm -rf /'
  [ "$status" -ne 0 ]
}

@test "repoint moves the hub address in the machine's own known_hosts, same key" {
  mkdir -p "$HOME/.config/devmesh"
  printf '203.0.113.10,10.73.0.1 %s\n203.0.113.100 %s\n' "$KEY" "$KEY" >"$HOME/.config/devmesh/known_hosts"
  dm_platform() { printf 'macos\n'; }
  STUB_KEYSCAN_KEY=$KEY run dm_repoint 198.51.100.7
  [ "$status" -eq 0 ]
  grep -qx "198.51.100.7,10.73.0.1 $KEY" "$HOME/.config/devmesh/known_hosts"
  # A longer address that merely starts with the old one is left alone.
  grep -qx "203.0.113.100 $KEY" "$HOME/.config/devmesh/known_hosts"
}

@test "on a Linux machine the root-only WireGuard config and known_hosts get sudo commands" {
  unset DM_WG_CONF
  dm_platform() { printf 'linux\n'; }
  dm_repoint_node_known_hosts() { printf '/etc/devmesh/known_hosts\n'; }
  STUB_KEYSCAN_KEY=$KEY run dm_repoint 198.51.100.7
  [ "$status" -eq 0 ]
  [[ $output == *"sudo sed -i.bak -E 's|^(Endpoint = )"*"/etc/wireguard/devmesh.conf"* ]]
  [[ $output == *"sudo systemctl restart wg-quick@devmesh"* ]]
  [[ $output == *"/etc/devmesh/known_hosts"* ]]
}
