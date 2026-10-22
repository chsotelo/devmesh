#!/usr/bin/env bats
# IP mode: HUB_HOST is an address, the hub uses a self-signed certificate and invites carry its pin.

load helpers

setup() {
  setup_hub
  export HUB_HOST=203.0.113.10
}

pin_of() { bash -c 'source "$1"; tls_pin "$2"' _ "$REPO/server/lib/common.sh" "$1"; }

@test "valid_ip accepts IPv4 and IPv6 literals and rejects domains and junk" {
  source "$REPO/server/lib/common.sh"
  for ok in 203.0.113.10 10.0.0.1 255.255.255.255 ::1 2001:db8::7 fe80::1 1:2:3:4:5:6:7:8 ::; do
    valid_ip "$ok" || {
      echo "rejected: $ok"
      return 1
    }
  done
  for bad in hub.example.com 256.1.1.1 1.2.3 1.2.3.4.5 12345::1 1:2:3:4:5:6:7:8:9 1::2::3 :1:2 gggg::1 '' 1.2.3.4/24 :::; do
    ! valid_ip "$bad" || {
      echo "accepted: $bad"
      return 1
    }
  done
}

@test "the certificate is ECDSA P-256 with the IP as SAN, generated once and reused" {
  source "$REPO/server/lib/common.sh"
  tls_ensure_selfsigned 203.0.113.10
  d=$DEVMESH_ETC/tls
  [ "$(stat -c %a "$d/key.pem" 2>/dev/null || stat -f %Lp "$d/key.pem")" = 600 ]
  run openssl x509 -in "$d/cert.pem" -noout -text
  [[ $output == *"prime256v1"* || $output == *"P-256"* ]]
  [[ $output == *"IP Address:203.0.113.10"* ]]
  first=$(pin_of "$d/cert.pem")
  tls_ensure_selfsigned 203.0.113.10
  [ "$(pin_of "$d/cert.pem")" = "$first" ]
  # Another address (restore on a new VPS) gets a new certificate.
  tls_ensure_selfsigned 198.51.100.7
  [ "$(pin_of "$d/cert.pem")" != "$first" ]
}

@test "the pin is base64(sha256(SPKI DER))" {
  source "$REPO/server/lib/common.sh"
  tls_ensure_selfsigned 203.0.113.10
  expected=$(openssl x509 -in "$DEVMESH_ETC/tls/cert.pem" -pubkey -noout | openssl pkey -pubin -outform der |
    openssl dgst -sha256 -binary | base64 | tr -d '\n')
  [ "$(pin_of "$DEVMESH_ETC/tls/cert.pem")" = "$expected" ]
  [[ $expected =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

@test "IP mode invite prints a pinned, -k join line and exports the pin to the device" {
  source "$REPO/server/lib/common.sh"
  tls_ensure_selfsigned 203.0.113.10
  pin=$(pin_of "$DEVMESH_ETC/tls/cert.pem")
  run devmesh invite lap
  [ "$status" -eq 0 ]
  join=$(sed -n 's/^JOIN: //p' <<<"$output")
  [[ $join == "curl -fsSL --pinnedpubkey 'sha256//$pin' -k https://203.0.113.10:8443/j/"* ]]
  [[ $join =~ \ \|\ sh\ -s\ [A-Z0-9]{12}$ ]]
  script="$DEVMESH_WEBROOT/j/$(invite_code)"
  grep -qF "export DM_HUB_PIN='$pin'" "$script"
  sh -n "$script"
}

@test "IP mode: an IPv6 hub is bracketed in the join URL" {
  export HUB_HOST=2001:db8::7
  source "$REPO/server/lib/common.sh"
  tls_ensure_selfsigned 2001:db8::7
  run devmesh invite lap
  [ "$status" -eq 0 ]
  [[ $output == *"-k https://[2001:db8::7]:8443/j/"* ]]
}

@test "IP mode: HUB_PIN from hub.conf wins over the certificate" {
  printf 'HUB_HOST=203.0.113.10\nHUB_PIN=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' >"$DEVMESH_ETC/hub.conf"
  run devmesh invite lap
  [ "$status" -eq 0 ]
  [[ $output == *"sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="* ]]
}

@test "IP mode without a certificate refuses to print an unpinned line" {
  run devmesh invite lap
  [ "$status" -ne 0 ]
  [[ $output == *"pin"* ]]
}

@test "domain mode join line is unchanged and carries no pin" {
  export HUB_HOST=hub.example.test
  run devmesh invite lap
  [ "$status" -eq 0 ]
  join=$(sed -n 's/^JOIN: //p' <<<"$output")
  [[ $join =~ ^curl\ -fsSL\ https://hub\.example\.test/j/[A-Z0-9]{12}\ \|\ sh\ -s\ [A-Z0-9]{12}$ ]]
  [[ $join != *pinned* && $join != *" -k "* ]]
  grep -qF "export DM_HUB_PIN=''" "$DEVMESH_WEBROOT/j/$(invite_code)"
}

@test "backup includes the tls directory and restore brings it back" {
  source "$REPO/server/lib/common.sh"
  tls_ensure_selfsigned 203.0.113.10
  pin=$(pin_of "$DEVMESH_ETC/tls/cert.pem")
  age-keygen -o "$BATS_TEST_TMPDIR/id" 2>/dev/null
  age-keygen -y "$BATS_TEST_TMPDIR/id" >"$DEVMESH_ETC/backup.recipients"
  out=$(devmesh backup)
  age -d -i "$BATS_TEST_TMPDIR/id" -o "$BATS_TEST_TMPDIR/s.tgz" "$out"
  run tar -tzf "$BATS_TEST_TMPDIR/s.tgz"
  [[ $output == *"etc/devmesh/tls/cert.pem"* && $output == *"etc/devmesh/tls/key.pem"* ]]
  rm -rf "$DEVMESH_ETC/tls"
  printf 'HUB_HOST=203.0.113.10\n' >"$DEVMESH_ETC/hub.conf"
  mkdir -p "$BATS_TEST_TMPDIR/root"
  # Extract into the sandbox root, as restore does for the hub.
  tar -C "$BATS_TEST_TMPDIR/root" -xzpf "$BATS_TEST_TMPDIR/s.tgz"
  [ "$(pin_of "$BATS_TEST_TMPDIR/root${DEVMESH_ETC}/tls/cert.pem")" = "$pin" ]
}

@test "node.conf records the pin in IP mode only" {
  source "$REPO/client/lib/bootstrap_common.sh"
  export DM_NAME=lap DM_KIND=machine DM_IP=10.73.0.2 DM_HUB_HOST=203.0.113.10 DM_HUB_IP=10.73.0.1 \
    DM_HUB_WG_PUB=k DM_WG_IFACE=devmesh DM_WG_PORT=51820 DM_VERSION=0.1.0
  DM_HUB_PIN=abc= run bs_node_conf
  [[ $output == *$'\nDM_HUB_PIN=abc='* ]]
  DM_HUB_PIN= run bs_node_conf
  [[ $output != *DM_HUB_PIN* ]]
}

@test "bs_hub_curl pins the connection only when DM_HUB_PIN is set" {
  source "$REPO/client/lib/bootstrap_common.sh"
  DM_HUB_PIN=abc= bs_hub_curl https://203.0.113.10/x
  grep -q "^curl -fsSL --pinnedpubkey sha256//abc= -k https://203.0.113.10/x" "$STUB_LOG"
  DM_HUB_PIN= bs_hub_curl https://hub.example.test/x
  grep -q "^curl -fsSL https://hub.example.test/x" "$STUB_LOG"
}
