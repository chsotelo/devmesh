#!/usr/bin/env bats
# Herdr on the mesh: the mobile app's keys on every machine (dm herdr), dm use, dm power.

load helpers

KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIEXLRAJBEPPkAFFOE1fycCswpwLZ3lJmT93re0ErGPd'
KEY2='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKeyOtherKey12'

setup() {
  export DM_LANG=en
  setup_client
  AK="$HOME/.ssh/authorized_keys"
}

@test "the key is found in the line the Herdr app shows, and nothing else passes" {
  run dm_herdr_key_from "mkdir -p ~/.ssh && echo '$KEY herdr-mobile' >> ~/.ssh/authorized_keys"
  [ "$output" = "$KEY" ]
  run dm_herdr_key_from "echo hello; rm -rf ~"
  [ -z "$output" ]
}

@test "machine side: add pins the key to the device address, without forwarding, replacing older copies" {
  printf 'ssh-ed25519 AAAAOWNKEYownkeyownkeyownkeyownkeyownkeyownkey me@laptop\n%s herdr-mobile\n' "$KEY" >"$AK"
  run dm_remote_herdr add tablet 10.73.0.3 ${KEY% *} ${KEY#* }
  [ "$status" -eq 0 ]
  [[ $output == ok* ]]
  # The user's own key stays; the hand-pasted copy of the same key is replaced by the managed line.
  grep -q 'me@laptop' "$AK"
  [ "$(grep -c "${KEY#* }" "$AK")" -eq 1 ]
  grep -qx "from=\"10.73.0.3\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding $KEY devmesh-herdr:tablet" "$AK"
  [ "$(stat -c %a "$AK" 2>/dev/null || stat -f %Lp "$AK")" = 600 ]
  # Adding again (or a new key for the same device) leaves exactly one line for it.
  dm_remote_herdr add tablet 10.73.0.3 ${KEY2% *} ${KEY2#* } >/dev/null
  [ "$(grep -c 'devmesh-herdr:tablet$' "$AK")" -eq 1 ]
  grep -q "${KEY2#* }" "$AK"
  run dm_remote_herdr ls
  [[ $output == "tablet"$'\t'"ssh-ed25519"$'\t'* ]]
}

@test "machine side: rm drops only that device's lines; bad input never reaches the file" {
  dm_remote_herdr add tablet 10.73.0.3 ${KEY% *} ${KEY#* } >/dev/null
  dm_remote_herdr add phone 10.73.0.5 ${KEY2% *} ${KEY2#* } >/dev/null
  printf 'ssh-ed25519 AAAAOWNKEYownkeyownkeyownkeyownkeyownkeyownkey devmesh-herdr:tablet-old\n' >>"$AK"
  dm_remote_herdr rm tablet >/dev/null
  ! grep -q 'devmesh-herdr:tablet$' "$AK"
  grep -q 'devmesh-herdr:phone$' "$AK"
  grep -q 'devmesh-herdr:tablet-old$' "$AK"
  before=$(cat "$AK")
  run dm_remote_herdr add 'x;y' 10.73.0.3 ${KEY% *} ${KEY#* }
  [ "$status" -ne 0 ]
  run dm_remote_herdr add tablet '10.73.0.3" ,command="sh' ${KEY% *} ${KEY#* }
  [ "$status" -ne 0 ]
  run dm_remote_herdr add tablet 10.73.0.3 ssh-ed25519 'AAAA x" command="id'
  [ "$status" -ne 0 ]
  [ "$(cat "$AK")" = "$before" ]
}

@test "allow sends the device's mesh address and the key to every machine, and says which missed" {
  dm_herdr_each() {
    printf '%s\n' "$*" >>"$BATS_TEST_TMPDIR/each.log"
    printf 'lap\tok\npc2\toffline\n'
  }
  run dm_herdr_allow tablet "echo '$KEY herdr-mobile' >> ~/.ssh/authorized_keys"
  [ "$status" -eq 0 ]
  grep -qx "add tablet 10.73.0.4 $KEY" "$BATS_TEST_TMPDIR/each.log"
  [[ $output == *"lap: ok"* && $output == *"pc2: offline"* && $output == *"run it again"* ]]
  run dm_herdr_allow ghost "$KEY"
  [ "$status" -ne 0 ]
  run dm_herdr_allow tablet "no key here"
  [ "$status" -ne 0 ]
}

@test "dm use wakes a sleeping machine, then starts the command in Herdr there" {
  dm_path() { [[ -e $BATS_TEST_TMPDIR/awake ]]; }
  dm_power() { printf 'power %s\n' "$*" >>"$BATS_TEST_TMPDIR/calls" && : >"$BATS_TEST_TMPDIR/awake"; }
  dm_run() {
    printf 'run %s\n' "$*" >>"$BATS_TEST_TMPDIR/calls"
    [[ $* == *"_herdr run"* ]] && printf '{"address":"t7","agent":"claude","state":"live"}\n'
    return 0
  }
  sleep() { :; }
  run dm_use lap --cwd '/home/dev/my app' -- claude --model 'opus 4'
  [ "$status" -eq 0 ]
  grep -qx 'power lap wake' "$BATS_TEST_TMPDIR/calls"
  grep -qx 'run lap dm _herdr hc' "$BATS_TEST_TMPDIR/calls"
  # Each word is quoted for the remote shell: spaces survive the ssh hop.
  grep -qF "run lap dm _herdr run --cwd /home/dev/my\\ app -- claude --model opus\\ 4" "$BATS_TEST_TMPDIR/calls"
  [[ $output == *"started t7 on lap"* ]]
}

@test "dm use says Herdr is optional when the machine has no herdr-core, and never installs it" {
  dm_path() { return 0; }
  dm_run() {
    printf 'run %s\n' "$*" >>"$BATS_TEST_TMPDIR/calls"
    [[ $* != *"_herdr hc"* ]]
  }
  run dm_use lap
  [ "$status" -ne 0 ]
  [[ $output == *"herdr-core is not on lap"* && $output == *"optional"* ]]
  ! grep -q '_herdr run' "$BATS_TEST_TMPDIR/calls"
  run dm_use tablet
  [ "$status" -ne 0 ]
}

@test "dm power status says what can be done, or why not" {
  dm_path() { return 0; }
  dm_power() { printf 'suspend=1 off=0 wake=0 why=ok\n'; }
  run dm_power_cmd lap status
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "lap is on" && ${lines[1]} == "can: suspend" ]]
  dm_path() { return 1; }
  dm_power() { printf 'suspend=0 off=0 wake=0 why=no-relay\n'; }
  run dm_power_cmd lap
  [[ ${lines[0]} == "lap is off or asleep" && ${lines[1]} == *"No other machine is online"* ]]
  run dm_power_cmd lap explode
  [ "$status" -ne 0 ]
}

@test "a machine that answers but has an older devmesh is reported as outdated, not offline" {
  dm_run() { return 127; }
  dm_path() { [[ $1 == lap ]]; }
  run dm_herdr_ls
  [[ $output == *"lap              (outdated)"* && $output == *"pc2              (offline)"* ]]
  dm_run() {
    [[ $1 == lap ]] && printf 'tablet\tssh-ed25519\tAAAAC3NzaC1lZDI1…\n'
    return 0
  }
  run dm_herdr_ls
  [[ $output == *"lap              tablet"* && $output == *"pc2              (none)"* ]]
}

@test "herdr ls never prints raw machine output; a symlinked authorized_keys is left alone" {
  dm_path() { return 0; }
  dm_run() { [[ $1 == lap ]] && printf 'tablet\tssh-ed25519\t\033]0;owned\007\n'; return 0; }
  run dm_herdr_ls
  [[ $output == *"lap              (unreadable line)"* && $output != *owned* ]]
  printf 'x\n' >"$BATS_TEST_TMPDIR/real_keys"
  ln -s "$BATS_TEST_TMPDIR/real_keys" "$AK"
  run dm_remote_herdr add tablet 10.73.0.3 ${KEY% *} ${KEY#* }
  [ "$status" -ne 0 ]
  [ -L "$AK" ] && [ "$(cat "$BATS_TEST_TMPDIR/real_keys")" = x ]
}
