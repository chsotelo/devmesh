#!/usr/bin/env bats
# ls / check (alerts) / backup + restore / firewall hook.

bats_require_minimum_version 1.5.0
load helpers

setup() {
  setup_hub
  enroll_machine lap
  export NTFY_URL=https://hub.example.test NTFY_TOKEN=tk_test
}

lap_wg() { awk -F'\t' '$1 == "lap" {print $9}' "$DEVMESH_ETC/registry.tsv"; }

@test "ls shows handshake age and tunnel state" {
  printf '%s %s\n' "$(lap_wg)" "$(($(date +%s) - 30))" >"$BATS_TEST_TMPDIR/hs"
  STUB_WG_HANDSHAKES="$BATS_TEST_TMPDIR/hs" STUB_SS_PORTS=2202 run devmesh ls
  [[ ${lines[1]} =~ ^lap\ +machine\ +10\.73\.0\.2\ +:2202\ +3[0-9]s\ ago\ +up ]]
}

@test "machines report their client version through key sync" {
  printf 'ssh-ed25519 AAAA devmesh:lap\n' >"$BATS_TEST_TMPDIR/clients.pub"
  home="$DEVMESH_STATE/home/tunnel"
  mkdir -p "$home"
  run env HOME="$home" DEVMESH_CLIENTS_PUB="$BATS_TEST_TMPDIR/clients.pub" SSH_ORIGINAL_COMMAND="keys 0.1.0" \
    sh "$REPO/server/sbin/devmesh-keys-out" lap
  [ "$output" = "ssh-ed25519 AAAA devmesh:lap" ]
  # Garbage versions are ignored, the key list is still served.
  run env HOME="$home" DEVMESH_CLIENTS_PUB="$BATS_TEST_TMPDIR/clients.pub" SSH_ORIGINAL_COMMAND="keys ../x" \
    sh "$REPO/server/sbin/devmesh-keys-out" lap
  [ "$status" -eq 0 ]
  run devmesh ls
  [[ ${lines[1]} == *" 0.1.0 "* ]]
}

@test "ls lists pending invites" {
  devmesh invite pc2 >/dev/null
  run devmesh ls
  [[ $output == *"pc2"*"pending, expires"* ]]
}

@test "check: alerts once after the grace period, then on recovery" {
  now=$(date +%s)
  # Down: no handshake, no tunnel. First observation records, no alert.
  DEVMESH_NOW=$now devmesh check
  ! grep -q '^curl' "$STUB_LOG"
  # After the grace period: one alert.
  DEVMESH_NOW=$((now + 61)) devmesh check
  [ "$(grep -c '^curl.*Title: lap is down' "$STUB_LOG")" -eq 1 ]
  grep -q '^curl-config header = "Authorization: Bearer tk_test"' "$STUB_LOG"
  ! grep '^curl ' "$STUB_LOG" | grep -q tk_test
  # Still down: no repeat.
  DEVMESH_NOW=$((now + 300)) devmesh check
  [ "$(grep -c 'lap is down' "$STUB_LOG")" -eq 1 ]
  # Tunnel back: recovery alert once it stays up.
  STUB_SS_PORTS=2202 DEVMESH_NOW=$((now + 400)) devmesh check
  [ "$(grep -c 'Title: lap is back' "$STUB_LOG")" -eq 0 ]
  STUB_SS_PORTS=2202 DEVMESH_NOW=$((now + 700)) devmesh check
  grep -q 'Title: lap is back' "$STUB_LOG"
}

@test "check: a sleeping machine that wakes for seconds (Power Nap) alerts down once, back only when awake" {
  now=$(date +%s)
  DEVMESH_NOW=$now devmesh check
  DEVMESH_NOW=$((now + 61)) devmesh check
  # Short wakes between sleeps: no "back", no second "down".
  for t in 900 1800 2700; do
    STUB_SS_PORTS=2202 DEVMESH_NOW=$((now + t)) devmesh check
    DEVMESH_NOW=$((now + t + 60)) devmesh check
    DEVMESH_NOW=$((now + t + 200)) devmesh check
  done
  [ "$(grep -c 'Title: lap is down' "$STUB_LOG")" -eq 1 ]
  [ "$(grep -c 'Title: lap is back' "$STUB_LOG")" -eq 0 ]
  # Really awake: one "back".
  for t in 3600 3700 3800 3900; do STUB_SS_PORTS=2202 DEVMESH_NOW=$((now + t)) devmesh check; done
  [ "$(grep -c 'Title: lap is back' "$STUB_LOG")" -eq 1 ]
  [ "$(cat "$DEVMESH_STATE/machines/lap")" = up ]
}

