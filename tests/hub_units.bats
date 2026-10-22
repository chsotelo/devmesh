#!/usr/bin/env bats
# Validators, codes, time formats and allocation.

load helpers

setup() {
  setup_hub
  load_hub_libs
}

@test "names: lowercase, short, letter first, not hub*" {
  valid_name lap
  valid_name pc-2
  ! valid_name Lap
  ! valid_name 2pc
  ! valid_name hub
  ! valid_name hubx
  ! valid_name 'a;b'
  ! valid_name "$(printf 'a%.0s' {1..17})"
}

@test "wireguard keys: real keys pass, malformed fail" {
  valid_wg_key "$(wg genkey | wg pubkey)"
  ! valid_wg_key "abc="
  ! valid_wg_key "$(printf 'A%.0s' {1..43})"
  ! valid_wg_key "$(wg genkey | wg pubkey) x"
}

@test "ssh keys: only bare ed25519 keys" {
  k=$(new_ssh_pub "$BATS_TEST_TMPDIR/k")
  valid_ssh_pubkey "$k"
  ! valid_ssh_pubkey "$k comment"
  ! valid_ssh_pubkey "restrict $k"
  ! valid_ssh_pubkey "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ"
  [ "$(ssh_key_bare "$k comment here")" = "$k" ]
}

@test "codes: 12 chars from an unambiguous alphabet, unique" {
  a=$(random_code)
  b=$(random_code)
  valid_code "$a"
  [ "$a" != "$b" ]
  [[ $a != *[01ILO]* ]]
  [ "$(format_code ABCDEFGHJKMN)" = "ABCD-EFGH-JKMN" ]
  ! valid_code "abcdefghjkmn"
}

@test "expiry-time uses local time without Z (OpenSSH 8.2 rejects Z)" {
  [ "$(TZ=UTC fmt_expiry 0)" = "197001010000" ]
  [ "$(TZ=America/Lima fmt_expiry 0)" = "196912311900" ]
  [ "$(fmt_iso 86400)" = "1970-01-02T00:00Z" ]
}

@test "ago formatting" {
  DEVMESH_NOW=1000
  [ "$(fmt_ago 0)" = never ]
  [ "$(fmt_ago 990)" = "10s ago" ]
  [ "$(fmt_ago 400)" = "10m ago" ]
}

@test "allocation skips used IPs, reserved invites and reuses freed ones" {
  [ "$(alloc_ip)" = 10.73.0.2 ]
  enroll_machine lap
  devmesh invite pc2 >/dev/null
  [ "$(alloc_ip)" = 10.73.0.4 ]
  [ "$(port_for_ip 10.73.0.11)" = 2211 ]
  devmesh remove lap --confirm lap >/dev/null
  [ "$(alloc_ip)" = 10.73.0.2 ]
}

@test "colors are unique per machine while the palette lasts" {
  enroll_machine a
  enroll_machine b
  enroll_phone p
  run awk -F'\t' '{print $5}' "$DEVMESH_ETC/registry.tsv"
  [ "$output" = $'22\n24\n-' ]
  [ "$(alloc_color)" = 88 ]
}

@test "registry rejects duplicates and malformed lines" {
  enroll_machine lap
  line=$(cat "$DEVMESH_ETC/registry.tsv")
  run reg_add "$line"
  [ "$status" -ne 0 ]
  run reg_add $'x\tmachine'
  [ "$status" -ne 0 ]
}

@test "templates render every placeholder or fail" {
  printf 'a=@@A@@ b=@@B@@\n' >"$BATS_TEST_TMPDIR/t"
  [ "$(render_template "$BATS_TEST_TMPDIR/t" A=1 B='x&y\1')" = 'a=1 b=x&y\1' ]
  run render_template "$BATS_TEST_TMPDIR/t" A=1
  [ "$status" -ne 0 ]
}

@test "hub refuses to run without HUB_HOST" {
  run env -u HUB_HOST bash "$REPO/server/sbin/devmesh" ls
  [ "$status" -ne 0 ]
  [[ $output == *"HUB_HOST is not set"* ]]
}
