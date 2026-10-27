#!/usr/bin/env bats
# Suspend / power off / wake: the machine side (_power_do) over stubbed busctl, iw and pmset,
# and the controller side (_power ... check|suspend|off|wake) over stub ssh. The safety rule:
# a machine is only suspended or powered off when another online machine on its LAN could wake it.

bats_require_minimum_version 1.5.0
load helpers

CIDR="192.168.1.0/24"

setup() {
  export DM_LANG=es
  setup_client
  export DM_POWER_DELAY=0
  dm_platform() { printf 'linux\n'; }
  printf 'lap\tmachine\t10.73.0.2\t2202\t22\tdev\thome\taa:bb:cc:dd:ee:01\n' >"$DM_CACHE/hosts.tsv"
  printf 'pc2\tmachine\t10.73.0.3\t2203\t24\tdev\thome\taa:bb:cc:dd:ee:02\n' >>"$DM_CACHE/hosts.tsv"
  printf 'far\tmachine\t10.73.0.5\t2205\t25\tdev\toffice\taa:bb:cc:dd:ee:05\n' >>"$DM_CACHE/hosts.tsv"
  printf 'tablet\tphone\t10.73.0.4\t-\t-\t-\t-\t-\n' >>"$DM_CACHE/hosts.tsv"
  # Path L stays off: the controller is not on any LAN unless a test says so.
  touch "$DM_CACHE/lan-off-lap" "$DM_CACHE/lan-off-pc2" "$DM_CACHE/lan-off-far"
  ssh_reply lap "dm _power_do caps" "suspend=yes off=yes wol=ok"
  ssh_reply lap "cat /run/devmesh/lan" "192.168.1.5 $CIDR wlan0"
  ssh_reply pc2 "cat /run/devmesh/lan" "192.168.1.9 $CIDR wlan0"
  ssh_reply lap "dm _power_do suspend" "ok"
  ssh_reply lap "dm _power_do off" "ok"
}

# wait_log PATTERN — the detached command runs a moment after the caller returned.
wait_log() {
  local i
  for i in $(seq 50); do
    grep -q -- "$1" "$STUB_LOG" && return 0
    sleep 0.1
  done
  return 1
}

# --- machine side ----------------------------------------------------------------------------

@test "_power_do caps: logind answers and the WiFi wake state" {
  export STUB_CAN_SUSPEND=yes STUB_CAN_POWEROFF=challenge
  run dm_power_do caps
  [[ $output == "suspend=yes off=challenge wol="* ]]
}

@test "_power_do suspend: asks logind without a password prompt, detached" {
  run dm_power_do suspend
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  wait_log 'busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager Suspend b false'
}

@test "_power_do off: PowerOff, only when logind says yes" {
  run dm_power_do off
  [ "$status" -eq 0 ]
  wait_log 'Manager PowerOff b false'
}

@test "_power_do: a polkit challenge means refused, nothing is called" {
  export STUB_CAN_SUSPEND=challenge STUB_CAN_POWEROFF=challenge
  run dm_power_do suspend
  [ "$status" -ne 0 ]
  run dm_power_do off
  [ "$status" -ne 0 ]
  sleep 0.3
  ! grep -q 'Suspend b false\|PowerOff b false' "$STUB_LOG"
}

@test "_power_do suspend: a WiFi-only machine without Wake-on-WLAN refuses (unless it is the panel's own)" {
  mkdir -p "$BATS_TEST_TMPDIR/net/wlan0/wireless"
  export DM_SYS_NET="$BATS_TEST_TMPDIR/net" STUB_IW_PHY=1 STUB_IW_ON=0
  run dm_power_do suspend
  [ "$status" -ne 0 ]
  [ "$(dm_power_wol)" = off ]
  sleep 0.3
  ! grep -q 'Suspend b false' "$STUB_LOG"
  run dm_power_do suspend --self
  [ "$status" -eq 0 ]
  wait_log 'Suspend b false'
}