@test "check: a fresh handshake counts as up even without the tunnel" {
  printf '%s %s\n' "$(lap_wg)" "$(date +%s)" >"$BATS_TEST_TMPDIR/hs"
  STUB_WG_HANDSHAKES="$BATS_TEST_TMPDIR/hs" devmesh check
  [ "$(cat "$DEVMESH_STATE/machines/lap")" = up ]
}

@test "backup is age-encrypted and decrypts to hub state only" {
  age-keygen -o "$BATS_TEST_TMPDIR/id" 2>/dev/null
  age-keygen -y "$BATS_TEST_TMPDIR/id" >"$DEVMESH_ETC/backup.recipients"
  run devmesh backup
  [ "$status" -eq 0 ]
  out=$output
  ! grep -q 'registry' "$out"
  age -d -i "$BATS_TEST_TMPDIR/id" -o "$BATS_TEST_TMPDIR/s.tgz" "$out"
  run tar -tzf "$BATS_TEST_TMPDIR/s.tgz"
  [[ $output == *"etc/devmesh/registry.tsv"* ]]
  [[ $output == *"ssh_host_ed25519_key"* ]]
  run devmesh backup-latest
  [ "$status" -eq 0 ]
}

@test "backup prunes to BACKUP_KEEP" {
  age-keygen -o "$BATS_TEST_TMPDIR/id" 2>/dev/null
  age-keygen -y "$BATS_TEST_TMPDIR/id" >"$DEVMESH_ETC/backup.recipients"
  mkdir -p "$DEVMESH_BACKUP_DIR"
  for i in 01 02 03 04; do : >"$DEVMESH_BACKUP_DIR/devmesh-2026010${i:1}T000000Z.tar.gz.age"; done
  BACKUP_KEEP=2 devmesh backup >/dev/null
  [ "$(ls "$DEVMESH_BACKUP_DIR" | grep -c '^devmesh-')" -eq 2 ]
}

@test "restore round-trips state and rejects foreign paths" {
  age-keygen -o "$BATS_TEST_TMPDIR/id" 2>/dev/null
  age-keygen -y "$BATS_TEST_TMPDIR/id" >"$DEVMESH_ETC/backup.recipients"
  out=$(devmesh backup)
  age -d -i "$BATS_TEST_TMPDIR/id" -o "$BATS_TEST_TMPDIR/s.tgz" "$out"
  devmesh remove lap --confirm lap >/dev/null
  run devmesh restore "$BATS_TEST_TMPDIR/s.tgz"
  [ "$status" -eq 0 ]
  grep -q '^lap' "$DEVMESH_ETC/registry.tsv"
  grep -q 'AllowedIPs = 10.73.0.2/32' "$DEVMESH_WG_DIR/devmesh.conf"

  mkdir -p "$BATS_TEST_TMPDIR/evil/etc"
  echo x >"$BATS_TEST_TMPDIR/evil/etc/passwd"
  tar -C "$BATS_TEST_TMPDIR/evil" -czf "$BATS_TEST_TMPDIR/evil.tgz" etc/passwd
  run devmesh restore "$BATS_TEST_TMPDIR/evil.tgz"
  [ "$status" -ne 0 ]
  [[ $output == *"unexpected path"* ]]
}

@test "backup with the host key inside DEVMESH_ETC restores cleanly (no hardlinks)" {
  mv "${DEVMESH_HOST_KEY_PUB%.pub}" "$DEVMESH_ETC/ssh_host_ed25519_key"
  mv "$DEVMESH_HOST_KEY_PUB" "$DEVMESH_ETC/ssh_host_ed25519_key.pub"
  export DEVMESH_HOST_KEY_PUB="$DEVMESH_ETC/ssh_host_ed25519_key.pub"
  age-keygen -o "$BATS_TEST_TMPDIR/id" 2>/dev/null
  age-keygen -y "$BATS_TEST_TMPDIR/id" >"$DEVMESH_ETC/backup.recipients"
  out=$(devmesh backup)
  age -d -i "$BATS_TEST_TMPDIR/id" -o "$BATS_TEST_TMPDIR/s.tgz" "$out"
  [ "$(tar -tvzf "$BATS_TEST_TMPDIR/s.tgz" | grep -c '^h')" -eq 0 ]
  run devmesh restore "$BATS_TEST_TMPDIR/s.tgz"
  [ "$status" -eq 0 ]
}

