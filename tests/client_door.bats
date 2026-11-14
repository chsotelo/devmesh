#!/usr/bin/env bats
# dm door: a timed sshd on a phone that only approver-signed machines may enter, and the
# "<device>-door" aliases machines check against the phone's signed client key.

load helpers

setup() {
  setup_hub
  setup_client
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_common.sh"
  K=$BATS_TEST_TMPDIR/keys
  mkdir -p "$K"
  export DM_TEST=1
}

teardown() {
  local p=$(dirname "$DM_CONF")/door/sshd.pid
  if [[ -r $p ]]; then kill "$(cat "$p")" 2>/dev/null || true; fi
  /usr/bin/pkill -f "dm-door-timer $(dirname "$DM_CONF")/door" 2>/dev/null || true
}

pubof() { awk '{print $1 " " $2}' "$1.pub"; }
owner_sign() { tr_sign "$HOME/.ssh/id_devmesh" "$(tr_msg "$1" "$2" "$3")"; }
admin() { SSH_ORIGINAL_COMMAND=$1 devmesh _ssh tablet; }

enroll_dev() {
  local name=$1 kind=$2 code
  devmesh invite "$name" $([[ $kind == phone ]] && echo --phone) >/dev/null
  code=$(invite_code)
  {
    printf 'kind %s\nwg %s\n' "$kind" "$(new_wg_pub)"
    printf 'client %s\n' "$(new_ssh_pub "$K/$name-client")"
    if [[ $kind == machine ]]; then
      printf 'tunnel %s\nhost %s\nuser dev\n' "$(new_ssh_pub "$K/$name-tunnel")" "$(new_ssh_pub "$K/$name-host")"
    fi
  } | devmesh _enroll "$code" >/dev/null
}

# The owner is this test's "tablet" (a phone): its key is ~/.ssh/id_devmesh.
enroll_owner() {
  local code
  export STUB_ADMIN_CMD="bash '$REPO/server/sbin/devmesh' _ssh tablet"
  devmesh invite tablet --phone --owner >/dev/null
  code=$(invite_code)
  printf 'kind phone\nwg %s\nclient %s\n' "$(new_wg_pub)" "$(new_ssh_pub "$HOME/.ssh/id_devmesh")" |
    devmesh _enroll "$code" >/dev/null
  DM_NAME=tablet DM_OWNER=1 bs_trust_setup "$(dm_allowed_signers)" "$HOME/.ssh/id_devmesh.pub"
  printf 'DM_TRUST=signed\nDM_IP=10.73.0.4\n' >>"$DM_CONF"
  DM_TRUST=signed DM_IP=10.73.0.4
}

# lap: approved machine · pc2: machine still pending · fon: approved phone.
mesh() {
  enroll_owner
  enroll_dev lap machine
  enroll_dev pc2 machine
  enroll_dev fon phone
  admin "approve lap" <<<"client $(owner_sign client lap "$(pubof "$K/lap-client")")"$'\n'"host $(owner_sign host lap "$(pubof "$K/lap-host")")" >/dev/null
  admin "approve fon" <<<"client $(owner_sign client fon "$(pubof "$K/fon-client")")" >/dev/null
  local t=$'\t' hub_line
  hub_line="hub.example.test,10.73.0.1 $(devmesh known-hosts | head -n1 | awk '{print $2 " " $3}')"
  ssh_reply hub-admin ssh-config "$(min_cfg)"
  ssh_reply hub-admin known-hosts "$hub_line"$'\n'
  ssh_reply hub-admin hosts "lap${t}machine${t}10.73.0.2${t}2202${t}22${t}dev${t}-${t}-"$'\n'"pc2${t}machine${t}10.73.0.3${t}2203${t}24${t}dev${t}-${t}-"$'\n'"tablet${t}phone${t}10.73.0.4${t}-${t}-${t}-${t}-${t}-"$'\n'"fon${t}phone${t}10.73.0.6${t}-${t}-${t}-${t}-${t}-"$'\n'
  unset STUB_ADMIN_CMD
  devmesh bundle >"$STUB_SSH_DIR/hub-admin/bundle"
  printf 'hub.example.test,10.73.0.1 ssh-ed25519 PINNED\n' >"$HOME/.ssh/devmesh_known_hosts"
}

# The door opens on "fon", a phone that is not an approver (the owner tablet is).
door() { DM_DOOR_ANY_PLATFORM=1 DM_ID_KEY="$K/fon-client" DM_NAME=fon DM_IP=10.73.0.6 dm_door "$@"; }
DOOR() { printf '%s/door\n' "$(dirname "$DM_CONF")"; }

@test "door: time is 1m to 8h, minutes or hours" {
  [ "$(dm_door_seconds 30m)" = 1800 ]
  [ "$(dm_door_seconds 2h)" = 7200 ]
  [ "$(dm_door_seconds 4h)" = 14400 ]
  for bad in 0m 5h 9h 30 1d -5m 30m5 ''; do
    run dm_door_seconds "$bad"
    [ "$status" -ne 0 ]
  done
}

@test "door: sshd listens only on the mesh address, keys only, nothing forwarded" {
  run dm_door_sshd_config /d 10.73.0.4 /k
  [[ $output == *$'\nListenAddress 10.73.0.4\n'* ]]
  [[ $output == *$'\nPort 8022\n'* ]]
  [[ $output == *"PasswordAuthentication no"* && $output == *"KbdInteractiveAuthentication no"* ]]
  [[ $output == *"AuthenticationMethods publickey"* && $output == *"AuthorizedKeysFile /d/authorized_keys"* ]]
  [[ $output == *"AllowTcpForwarding no"* && $output == *"AllowAgentForwarding no"* && $output == *"PermitTunnel no"* ]]
  [ "$(grep -c '^ListenAddress' <<<"$output")" -eq 1 ]
}