@test "_power_do: Wake-on-WLAN on, or no WiFi at all, is wakeable" {
  mkdir -p "$BATS_TEST_TMPDIR/net/wlan0/wireless"
  export DM_SYS_NET="$BATS_TEST_TMPDIR/net" STUB_IW_PHY=1 STUB_IW_ON=1
  [ "$(dm_power_wol)" = ok ]
  export DM_SYS_NET="$BATS_TEST_TMPDIR/none"
  mkdir -p "$DM_SYS_NET/eth0"
  [ "$(dm_power_wol)" = na ]
}

@test "_power_do on macOS: suspend is pmset sleepnow, power off does not exist" {
  dm_platform() { printf 'macos\n'; }
  run dm_power_do suspend
  [ "$status" -eq 0 ]
  wait_log 'pmset sleepnow'
  run dm_power_do off
  [ "$status" -ne 0 ]
  [ "$(grep -c pmset "$STUB_LOG")" -eq 1 ]
}

@test "_power_do: only suspend, off and caps exist" {
  run dm_power_do reboot
  [ "$status" -ne 0 ]
}

# --- controller side ---------------------------------------------------------------------------

@test "_power check: a machine another online machine shares a LAN with can be suspended and powered off" {
  run dm_power lap check
  [ "$output" = "suspend=1 off=1 wake=0 why=ok" ]
}

@test "_power check: the panel's own machine suspends itself, never powers off" {
  DM_NAME=lap run dm_power lap check
  [ "$output" = "suspend=1 off=0 wake=0 why=self" ]
}

@test "_power suspend: the panel's own machine goes through logind with no ssh" {
  DM_NAME=lap run dm_power lap suspend
  [ "$status" -eq 0 ]
  wait_log 'Manager Suspend b false'
  ! grep -q '^ssh' "$STUB_LOG"
}

@test "_power off: refused for the panel's own machine" {
  DM_NAME=lap run dm_power lap off
  [ "$status" -ne 0 ]
  [[ $output == *"Es la máquina donde estás"* ]]
}

@test "_power: on another network it is refused with the clear message" {
  ssh_reply lap "cat /run/devmesh/lan" ""
  run dm_power lap check
  [ "$output" = "suspend=0 off=0 wake=0 why=other-lan" ]
  run dm_power lap suspend
  [ "$status" -ne 0 ]
  [[ $output == *"Desde aquí no se podría despertar: está en otra red"* ]]
  ! grep -q 'dm _power_do suspend' "$STUB_LOG"
}

@test "_power: no other machine on its LAN is online, so no suspend and no power off" {
  ssh_reply pc2 "cat /run/devmesh/lan" "10.0.0.9 10.0.0.0/24 wlan0"
  ssh_reply far "cat /run/devmesh/lan" ""
  run dm_power lap check
  [ "$output" = "suspend=0 off=0 wake=0 why=no-relay" ]
  run dm_power lap off
  [ "$status" -ne 0 ]
  ! grep -q 'dm _power_do off' "$STUB_LOG"
}

@test "_power: a relay that is down does not count" {
  STUB_SSH_DOWN="pc2 pc2-b" run dm_power lap check
  [ "$output" = "suspend=0 off=0 wake=0 why=no-relay" ]
}

@test "_power: the controller on the machine's own LAN is a relay" {
  ssh_reply pc2 "cat /run/devmesh/lan" ""
  rm -f "$DM_CACHE/lan-off-lap"
  printf '192.168.1.5\n' >"$DM_CACHE/lan-lap"
  ssh_reply lap-l "dm _power_do caps" "suspend=yes off=yes wol=ok"
  ssh_reply lap-l "cat /run/devmesh/lan" "192.168.1.5 $CIDR wlan0"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "192.168.1.5 dev wlan0 src 192.168.1.32"\n' >"$BATS_TEST_TMPDIR/bin/ip"
  chmod +x "$BATS_TEST_TMPDIR/bin/ip"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run dm_power lap check
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "suspend=1 off=1 wake=0 why=ok" ]
}

