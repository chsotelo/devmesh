#!/usr/bin/env bats
# OSS-25: firewall of a machine's mesh interface (devmesh-node-fw, devmesh-node mesh, dm mesh,
# PostUp/PostDown installation). iptables is the stub in tests/stubs.

load helpers

setup() {
  BATS_TEST_TMPDIR=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  local t=$BATS_TEST_TMPDIR
  export PATH="$REPO/tests/stubs:$PATH"
  export STUB_LOG="$t/stub.log" STUB_IPT="$t/ipt.db"
  : >"$STUB_LOG"
  export NODE_ETC="$t/etc"
  mkdir -p "$NODE_ETC"
  printf 'DM_NAME=lap\nDM_HUB_HOST=hub.example.test\nDM_WG_IFACE=devmesh\n' >"$NODE_ETC/node.conf"
  FW=$REPO/client/sbin/devmesh-node-fw
}

fw() { bash "$FW" "$@"; }
set_open() { printf 'DM_MESH_OPEN="%s"\n' "$1" >>"$NODE_ETC/node.conf"; }
chain_rules() { grep '^DEVMESH-IN ' "$STUB_IPT"; }

EXPECTED_BASE="DEVMESH-IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
DEVMESH-IN -p icmp --icmp-type echo-request -j ACCEPT
DEVMESH-IN -p tcp --dport 22 -j ACCEPT
DEVMESH-IN -p udp --dport 60000:61000 -j ACCEPT"