@test "restore refuses symlinks and setuid entries inside allowed paths" {
  rel=${DEVMESH_ETC#/}
  mkdir -p "$BATS_TEST_TMPDIR/evil/$rel"
  ln -s /etc "$BATS_TEST_TMPDIR/evil/$rel/x"
  tar -C "$BATS_TEST_TMPDIR/evil" -czf "$BATS_TEST_TMPDIR/sym.tgz" "$rel/x"
  run devmesh restore "$BATS_TEST_TMPDIR/sym.tgz"
  [ "$status" -ne 0 ]
  [[ $output == *"unsupported entry type"* ]]
}

@test "devmesh-fw: DOCKER-USER on Docker hosts, FORWARD otherwise, idempotent" {
  STUB_DOCKER=1 bash "$REPO/server/sbin/devmesh-fw" up devmesh
  STUB_DOCKER=1 bash "$REPO/server/sbin/devmesh-fw" up devmesh
  [ "$(grep -c '^DOCKER-USER ' "$STUB_IPT")" -eq 2 ]
  [ "$(grep '^DOCKER-USER ' "$STUB_IPT" | sed -n 1p)" = "DOCKER-USER -i devmesh ! -o devmesh -j DROP" ]
  [ "$(grep '^DOCKER-USER ' "$STUB_IPT" | sed -n 2p)" = "DOCKER-USER -i devmesh -o devmesh -j ACCEPT" ]
  STUB_DOCKER=1 bash "$REPO/server/sbin/devmesh-fw" down devmesh
  [ ! -s "$STUB_IPT" ]
  bash "$REPO/server/sbin/devmesh-fw" up devmesh
  grep -qxF "FORWARD -i devmesh -o devmesh -j ACCEPT" "$STUB_IPT"
  ! grep -q '^DOCKER-USER' "$STUB_IPT"
  run bash "$REPO/server/sbin/devmesh-fw" up 'x;rm'
  [ "$status" -eq 2 ]
}

@test "devmesh-fw: INPUT from the mesh allows only established, ping and the devmesh ssh port" {
  printf 'HUB_SSH_PORT=2299\n' >"$DEVMESH_ETC/hub.conf"
  bash "$REPO/server/sbin/devmesh-fw" up devmesh
  bash "$REPO/server/sbin/devmesh-fw" up devmesh
  [ "$(grep -c '^INPUT ' "$STUB_IPT")" -eq 1 ]
  grep -qxF "INPUT -i devmesh -j DEVMESH-HUB-IN" "$STUB_IPT"
  [ "$(grep -c '^:DEVMESH-HUB-IN$' "$STUB_IPT")" -eq 1 ]
  expected="DEVMESH-HUB-IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
DEVMESH-HUB-IN -p icmp --icmp-type echo-request -j ACCEPT
DEVMESH-HUB-IN -p tcp --dport 2299 -j ACCEPT
DEVMESH-HUB-IN -j DROP"
  [ "$(grep '^DEVMESH-HUB-IN ' "$STUB_IPT")" = "$expected" ]
}

@test "devmesh-fw: HUB_SSH_PORT defaults to 2222 and junk in hub.conf is ignored" {
  printf 'HUB_SSH_PORT=70000\n' >"$DEVMESH_ETC/hub.conf"
  bash "$REPO/server/sbin/devmesh-fw" up devmesh
  grep -qxF "DEVMESH-HUB-IN -p tcp --dport 2222 -j ACCEPT" "$STUB_IPT"
}

@test "devmesh-fw down removes every devmesh rule and leaves other rules alone" {
  printf 'INPUT -p tcp --dport 80 -j ACCEPT\nDOCKER-USER -j RETURN\n' >"$STUB_IPT"
  STUB_DOCKER=1 bash "$REPO/server/sbin/devmesh-fw" up devmesh
  STUB_DOCKER=1 bash "$REPO/server/sbin/devmesh-fw" down devmesh
  [ "$(cat "$STUB_IPT")" = "INPUT -p tcp --dport 80 -j ACCEPT
DOCKER-USER -j RETURN" ]
}

@test "devmesh-fw: no iptables call touches a rule that is not devmesh's" {
  STUB_DOCKER=1 bash "$REPO/server/sbin/devmesh-fw" up devmesh
  STUB_DOCKER=1 bash "$REPO/server/sbin/devmesh-fw" down devmesh
  ! grep '^iptables ' "$STUB_LOG" | grep -E ' -(D|F|X|N|A|I) ' | grep -viE 'devmesh'
}

hub_in_rules() { grep '^DEVMESH-HUB-IN ' "$STUB_IPT"; }

@test "devmesh-fw: no HUB_OPEN_PORTS keeps exactly the base rule set" {
  printf 'HUB_OPEN_PORTS=\n' >"$DEVMESH_ETC/hub.conf"
  bash "$REPO/server/sbin/devmesh-fw" up devmesh
  [ "$(hub_in_rules)" = "DEVMESH-HUB-IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
DEVMESH-HUB-IN -p icmp --icmp-type echo-request -j ACCEPT
DEVMESH-HUB-IN -p tcp --dport 2222 -j ACCEPT
DEVMESH-HUB-IN -j DROP" ]
}

@test "devmesh-fw: HUB_OPEN_PORTS adds ACCEPT rules after sshd and before DROP" {
  printf 'HUB_OPEN_PORTS="8730 9000/udp"\n' >"$DEVMESH_ETC/hub.conf"
  bash "$REPO/server/sbin/devmesh-fw" up devmesh
  [ "$(hub_in_rules)" = "DEVMESH-HUB-IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
DEVMESH-HUB-IN -p icmp --icmp-type echo-request -j ACCEPT
DEVMESH-HUB-IN -p tcp --dport 2222 -j ACCEPT
DEVMESH-HUB-IN -p tcp --dport 8730 -j ACCEPT
DEVMESH-HUB-IN -p udp --dport 9000 -j ACCEPT
DEVMESH-HUB-IN -j DROP" ]
}

@test "devmesh-fw: HUB_OPEN_PORTS accepts commas and the last occurrence wins" {
  printf 'HUB_OPEN_PORTS=1111\nHUB_OPEN_PORTS='"'"'8730,9001/tcp'"'"'\n' >"$DEVMESH_ETC/hub.conf"
  bash "$REPO/server/sbin/devmesh-fw" up devmesh
  grep -qxF "DEVMESH-HUB-IN -p tcp --dport 8730 -j ACCEPT" "$STUB_IPT"
  grep -qxF "DEVMESH-HUB-IN -p tcp --dport 9001 -j ACCEPT" "$STUB_IPT"
  ! grep -q -- '--dport 1111 ' "$STUB_IPT"
}

@test "devmesh-fw: invalid HUB_OPEN_PORTS entries are skipped with a warning and exit 0" {
  printf 'HUB_OPEN_PORTS="0 70000 abc 8730/sctp 8730"\n' >"$DEVMESH_ETC/hub.conf"
  run --separate-stderr bash "$REPO/server/sbin/devmesh-fw" up devmesh
  [ "$status" -eq 0 ]
  for bad in 0 70000 abc 8730/sctp; do [[ $stderr == *"$bad"* ]]; done
  [ "$(hub_in_rules | grep -c -- '--dport')" -eq 2 ]
  grep -qxF "DEVMESH-HUB-IN -p tcp --dport 8730 -j ACCEPT" "$STUB_IPT"
  [ "$(hub_in_rules | tail -n 1)" = "DEVMESH-HUB-IN -j DROP" ]
}

@test "devmesh-fw: re-running up does not duplicate the open-port rules" {
  printf 'HUB_OPEN_PORTS="8730 9000/udp"\n' >"$DEVMESH_ETC/hub.conf"
  bash "$REPO/server/sbin/devmesh-fw" up devmesh
  bash "$REPO/server/sbin/devmesh-fw" up devmesh
  [ "$(hub_in_rules | wc -l)" -eq 6 ]
  [ "$(grep -c '^INPUT ' "$STUB_IPT")" -eq 1 ]
  # Removing the key and re-applying drops the rule again.
  : >"$DEVMESH_ETC/hub.conf"
  bash "$REPO/server/sbin/devmesh-fw" up devmesh
  [ "$(hub_in_rules | wc -l)" -eq 4 ]
}
