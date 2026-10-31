#!/usr/bin/env bats
# dmadmin allowlist (no shell, no injection) and the files clients consume.

load helpers

setup() {
  setup_hub
  enroll_machine lap
  enroll_phone tablet
}

admin() { SSH_ORIGINAL_COMMAND=$1 devmesh _ssh "${2:-tablet}"; }

@test "admin: allowed read commands work for an enrolled caller" {
  run admin "hosts"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | awk -F'\t' '{print NF}' | sort -u)" = 8 ]
  run admin "version"
  [ "$output" = "$(cat "$REPO/VERSION")" ]
}

@test "admin: unknown callers are rejected" {
  run admin "ls" ghost
  [ "$status" -ne 0 ]
  [[ $output == *"unknown caller"* ]]
}

@test "admin: injection attempts never reach a shell" {
  for cmd in 'ls; id' 'ls && id' 'ls | id' '$(id)' '`id`' 'invite x*' "invite 'x'" 'ls > /tmp/x' 'bash' 'restore /etc/passwd' 'apply' '_enroll AAAA'; do
    run admin "$cmd"
    [ "$status" -ne 0 ] || {
      echo "allowed: $cmd"
      return 1
    }
  done
}

@test "admin: overlong commands are rejected" {
  run admin "ls $(printf 'a%.0s' {1..300})"
  [ "$status" -ne 0 ]
  [[ $output == *"too long"* ]]
}

@test "admin: remove requires the confirmation name" {
  run admin "remove lap"
  [ "$status" -ne 0 ]
  run admin "remove lap --confirm lap"
  [ "$status" -eq 0 ]
}

@test "admin: invite works through the allowlist" {
  run admin "invite pc2 --lan home"
  [ "$status" -eq 0 ]
  [[ $output == *"JOIN: curl -fsSL https://hub.example.test/j/"* ]]
}

@test "ssh-config: path A, path B through hub-jump, shared host key alias" {
  run devmesh ssh-config
  [[ $output == *$'Host lap\n  HostName 10.73.0.2\n  User dev\n  HostKeyAlias lap'* ]]
  [[ $output == *$'Host lap-b\n  HostName localhost\n  Port 2202\n  User dev\n  HostKeyAlias lap\n  ProxyJump hub-jump'* ]]
  [[ $output == *$'Host hub-admin\n  HostName hub.example.test\n  Port 2222\n  User dmadmin'* ]]
  [[ $output == *$'Host hub-jump\n  HostName hub.example.test\n  Port 2222\n  User tunnel'* ]]
  [[ $output == *"StrictHostKeyChecking yes"* ]]
  [[ $output != *"Host tablet"* ]]
  # Included first in ~/.ssh/config: it must never apply to non-devmesh hosts.
  [[ $output == *$'\nHost hub-admin hub-jump lap lap-b\n'* ]]
  ! grep -Eq '^Host .*(\*|\?)' <<<"$output"
}

@test "devmesh sshd: own port, restricted users, keys only, valid for real sshd" {
  source "$REPO/server/install/base.sh"
  run devmesh_sshd_config
  for want in "Port 2222" "AllowUsers tunnel enroll dmadmin" "AuthenticationMethods publickey" \
    "PasswordAuthentication no" "PermitRootLogin no" "PermitTTY no" "AllowTcpForwarding no" \
    "ClientAliveInterval 15" "HostKey ${DEVMESH_HOST_KEY_PUB%.pub}"; do
    grep -qxF "$want" <<<"$output" || {
      echo "missing: $want"
      return 1
    }
  done
  # Forwarding only for the tunnel account.
  [[ $output == *$'Match User tunnel\n    AuthorizedKeysFile '*$'\n    AllowTcpForwarding yes'* ]]
  # The real sshd binary accepts it.
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/sshd_config"
  run /usr/sbin/sshd -t -f "$BATS_TEST_TMPDIR/sshd_config"
  [ "$status" -eq 0 ] || echo "$output"
}

@test "known-hosts pins the hub and every machine by alias" {
  run devmesh known-hosts
  [[ ${lines[0]} == "hub.example.test,10.73.0.1 ssh-ed25519 "* ]]
  [[ ${lines[1]} == "lap ssh-ed25519 "* ]]
  [ "${#lines[@]}" -eq 2 ]
}

@test "hub wg config routes each peer as /32 and uses the firewall hook" {
  run cat "$DEVMESH_WG_DIR/devmesh.conf"
  [[ $output == *"Address = 10.73.0.1/24"* ]]
  [[ $output == *"ListenPort = 51820"* ]]
  [[ $output == *"PostUp = /usr/local/sbin/devmesh-fw up %i"* ]]
  [[ $output == *"AllowedIPs = 10.73.0.2/32"* ]]
  [[ $output == *"AllowedIPs = 10.73.0.3/32"* ]]
  [ "$(stat -c %a "$DEVMESH_WG_DIR/devmesh.conf" 2>/dev/null || stat -f %Lp "$DEVMESH_WG_DIR/devmesh.conf")" = 600 ]
}