@test "node-fw: up twice leaves one hook and the chain in the exact order" {
  fw up devmesh
  fw up devmesh
  [ "$(grep -c '^INPUT ' "$STUB_IPT")" -eq 1 ]
  grep -qxF "INPUT -i devmesh -j DEVMESH-IN" "$STUB_IPT"
  [ "$(grep -c '^:DEVMESH-IN$' "$STUB_IPT")" -eq 1 ]
  [ "$(chain_rules)" = "$EXPECTED_BASE
DEVMESH-IN -j DROP" ]
}

@test "node-fw: DM_MESH_OPEN entries go before the final DROP, ranges use a:b" {
  set_open "tcp/8000 udp/5353 tcp/3000-3010"
  fw up devmesh
  [ "$(chain_rules)" = "$EXPECTED_BASE
DEVMESH-IN -p tcp --dport 8000 -j ACCEPT
DEVMESH-IN -p udp --dport 5353 -j ACCEPT
DEVMESH-IN -p tcp --dport 3000:3010 -j ACCEPT
DEVMESH-IN -j DROP" ]
}

@test "node-fw: down leaves nothing behind and never touches other rules" {
  printf 'INPUT -p tcp --dport 443 -j ACCEPT\n' >"$STUB_IPT"
  fw up devmesh
  fw down devmesh
  fw down devmesh
  [ "$(cat "$STUB_IPT")" = "INPUT -p tcp --dport 443 -j ACCEPT" ]
}

@test "node-fw: an invalid DM_MESH_OPEN entry aborts without calling iptables" {
  local bad
  for bad in tcp/0 tcp/70000 tcp/9-3 icmp/1 'tcp/22;rm' tcp/08 tcp/ 8000 'tcp/1-2-3' 'tcp/22$(id)'; do
    : >"$STUB_LOG"
    : >"$STUB_IPT"
    printf 'DM_NAME=lap\nDM_HUB_HOST=h\nDM_MESH_OPEN="tcp/8000 %s"\n' "$bad" >"$NODE_ETC/node.conf"
    run fw up devmesh
    [ "$status" -ne 0 ]
    [[ $output == *"invalid DM_MESH_OPEN entry"* ]]
    ! grep -q '^iptables' "$STUB_LOG"
    [ ! -s "$STUB_IPT" ]
  done
}

@test "node-fw: ports at the edge of the range are accepted" {
  set_open "tcp/1 udp/65535 tcp/1-65535"
  fw up devmesh
  grep -qxF "DEVMESH-IN -p tcp --dport 1:65535 -j ACCEPT" "$STUB_IPT"
}

@test "node-fw: without iptables it warns and succeeds" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  run env PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" /bin/bash "$FW" up devmesh
  [ "$status" -eq 0 ]
  [[ $output == *"iptables not found"* ]]
  run env PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" /bin/bash "$FW" down devmesh
  [ "$status" -eq 0 ]
}

@test "node-fw: refuses a bad interface name and unknown actions" {
  run fw up 'x;rm'
  [ "$status" -eq 2 ]
  run fw sideways devmesh
  [ "$status" -eq 2 ]
  ! grep -q '^iptables' "$STUB_LOG"
}

# --- linux_install_client ------------------------------------------------------------

install_env() {
  local t=$BATS_TEST_TMPDIR
  export DM_DIST_DIR="$REPO/client" DM_VERSION=9.9.9 DM_WG_IFACE=devmesh
  export BS_ETC="$NODE_ETC" BS_PREFIX="$t/prefix" BS_SYSTEMD="$t/systemd" BS_WG_DIR="$t/wg"
  mkdir -p "$BS_WG_DIR"
  printf '[Interface]\nPrivateKey = k\nAddress = 10.73.0.2/24\n\n[Peer]\nPublicKey = p\n' >"$BS_WG_DIR/devmesh.conf"
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_linux.sh"
}

@test "install: PostUp/PostDown are added once under [Interface]" {
  install_env
  linux_install_client
  linux_install_client
  conf=$BS_WG_DIR/devmesh.conf
  [ "$(grep -c '^PostUp' "$conf")" -eq 1 ]
  [ "$(grep -c '^PostDown' "$conf")" -eq 1 ]
  grep -qxF "PostUp = $BS_PREFIX/sbin/devmesh-node-fw up %i || true" "$conf"
  grep -qxF "PostDown = $BS_PREFIX/sbin/devmesh-node-fw down %i || true" "$conf"
  [ "$(awk '/^\[Peer\]/ {exit} /^PostUp/ {n++} END {print n}' "$conf")" -eq 1 ]
  [ -x "$BS_PREFIX/sbin/devmesh-node-fw" ]
}

@test "install: a config that already has the hooks is left byte for byte" {
  install_env
  printf '[Interface]\nAddress = 10.73.0.2/24\nPostUp = /custom/devmesh-node-fw up %%i\n\n[Peer]\nPublicKey = p\n' >"$BS_WG_DIR/devmesh.conf"
  cp "$BS_WG_DIR/devmesh.conf" "$BATS_TEST_TMPDIR/before"
  linux_install_client
  cmp "$BS_WG_DIR/devmesh.conf" "$BATS_TEST_TMPDIR/before"
}

@test "install: applies the firewall now only when the interface is up" {
  install_env
  linux_install_client
  ! grep -q 'iptables -N DEVMESH-IN' "$STUB_LOG"
  STUB_WG_UP=1 linux_install_client
  grep -q 'iptables -N DEVMESH-IN' "$STUB_LOG"
  [ "$(grep -c '^INPUT ' "$STUB_IPT")" -eq 1 ]
}

@test "install: without iptables it warns, changes nothing and does not fail" {
  install_env
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cp "$BS_WG_DIR/devmesh.conf" "$BATS_TEST_TMPDIR/before"
  PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" run linux_install_client
  [ "$status" -eq 0 ]
  [[ $output == *"iptables not found"* ]]
  cmp "$BS_WG_DIR/devmesh.conf" "$BATS_TEST_TMPDIR/before"
}

@test "install: the interface name comes from node.conf (dm update has no enrollment env)" {
  install_env
  unset DM_WG_IFACE
  printf 'DM_WG_IFACE=wgmesh\n' >"$BS_ETC/node.conf"
  cp "$BS_WG_DIR/devmesh.conf" "$BS_WG_DIR/wgmesh.conf"
  linux_install_client
  grep -q '^PostUp' "$BS_WG_DIR/wgmesh.conf"
}

@test "bootstrap: node.conf keeps DM_MESH_OPEN across re-runs and drops junk" {
  export DM_DIST_DIR="$REPO/client"
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_linux.sh"
  export DM_NAME=lap DM_KIND=machine DM_IP=10.73.0.2 DM_HUB_HOST=h DM_HUB_IP=1.2.3.4 DM_HUB_WG_PUB=k \
    DM_WG_IFACE=devmesh DM_WG_PORT=51820 DM_VERSION=1.0.0
  printf 'DM_NAME=lap\nDM_KIND=machine\nDM_ENROLLED=1\nDM_PORT=2202\nDM_COLOR=24\nDM_MESH_OPEN="tcp/8000 udp/53"\n' >"$BATS_TEST_TMPDIR/conf"
  bs_already_enrolled "$BATS_TEST_TMPDIR/conf"
  [ "$DM_MESH_OPEN" = "tcp/8000 udp/53" ]
  bs_node_conf | grep -qxF 'DM_MESH_OPEN="tcp/8000 udp/53"'
  printf 'DM_NAME=lap\nDM_KIND=machine\nDM_ENROLLED=1\nDM_MESH_OPEN="$(touch pwned)"\n' >"$BATS_TEST_TMPDIR/conf"
  bs_already_enrolled "$BATS_TEST_TMPDIR/conf"
  [ -z "$DM_MESH_OPEN" ]
  ! bs_node_conf | grep -q DM_MESH_OPEN
}

# --- devmesh-node mesh / dm mesh -----------------------------------------------------

node() { DEVMESH_ALLOW_NONROOT=1 bash "$REPO/client/sbin/devmesh-node" "$@"; }

@test "mesh: open and close edit node.conf idempotently and reapply the rules" {
  export STUB_WG_UP=1
  run node mesh status
  [ "$status" -eq 0 ]
  [[ $output == *"ssh (tcp/22), mosh (udp/60000-61000), ping"* ]]
  node mesh open tcp/8000
  node mesh open tcp/8000
  node mesh open udp/5353
  grep -qxF 'DM_MESH_OPEN="tcp/8000 udp/5353"' "$NODE_ETC/node.conf"
  [ "$(grep -c '^DM_MESH_OPEN' "$NODE_ETC/node.conf")" -eq 1 ]
  grep -qxF "DEVMESH-IN -p tcp --dport 8000 -j ACCEPT" "$STUB_IPT"
  run node mesh status
  [[ $output == *"tcp/8000"* && $output == *"udp/5353"* ]]
  node mesh close tcp/8000
  node mesh close tcp/8000
  grep -qxF 'DM_MESH_OPEN="udp/5353"' "$NODE_ETC/node.conf"
  ! grep -q -- '--dport 8000 ' "$STUB_IPT"
  node mesh close udp/5353
  ! grep -q '^DM_MESH_OPEN' "$NODE_ETC/node.conf"
  grep -q '^DM_NAME=lap' "$NODE_ETC/node.conf"
}

@test "mesh: validates before touching anything and needs root" {
  for bad in tcp/0 tcp/70000 tcp/9-3 icmp/1 'tcp/22;rm' ''; do
    run node mesh open "$bad"
    [ "$status" -ne 0 ]
  done
  ! grep -q '^DM_MESH_OPEN' "$NODE_ETC/node.conf"
  ! grep -q '^iptables' "$STUB_LOG"
  [ "$EUID" -ne 0 ] || skip "running as root"
  run env -u DEVMESH_ALLOW_NONROOT bash "$REPO/client/sbin/devmesh-node" mesh open tcp/8000
  [ "$status" -ne 0 ]
  [[ $output == *"needs root"* ]]
}

@test "mesh: without a running interface only the config changes" {
  node mesh open tcp/8000
  grep -qxF 'DM_MESH_OPEN="tcp/8000"' "$NODE_ETC/node.conf"
  ! grep -q '^iptables' "$STUB_LOG"
}

@test "dm mesh: shows the open ports and the exact sudo commands" {
  setup_client
  dm_platform() { printf 'linux\n'; }
  DM_MESH_OPEN="tcp/8000"
  run dm_mesh
  [ "$status" -eq 0 ]
  dm_platform() { printf 'macos\n'; }
  run dm_mesh
  [ "$status" -ne 0 ]
  dm_platform() { printf 'linux\n'; }
  run dm_mesh
  [ "$status" -eq 0 ]
  [[ $output == *"tcp/22"* && $output == *"udp/60000-61000"* && $output == *"tcp/8000"* ]]
  [[ $output == *"sudo devmesh-node mesh open <tcp|udp>/<port>"* ]]
  [[ $output == *"sudo devmesh-node mesh close"* ]]
  [[ $output == *"dm port"* ]]
}