@test "_power: a machine without a registered MAC cannot be woken, so it is not suspended" {
  printf 'lap\tmachine\t10.73.0.2\t2202\t22\tdev\thome\t-\n' >"$DM_CACHE/hosts.tsv"
  printf 'pc2\tmachine\t10.73.0.3\t2203\t24\tdev\thome\taa:bb:cc:dd:ee:02\n' >>"$DM_CACHE/hosts.tsv"
  run dm_power lap check
  [ "$output" = "suspend=0 off=0 wake=0 why=no-mac" ]
}

@test "_power: Wake-on-WLAN off on the machine refuses" {
  ssh_reply lap "dm _power_do caps" "suspend=yes off=yes wol=off"
  run dm_power lap check
  [ "$output" = "suspend=0 off=0 wake=0 why=no-wol" ]
}

@test "_power: a machine that was not updated (no _power_do) is refused" {
  ssh_reply lap "dm _power_do caps" ""
  run dm_power lap check
  [ "$output" = "suspend=0 off=0 wake=0 why=outdated" ]
}

@test "_power: a polkit challenge on the machine offers nothing" {
  ssh_reply lap "dm _power_do caps" "suspend=challenge off=challenge wol=ok"
  run dm_power lap check
  [ "$output" = "suspend=0 off=0 wake=0 why=no-power" ]
}

@test "_power: suspend allowed but power off not" {
  ssh_reply lap "dm _power_do caps" "suspend=yes off=challenge wol=ok"
  run dm_power lap check
  [ "$output" = "suspend=1 off=0 wake=0 why=ok" ]
  run dm_power lap off
  [ "$status" -ne 0 ]
}

@test "_power suspend and off: run _power_do on the machine when allowed" {
  run dm_power lap suspend
  [ "$status" -eq 0 ]
  grep -q 'ssh .* lap dm _power_do suspend' "$STUB_LOG"
  run dm_power lap off
  [ "$status" -eq 0 ]
  grep -q 'ssh .* lap dm _power_do off' "$STUB_LOG"
}

@test "_power: a machine that answers nothing to the action is a failure" {
  ssh_reply lap "dm _power_do suspend" ""
  run dm_power lap suspend
  [ "$status" -ne 0 ]
}

@test "_power: a phone and an unknown device offer nothing" {
  printf 'phone2\tphone\t10.73.0.6\t-\t-\t-\t-\t-\n' >>"$DM_CACHE/hosts.tsv"
  run dm_power phone2 check
  [ "$output" = "suspend=0 off=0 wake=0 why=unsupported" ]
  dm_platform() { printf 'termux\n'; }
  run dm_power tablet check
  [ "$output" = "suspend=0 off=0 wake=0 why=unsupported" ]
  run dm_power nobody check
  [ "$output" = "suspend=0 off=0 wake=0 why=unsupported" ]
}

@test "_power: offline machine can be woken when an online machine shares its LAN label" {
  STUB_SSH_DOWN="lap lap-b" run dm_power lap check
  [ "$output" = "suspend=0 off=0 wake=1 why=ok" ]
  STUB_SSH_DOWN="lap lap-b" run dm_power lap wake
  [ "$status" -eq 0 ]
  grep -q 'ssh .* pc2 dm _wol aa:bb:cc:dd:ee:01' "$STUB_LOG"
}

@test "_power: offline and nobody on its LAN online, no wake" {
  STUB_SSH_DOWN="lap lap-b pc2 pc2-b" run dm_power lap check
  [ "$output" = "suspend=0 off=0 wake=0 why=no-relay" ]
  STUB_SSH_DOWN="lap lap-b pc2 pc2-b" run dm_power lap wake
  [ "$status" -ne 0 ]
}

@test "_power: wake is refused while the machine is online" {
  run dm_power lap wake
  [ "$status" -ne 0 ]
}

@test "_power: only valid host names and actions are accepted" {
  run dm_power 'lap;x' check
  [ "$status" -ne 0 ]
  run dm_power lap reboot
  [ "$status" -ne 0 ]
  run dm_power '' check
  [ "$status" -ne 0 ]
}