@test "apply syncs a live interface without restarting it" {
  STUB_WG_UP=1 devmesh apply
  grep -q '^wg syncconf devmesh' "$STUB_LOG"
}

@test "dist streams a bundle with the client and VERSION" {
  devmesh dist >"$BATS_TEST_TMPDIR/d.tgz"
  run tar -tzf "$BATS_TEST_TMPDIR/d.tgz"
  [[ $output == *"client/bin/dm"* ]]
  [[ $output == *"VERSION"* ]]
}

@test "exports succeed when the last device is not a machine (exit status, not only output)" {
  enroll_phone zphone
  for c in known-hosts ssh-config hosts; do
    run devmesh "$c"
    [ "$status" -eq 0 ] || {
      echo "$c exited $status"
      return 1
    }
  done
  run admin "known-hosts"
  [ "$status" -eq 0 ]
}

@test "ssh-config silences only the post-quantum warning and parses on old and new OpenSSH" {
  run devmesh ssh-config
  [[ $output == *$'IgnoreUnknown WarnWeakCrypto\n  WarnWeakCrypto no-pq-kex'* ]]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/cfg"
  run /usr/bin/ssh -G -F "$BATS_TEST_TMPDIR/cfg" hub-admin
  [ "$status" -eq 0 ]
  # Shared connections, and a dead link noticed within ~10 s.
  [[ $output == *"controlmaster auto"* && $output == *"controlpersist 120"* ]]
  [[ $output == *"serveraliveinterval 5"* && $output == *"serveralivecountmax 2"* ]]
  [[ $output == *"port 2222"* ]]
}

@test "ssh-config reaches macOS machines through the hub on both paths" {
  devmesh invite mm >/dev/null
  t=$BATS_TEST_TMPDIR
  printf 'kind machine\nos macos\nwg %s\nclient %s\ntunnel %s\nhost %s\nuser chris\n' "$(new_wg_pub)" \
    "$(new_ssh_pub "$t/m1")" "$(new_ssh_pub "$t/m2")" "$(new_ssh_pub "$t/m3")" | devmesh _enroll "$(invite_code)" >/dev/null
  port=$(awk -F'\t' '$1 == "mm" {print $4}' "$DEVMESH_ETC/registry.tsv")
  run devmesh ssh-config
  [[ $output == *$'Host mm\n  HostName localhost\n  Port '"$port"$'\n  User chris\n  HostKeyAlias mm\n  ProxyJump hub-jump'* ]]
}

@test "registry rows from v0.2 (14 columns) are migrated with os and sig columns" {
  printf 'old\tphone\t10.73.0.9\t-\t-\t-\t-\t-\t%s\t%s\t-\t-\t2026-01-01T00:00Z\t-\n' "$(new_wg_pub)" "$(new_ssh_pub "$BATS_TEST_TMPDIR/o")" >>"$DEVMESH_ETC/registry.tsv"
  run devmesh hosts
  [[ $output == *"old	phone"* ]]
  [ "$(awk -F'\t' '$1 == "old" {print NF, $15, $16}' "$DEVMESH_ETC/registry.tsv")" = "16 android -" ]
}

@test "admin: notify claude pushes a fixed message for the calling machine" {
  export NTFY_URL=https://hub.example.test NTFY_TOKEN=tk_test
  run admin "notify claude redi perm" lap
  [ "$status" -eq 0 ]
  grep -q '^curl .*Title: Claude on lap: redi' "$STUB_LOG"
  grep -q '^curl .*-d Claude needs your permission' "$STUB_LOG"
  grep -q '^curl-config header = "Authorization: Bearer tk_test"' "$STUB_LOG"
  : >"$STUB_LOG"
  run admin "notify claude redi wait" lap
  [ "$status" -eq 0 ]
  grep -q '^curl .*-d Claude is waiting for your answer' "$STUB_LOG"
}

@test "admin: notify rejects unknown kinds and does nothing without ntfy" {
  export NTFY_URL=https://hub.example.test NTFY_TOKEN=tk_test
  for cmd in 'notify claude redi rm' 'notify claude' 'notify mail redi wait' 'notify claude redi wait extra'; do
    run admin "$cmd" lap
    [ "$status" -ne 0 ] || {
      echo "allowed: $cmd"
      return 1
    }
  done
  ! grep -q '^curl' "$STUB_LOG"
  NTFY_URL='' run admin "notify claude redi wait" lap
  [ "$status" -eq 0 ]
  ! grep -q '^curl' "$STUB_LOG"
}
