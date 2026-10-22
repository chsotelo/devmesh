#!/usr/bin/env bats
# Invite -> enroll -> remove, with real ssh keys and the wg stub.

load helpers

setup() { setup_hub; }

@test "invite prints one universal join line and publishes no device private keys" {
  run devmesh invite lap
  [ "$status" -eq 0 ]
  join=$(sed -n 's/^JOIN: //p' <<<"$output")
  [[ $join =~ ^curl\ -fsSL\ https://hub\.example\.test/j/[A-Z0-9]{12}\ \|\ sh\ -s\ [A-Z0-9]{12}$ ]]
  [[ $output != *sudo* ]]
  code=$(invite_code)
  pass=${join##* }
  script="$DEVMESH_WEBROOT/j/$code"
  [ -f "$script" ]
  # Exactly one private key inside (the throwaway one, encrypted with the secret), and
  # the secret itself is never published.
  [ "$(grep -c 'BEGIN OPENSSH PRIVATE KEY' "$script")" -eq 1 ]
  ! grep -q "$pass" "$script"
  ! grep -q '@@' "$script"
  sh -n "$script"
}

@test "invite writes a throwaway key with expiry-time and a forced command" {
  devmesh invite lap >/dev/null
  code=$(invite_code)
  run cat "$DEVMESH_ETC/ssh/enroll.keys"
  [[ $output =~ restrict,expiry-time=\"[0-9]{12}\",command=\"sudo\ -n\ .*/devmesh\ _enroll\ $code\"\ ssh-ed25519 ]]
}

@test "machine enrollment registers the device and burns the invite" {
  enroll_machine lap
  run awk -F'\t' '{print $1, $2, $3, $4, $6, $8}' "$DEVMESH_ETC/registry.tsv"
  [ "$output" = "lap machine 10.73.0.2 2202 dev aa:bb:cc:dd:ee:01" ]
  [ -z "$(ls "$DEVMESH_ETC/invites")" ]
  [ -z "$(ls "$DEVMESH_WEBROOT/j")" ]
  ! grep -q 'devmesh-enroll' "$DEVMESH_ETC/ssh/enroll.keys"
  grep -q 'AllowedIPs = 10.73.0.2/32' "$DEVMESH_WG_DIR/devmesh.conf"
  grep -q 'permitlisten="localhost:2202",permitopen="localhost:1",command="/usr/local/sbin/devmesh-keys-out lap"' "$DEVMESH_ETC/ssh/tunnel.keys"
  grep -q 'command="sudo -n /usr/local/sbin/devmesh _ssh lap"' "$DEVMESH_ETC/ssh/dmadmin.keys"
  grep -q 'devmesh:lap$' "$DEVMESH_ETC/clients.pub"
}

@test "phone enrollment needs only wg and client keys and gets no tunnel" {
  enroll_phone tablet
  run awk -F'\t' '{print $1, $2, $4, $5, $11}' "$DEVMESH_ETC/registry.tsv"
  [ "$output" = "tablet phone - - -" ]
  ! grep -q permitlisten "$DEVMESH_ETC/ssh/tunnel.keys"
}

@test "client keys may only jump to machine tunnel ports" {
  enroll_machine lap
  enroll_machine pc2
  enroll_phone tablet
  run grep 'devmesh:tablet$' "$DEVMESH_ETC/ssh/tunnel.keys"
  [[ $output == 'restrict,port-forwarding,permitlisten="localhost:1",permitopen="localhost:2202",permitopen="localhost:2203",command="/bin/false" ssh-ed25519 '* ]]
  # Machine tunnel keys cannot open -L forwards into the hub's own services.
  run grep 'devmesh:lap$' "$DEVMESH_ETC/ssh/tunnel.keys"
  [[ $output == 'restrict,port-forwarding,permitlisten="localhost:2202",permitopen="localhost:1",command='* ]]
}

@test "a used code cannot enroll twice" {
  devmesh invite lap >/dev/null
  code=$(invite_code)
  t=$BATS_TEST_TMPDIR
  fields() {
    printf 'kind machine\nwg %s\nclient %s\n' "$(new_wg_pub)" "$(new_ssh_pub "$t/c$1")"
    printf 'tunnel %s\nhost %s\nuser dev\n' "$(new_ssh_pub "$t/t$1")" "$(new_ssh_pub "$t/h$1")"
  }
  fields 1 | devmesh _enroll "$code"
  run bash -c "$(declare -f fields new_wg_pub new_ssh_pub); t=$t; fields 2 | bash '$REPO/server/sbin/devmesh' _enroll '$code'"
  [ "$status" -ne 0 ]
  [[ $output == *"unknown or used code"* ]]
}

@test "an expired code is rejected and cleaned up" {
  devmesh invite lap >/dev/null
  code=$(invite_code)
  export DEVMESH_NOW=$(($(date +%s) + 3600))
  run devmesh _enroll "$code" </dev/null
  [ "$status" -ne 0 ]
  [[ $output == *"code expired"* ]]
  [ ! -e "$DEVMESH_ETC/invites/$code.env" ]
  [ ! -e "$DEVMESH_WEBROOT/j/$code" ]
}

@test "gc drops expired invites and their throwaway keys" {
  devmesh invite lap >/dev/null
  export DEVMESH_NOW=$(($(date +%s) + 3600))
  run devmesh gc
  [ "$status" -eq 0 ]
  [ -z "$(ls "$DEVMESH_ETC/invites")" ]
  ! grep -q devmesh-enroll "$DEVMESH_ETC/ssh/enroll.keys"
}

@test "enrollment input is strictly validated" {
  t=$BATS_TEST_TMPDIR
  good_ssh=$(new_ssh_pub "$t/g")
  cases=(
    "wg notakey"
    "client restrict,command=\"sh\" $good_ssh"
    "client $good_ssh evil-comment"
    "client ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC"
    "user root;id"
    "mac zz:zz:zz:zz:zz:zz"
    "shell /bin/sh"
  )
  for c in "${cases[@]}"; do
    rm -f "$DEVMESH_ETC"/invites/*
    devmesh invite lap >/dev/null
    code=$(invite_code)
    run bash -c "printf 'kind machine\n%s\n' \"\$1\" | bash '$REPO/server/sbin/devmesh' _enroll '$code'" _ "$c"
    [ "$status" -ne 0 ] || {
      echo "accepted: $c"
      return 1
    }
  done
  [ ! -s "$DEVMESH_ETC/registry.tsv" ]
}

@test "machines must send tunnel, host and user; keys must not repeat" {
  devmesh invite lap >/dev/null
  code=$(invite_code)
  t=$BATS_TEST_TMPDIR
  run bash -c "printf 'kind machine\nwg %s\nclient %s\n' '$(new_wg_pub)' '$(new_ssh_pub "$t/a")' | bash '$REPO/server/sbin/devmesh' _enroll '$code'"
  [ "$status" -ne 0 ]
  [[ $output == *"machine needs tunnel, host and user"* ]]
  same=$(new_ssh_pub "$t/b")
  run bash -c "printf 'kind machine\nwg %s\nclient %s\ntunnel %s\nhost %s\nuser dev\n' '$(new_wg_pub)' '$same' '$same' '$same' | bash '$REPO/server/sbin/devmesh' _enroll '$code'"
  [ "$status" -ne 0 ]
  [[ $output == *"tunnel and client keys must differ"* ]]
}

@test "the same wg key cannot be registered twice" {
  wgk=$(new_wg_pub)
  t=$BATS_TEST_TMPDIR
  devmesh invite a --phone >/dev/null
  printf 'kind phone\nwg %s\nclient %s\n' "$wgk" "$(new_ssh_pub "$t/a")" | devmesh _enroll "$(invite_code)" >/dev/null
  devmesh invite b --phone >/dev/null
  run bash -c "printf 'kind phone\nwg %s\nclient %s\n' '$wgk' '$(new_ssh_pub "$t/b")' | bash '$REPO/server/sbin/devmesh' _enroll '$(invite_code)'"
  [ "$status" -ne 0 ]
  [[ $output == *"wg key already registered"* ]]
}

@test "names: invalid, duplicate and pending invites are refused" {
  run devmesh invite Lap
  [ "$status" -ne 0 ]
  # "-b" would shadow another machine's path-B alias in ssh_config.
  run devmesh invite lap-b
  [ "$status" -ne 0 ]
  run devmesh invite hub-x
  [ "$status" -ne 0 ]
  enroll_machine lap
  run devmesh invite lap
  [[ $output == *"already exists"* ]]
  devmesh invite pc2 >/dev/null
  run devmesh invite pc2
  [[ $output == *"already pending"* ]]
}

@test "remove revokes everything and kills live tunnel sessions" {
  enroll_machine lap
  enroll_phone tablet
  run devmesh remove tablet
  [ "$status" -ne 0 ]
  run devmesh remove tablet --confirm tablet
  [ "$status" -eq 0 ]
  ! grep -q '^tablet' "$DEVMESH_ETC/registry.tsv"
  ! grep -q 'devmesh:tablet' "$DEVMESH_ETC/clients.pub" "$DEVMESH_ETC/ssh/tunnel.keys" "$DEVMESH_ETC/ssh/dmadmin.keys"
  grep -q 'pkill -KILL -u tunnel' "$STUB_LOG"
  grep -q '^lap' "$DEVMESH_ETC/registry.tsv"
}

@test "remove of a pending device cancels its invite" {
  devmesh invite pc3 >/dev/null
  run devmesh remove pc3 --confirm pc3
  [ "$status" -eq 0 ]
  [[ $output == *"cancelled pending invite"* ]]
  [ -z "$(ls "$DEVMESH_ETC/invites")" ]
}

@test "the device decides its kind: machines get port and color, others do not" {
  devmesh invite any1 >/dev/null
  printf 'kind phone\nwg %s\nclient %s\n' "$(new_wg_pub)" "$(new_ssh_pub "$BATS_TEST_TMPDIR/p")" |
    devmesh _enroll "$(invite_code)" >/dev/null
  [ "$(awk -F'\t' '$1 == "any1" {print $2, $4, $5}' "$DEVMESH_ETC/registry.tsv")" = "phone - -" ]
  enroll_machine any2
  [[ $(awk -F'\t' '$1 == "any2" {print $2, $4, $5}' "$DEVMESH_ETC/registry.tsv") =~ ^machine\ 22[0-9]{2}\ [0-9]+$ ]]
}

@test "a code restricted to one kind refuses other kinds" {
  devmesh invite tab --phone >/dev/null
  t=$BATS_TEST_TMPDIR
  run bash -c "printf 'kind machine\nwg %s\nclient %s\ntunnel %s\nhost %s\nuser dev\n' '$(new_wg_pub)' '$(new_ssh_pub "$t/k1")' '$(new_ssh_pub "$t/k2")' '$(new_ssh_pub "$t/k3")' | bash '$REPO/server/sbin/devmesh' _enroll '$(invite_code)'"
  [ "$status" -ne 0 ]
  [[ $output == *"this code is for a phone, not a machine"* ]]
}

@test "enrollment without a kind is refused" {
  devmesh invite x1 >/dev/null
  run bash -c "printf 'wg %s\nclient %s\n' '$(new_wg_pub)' '$(new_ssh_pub "$BATS_TEST_TMPDIR/q")' | bash '$REPO/server/sbin/devmesh' _enroll '$(invite_code)'"
  [ "$status" -ne 0 ]
  [[ $output == *"missing device kind"* ]]
}

@test "a silent enrollment client cannot hold the hub lock" {
  devmesh invite lap >/dev/null
  start=$(date +%s)
  # Process substitution: the hub process must return on its own, without waiting for EOF.
  run bash -c "ENROLL_TIMEOUT=1 bash '$REPO/server/sbin/devmesh' _enroll '$(invite_code)' < <(sleep 6 2>/dev/null)"
  [ "$status" -ne 0 ]
  (($(date +%s) - start < 6))
  run devmesh ls
  [ "$status" -eq 0 ]
}

@test "oversized enrollment input is rejected" {
  devmesh invite lap >/dev/null
  run bash -c "head -c 20000 /dev/zero | tr '\\0' a | bash '$REPO/server/sbin/devmesh' _enroll '$(invite_code)'"
  [ "$status" -ne 0 ]
  [[ $output == *"too large"* ]]
}

@test "--watch-hub gives the machine an ntfy.sh topic" {
  run devmesh invite lap --watch-hub
  [[ $output =~ https://ntfy\.sh/devmesh-[a-z0-9]{24} ]]
  run devmesh invite tablet --phone --watch-hub
  [ "$status" -ne 0 ]
}