@test "door open: only approved machines get in, each pinned to its mesh address" {
  mesh
  run door open 30m
  [ "$status" -eq 0 ]
  keys=$(cat "$(DOOR)/authorized_keys")
  [ "$keys" = "from=\"10.73.0.2\",restrict $(pubof "$K/lap-client") devmesh-door:lap" ]
  [[ $output == *"door open on 10.73.0.6:8022 for 30m (lap)"* ]]
  [ "$(ls -ld "$(DOOR)" | cut -c1-10)" = drwx------ ]
  grep -q "^sshd -f $(DOOR)/sshd_config" "$STUB_LOG"
  [[ $(door status) == "open on 10.73.0.6:8022, closes in "* ]]
  grep -q '^ListenAddress 10.73.0.6$' "$(DOOR)/sshd_config"
  grep -q "^HostKey $K/fon-client$" "$(DOOR)/sshd_config"
}

@test "door open: a machine the hub swapped in (unsigned host key) stays out" {
  mesh
  # The hub claims pc2's client key is signed by reusing lap's signature: dropped.
  sed -i.bak "s|^client lap \(ssh-ed25519 [^ ]*\) |client pc2 $(pubof "$K/pc2-client") |" "$STUB_SSH_DIR/hub-admin/bundle"
  run door open
  [ "$status" -ne 0 ]
  [[ $output == *"no approved machine"* ]]
  [ ! -e "$(DOOR)/authorized_keys" ]
  ! grep -q '^sshd' "$STUB_LOG"
}

@test "door open: refused in open mode, on a machine, or with a bad time" {
  run door open 30m
  [ "$status" -ne 0 ]
  [[ $output == *"signed mode"* ]]
  mesh
  run dm_door open
  [[ $output == *"phone or tablet"* ]]
  run door open 12h
  [[ $output == *"invalid time"* ]]
  # An approver's key signs devices: a machine let in could copy it.
  DM_DOOR_ANY_PLATFORM=1 DM_IP=10.73.0.4 run dm_door open
  [ "$status" -ne 0 ]
  [[ $output == *"is an approver"* ]]
  ! grep -q '^sshd' "$STUB_LOG"
}

@test "door: a stale pid file naming someone else's process is never signalled" {
  mesh
  mkdir -p "$(DOOR)"
  sleep 300 </dev/null >/dev/null 2>&1 3>&- &
  other=$!
  printf '%s\n' "$other" >"$(DOOR)/sshd.pid"
  printf '%s\n' "$other" >"$(DOOR)/timer.pid"
  printf '0\n' >"$(DOOR)/until"
  run door close
  [[ $output == *"was not open"* ]]
  kill -0 "$other"
  [ "$(door status)" = closed ]
  kill "$other"
}

@test "door open: sshd failing to bind (tunnel off) leaves no keys behind the error" {
  mesh
  STUB_SSHD_FAIL=1 run door open
  [ "$status" -ne 0 ]
  [[ $output == *"WireGuard tunnel"* ]]
  [ ! -e "$(DOOR)/authorized_keys" ] && [ ! -e "$(DOOR)/sshd_config" ]
}

@test "door close: sshd and timer stopped, keys and config removed" {
  mesh
  door open 5m >/dev/null 2>&1
  pid=$(cat "$(DOOR)/sshd.pid")
  timer=$(cat "$(DOOR)/timer.pid")
  child=$(pgrep -P "$pid")
  kill -0 "$pid" && kill -0 "$timer" && kill -0 "$child"
  run door close
  [[ $output == *"door closed"* ]]
  sleep 0.3
  ! kill -0 "$pid" 2>/dev/null
  ! kill -0 "$child" 2>/dev/null
  ! kill -0 "$timer" 2>/dev/null
  [ ! -e "$(DOOR)/authorized_keys" ] && [ ! -e "$(DOOR)/sshd_config" ] && [ ! -e "$(DOOR)/timer.pid" ]
  [ "$(door status)" = closed ]
  run door close
  [[ $output == *"was not open"* ]]
}

@test "machine refresh: <phone>-door aliases checked against the phone's signed client key" {
  mesh
  DM_KIND=machine
  run dm_refresh
  [ "$status" -eq 0 ]
  known=$(cat "$HOME/.ssh/devmesh_known_hosts")
  [[ $known == *"devmesh-door-fon $(pubof "$K/fon-client")"* ]]
  [[ $known == *"devmesh-door-tablet $(pubof "$HOME/.ssh/id_devmesh")"* ]]
  [[ $known != *"devmesh-door-lap"* && $known != *"devmesh-door-pc2"* ]]
  cfg=$(cat "$HOME/.ssh/config.d/devmesh-door")
  [[ $cfg == *$'Host fon-door\n  HostName 10.73.0.6\n  HostKeyAlias devmesh-door-fon'* ]]
  [[ $cfg == *"StrictHostKeyChecking yes"* && $cfg == *"Port 8022"* ]]
  [[ $cfg != *"lap-door"* ]]
  grep -qxF 'Include config.d/devmesh-door' "$HOME/.ssh/config"
}

@test "phone refresh writes no door aliases" {
  mesh
  run dm_refresh
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.ssh/config.d/devmesh-door" ]
}
