#!/usr/bin/env bats
# dm: names, paths A/B, terminal list, machine-side helpers, refresh validation.

load helpers

setup() {
  export DM_LANG=es # these tests assert the Spanish catalog
  setup_client
}

@test "session names are sanitized to tmux-safe ids" {
  [ "$(dm_sanitize 'My Project.v2:main')" = "my-project-v2-main" ]
  [ "$(dm_sanitize '--a  b--')" = "a-b" ]
  [ "$(dm_sanitize 'ñandú')" = "and" ]
  dm_valid_session main
  dm_valid_session Work_1
  ! dm_valid_session 'a.b'
  ! dm_valid_session ''
  ! dm_valid_session "$(printf 'a%.0s' {1..31})"
}

@test "path A is used when WireGuard works" {
  [ "$(dm_path lap)" = lap ]
}

@test "falls back to path B when path A is down" {
  STUB_SSH_DOWN=lap run dm_path lap
  [ "$output" = lap-b ]
}

@test "unreachable machine fails on both paths" {
  STUB_SSH_DOWN="lap lap-b" run dm_path lap
  [ "$status" -ne 0 ]
}

@test "dm_run: the path probe never eats the stdin meant for the remote command" {
  ssh() {
    # Real ssh forwards stdin to the remote side, even for the "true" probes.
    if [[ $* == *_claude_import* ]]; then
      cat >"$BATS_TEST_TMPDIR/got"
    else
      cat >/dev/null
    fi
  }
  dm_run lap dm _claude_import x y <<<'{"a":1}'
  [ "$(cat "$BATS_TEST_TMPDIR/got")" = '{"a":1}' ]
}

# lan_route near|far — route/ip stubs: is the machine's LAN address directly attached?
lan_route() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  if [[ $1 == near ]]; then
    printf '#!/bin/sh\necho "  interface: en0"\n' >"$BATS_TEST_TMPDIR/bin/route"
    printf '#!/bin/sh\necho "192.168.18.26 dev wlan0 src 192.168.18.32"\n' >"$BATS_TEST_TMPDIR/bin/ip"
  else
    printf '#!/bin/sh\necho "    gateway: 192.168.1.1"\n' >"$BATS_TEST_TMPDIR/bin/route"
    printf '#!/bin/sh\necho "192.168.18.26 via 192.168.1.1 dev wlan0"\n' >"$BATS_TEST_TMPDIR/bin/ip"
  fi
  chmod +x "$BATS_TEST_TMPDIR/bin/route" "$BATS_TEST_TMPDIR/bin/ip"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "path L: a machine on this LAN is reached directly, with a short timeout" {
  printf '192.168.18.26\n' >"$DM_CACHE/lan-lap"
  lan_route near
  [ "$(dm_path lap)" = lap-l ]
  grep -q 'ssh -o ConnectTimeout=1 .* lap-l true' "$STUB_LOG"
}

@test "path L: another network falls through to path A without trying the LAN" {
  printf '192.168.18.26\n' >"$DM_CACHE/lan-lap"
  lan_route far
  [ "$(dm_path lap)" = lap ]
  ! grep -q 'lap-l' "$STUB_LOG"
}

@test "path L: one slow LAN try is retried before giving the LAN up" {
  printf '192.168.18.26\n' >"$DM_CACHE/lan-lap"
  lan_route near
  ssh() {
    printf 'ssh %s\n' "$*" >>"$STUB_LOG"
    [[ $* == *lap-l* ]] || return 0
    # The first LAN try times out, the second answers.
    [[ -e $BATS_TEST_TMPDIR/tried ]] && return 0
    touch "$BATS_TEST_TMPDIR/tried"
    return 255
  }
  [ "$(dm_path lap)" = lap-l ]
  [ ! -e "$DM_CACHE/lan-off-lap" ]
}

@test "path L: a LAN given up is tried again after 2 minutes" {
  [ "$DM_LAN_OFF_MIN" -eq 2 ]
}

@test "path L: a failed LAN try backs off, forgets the address and uses path A" {
  printf '192.168.18.26\n' >"$DM_CACHE/lan-lap"
  lan_route near
  STUB_SSH_DOWN=lap-l run dm_path lap
  [ "$output" = lap ]
  [ -e "$DM_CACHE/lan-off-lap" ]
  : >"$STUB_LOG"
  [ "$(dm_path lap)" = lap ]
  ! grep -q 'lap-l' "$STUB_LOG"
}

# lan_answer TEXT — what a machine answers to DM_LAN_ASK (the shared ssh stub keys replies by
# file name, and this command has slashes): a wrapper in front of it.
lan_answer() {
  mkdir -p "$BATS_TEST_TMPDIR/sshw"
  printf '%s' "$1" >"$BATS_TEST_TMPDIR/lan-answer"
  cat >"$BATS_TEST_TMPDIR/sshw/ssh" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"/run/devmesh/lan"* ]]; then
  printf 'ssh %s\n' "\$*" >>"\$STUB_LOG"
  cat "$BATS_TEST_TMPDIR/lan-answer"
  exit 0
fi
exec "$REPO/tests/stubs/ssh" "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/sshw/ssh"
  export PATH="$BATS_TEST_TMPDIR/sshw:$PATH"
}

@test "path L: the machine's LAN address is learned once and becomes an ssh alias" {
  lan_answer $'192.168.18.26 192.168.18.0/24 wlp1s0\n'
  dm_lan_learn lap lap
  [ "$(cat "$DM_CACHE/lan-lap")" = 192.168.18.26 ]
  cfg=$HOME/.ssh/config.d/devmesh-lan
  grep -qxF 'Host lap-l' "$cfg"
  grep -qxF '  HostName 192.168.18.26' "$cfg"
  grep -qxF '  User dev' "$cfg"
  grep -qxF '  HostKeyAlias lap' "$cfg"
  grep -qxF '  StrictHostKeyChecking yes' "$cfg"
  grep -qxF '  UserKnownHostsFile ~/.ssh/devmesh_known_hosts' "$cfg"
  [ "$(head -n1 "$HOME/.ssh/config")" = "Include config.d/devmesh-lan" ]
  : >"$STUB_LOG"
  dm_lan_learn lap lap
  ! grep -q '/run/devmesh/lan' "$STUB_LOG"
}

@test "path L: a machine off its trusted LANs gives no address" {
  lan_answer ''
  dm_lan_learn lap lap
  [ "$(cat "$DM_CACHE/lan-lap")" = - ]
  ! grep -q 'Host lap-l' "$HOME/.ssh/config.d/devmesh-lan"
}

@test "path L: public, mesh, octal-looking or malformed answers are never used" {
  export DM_IP=10.73.0.4
  dm_lan_valid 192.168.18.26
  dm_lan_valid 10.1.2.3
  dm_lan_valid 172.16.0.1
  dm_lan_valid 172.31.255.254
  ! dm_lan_valid 172.32.0.1
  ! dm_lan_valid 8.8.8.8
  ! dm_lan_valid 10.73.0.2
  ! dm_lan_valid 192.168.1.300
  ! dm_lan_valid 010.1.2.3
  ! dm_lan_valid 192.168.01.2
  ! dm_lan_valid '192.168.1.1 -oProxyCommand=x'
  lan_answer $'203.0.113.7 203.0.113.0/24 eth0\n'
  dm_lan_learn lap lap
  [ "$(cat "$DM_CACHE/lan-lap")" = - ]
}

@test "path L: no alias over a device that is really named <machine>-l" {
  printf 'lap-l\tphone\t10.73.0.9\t-\t-\t-\t-\t-\n' >>"$DM_CACHE/hosts.tsv"
  lan_answer $'192.168.18.26 192.168.18.0/24 wlp1s0\n'
  dm_lan_learn lap lap
  ! grep -q 'Host lap-l' "$HOME/.ssh/config.d/devmesh-lan"
}

@test "remote attach creates the session with trace metadata in the project dir" {
  mkdir -p "$HOME/PROJECTS/redi"
  run dm_remote_attach redi proj:redi tablet
  grep -q "tmux new-session -d -s redi -c $HOME/PROJECTS/redi" "$STUB_LOG"
  grep -q 'tmux set-option -t redi @origin tablet' "$STUB_LOG"
  grep -q 'tmux set-option -t redi @created [0-9]' "$STUB_LOG"
  grep -q 'tmux -u attach-session -t =redi' "$STUB_LOG"
}

@test "remote attach never escapes the projects dir and reuses existing sessions" {
  run dm_remote_attach x 'proj:../../etc' tablet
  grep -q "new-session -d -s x -c $HOME\$" "$STUB_LOG"
  : >"$STUB_LOG"
  STUB_TMUX_HAS=redi run dm_remote_attach redi - pc2 2
  ! grep -q new-session "$STUB_LOG"
  grep -q 'select-window -t =redi:2' "$STUB_LOG"
  run dm_remote_attach 'bad.name' - tablet
  [ "$status" -ne 0 ]
}

@test "remote dest: inbox is created, projects must exist, traversal refused" {
  run dm_remote_dest inbox
  [ "$output" = "$HOME/devmesh-inbox" ]
  [ -d "$HOME/devmesh-inbox" ]
  run dm_remote_dest proj:nope
  [ "$status" -ne 0 ]
  run dm_remote_dest 'proj:../x'
  [ "$status" -ne 0 ]
  run dm_remote_dest /etc
  [ "$status" -ne 0 ]
}

@test "file pickers survive missing folders under pipefail" {
  set -o pipefail
  run dm_local_candidates
  [ "$status" -eq 0 ]
  mkdir -p "$HOME/Downloads"
  touch "$HOME/Downloads/shot.png"
  run dm_local_candidates
  [ "$output" = "$HOME/Downloads/shot.png" ]
  run dm_remote_recent
  [ "$status" -eq 0 ]
}

@test "wake-on-lan rejects malformed MACs" {
  run dm_remote_wol 'aa:bb;rm'
  [ "$status" -ne 0 ]
}

@test "wake picks an online relay on the same LAN" {
  run dm_wake lap
  [ "$status" -eq 0 ]
  grep -q 'ssh .* pc2 dm _wol aa:bb:cc:dd:ee:01' "$STUB_LOG"
}

@test "refresh rejects a malformed device list and keeps the old one" {
  before=$(cat "$DM_CACHE/hosts.tsv")
  ssh_reply hub-admin ssh-config $'Host hub-admin\n'
  ssh_reply hub-admin known-hosts $'hub ssh-ed25519 AAAA\n'
  ssh_reply hub-admin hosts $'broken line\n'
  run dm_refresh
  [ "$status" -ne 0 ]
  [ "$(cat "$DM_CACHE/hosts.tsv")" = "$before" ]
}

@test "refresh installs valid hub exports" {
  t=$'\t'
  ssh_reply hub-admin ssh-config "$(min_cfg)"
  ssh_reply hub-admin known-hosts $'hub ssh-ed25519 AAAA\n'
  ssh_reply hub-admin hosts "lap${t}machine${t}10.73.0.2${t}2202${t}22${t}dev${t}-${t}-"$'\n'
  run dm_refresh
  [ "$status" -eq 0 ]
  grep -q '^Host hub-admin$' "$HOME/.ssh/config.d/devmesh"
  [ "$(grep -c . "$DM_CACHE/hosts.tsv")" -eq 1 ]
}

@test "dm entrypoint: unknown commands fail, help works without enrollment" {
  run env DM_CONF=/nonexistent bash "$REPO/client/bin/dm" help
  [ "$status" -eq 0 ]
  [[ $output == *"dm use"* && $output == *"dm herdr allow"* ]]
  run env DM_CONF=/nonexistent bash "$REPO/client/bin/dm" go
  [ "$status" -ne 0 ]
  [[ $output == *"not enrolled"* ]]
  run bash "$REPO/client/bin/dm" frobnicate
  [ "$status" -ne 0 ]
}

@test "dm add asks nothing, validates locally and sends clean arguments" {
  ssh_reply hub-admin "invite tablet" $'Add "tablet": ...\n\nJOIN: curl -fsSL https://hub.example.test/j/ABCDEFGHJKMN | sh -s ABCDEFGHJKMN\n'
  run dm_add tablet </dev/null
  [ "$status" -eq 0 ]
  [[ $output == *"curl -fsSL https://hub.example.test/j/ABCDEFGHJKMN | sh -s ABCDEFGHJKMN"* ]]
  grep -q '^ssh .* hub-admin invite tablet$' "$STUB_LOG"
}

@test "dm add rejects a LAN label with spaces before reaching the hub" {
  run dm_add tablet --lan "home tablet"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid --lan 'home tablet'"* ]]
  ! grep -q 'hub-admin' "$STUB_LOG"
  run dm_add "My Tablet"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid name"* ]]
}

@test "dm add passes --lan and --watch-hub as separate validated words" {
  ssh_reply hub-admin "invite lap --lan home --watch-hub" $'JOIN: curl -fsSL https://h/j/ABCDEFGHJKMN | sh -s ABCDEFGHJKMN\n'
  run dm_add lap --lan home --watch-hub
  [ "$status" -eq 0 ]
  grep -q 'hub-admin invite lap --lan home --watch-hub$' "$STUB_LOG"
}

@test "with no machines, terminal commands explain what to do instead of an empty list" {
  printf 'tablet\tphone\t10.73.0.4\t-\t-\t-\t-\t-\n' >"$DM_CACHE/hosts.tsv"
  for f in dm_go dm_use dm_power_cmd; do
    run "$f" </dev/null
    [ "$status" -ne 0 ]
    [[ $output == *"no machines yet"* && $output == *"dm add"* ]] || {
      echo "$f: $output"
      return 1
    }
  done
}

@test "remote projects listing is portable (no find -printf) and skips hidden dirs" {
  mkdir -p "$HOME/PROJECTS/redi" "$HOME/PROJECTS/.git" "$HOME/PROJECTS/api"
  touch "$HOME/PROJECTS/file.txt"
  run dm_remote_projects
  [ "$output" = $'api\nredi' ]
}

@test "remote capture validates its arguments" {
  run dm_remote_capture 'bad.name' 0
  [ "$status" -ne 0 ]
  run dm_remote_capture main 'x'
  [ "$status" -ne 0 ]
}

@test "mosh is never used through the hub (ProxyJump), only for direct paths" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "mosh $*" >>"$STUB_LOG"\n' >"$BATS_TEST_TMPDIR/bin/mosh"
  chmod +x "$BATS_TEST_TMPDIR/bin/mosh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  ssh_reply lap _G $'hostname localhost\nproxyjump hub-jump\n'
  dm_tty lap "dm _attach main - tablet"
  ! grep -q '^mosh' "$STUB_LOG"
  grep -q '^ssh -t .* lap dm _attach main - tablet' "$STUB_LOG"
  : >"$STUB_LOG"
  ssh_reply pc2 _G $'hostname 10.73.0.3\n'
  dm_tty pc2 "dm _attach main - tablet"
  grep -q '^mosh pc2' "$STUB_LOG"
  ! grep -q '^ssh -t' "$STUB_LOG"
}

@test "a mosh that fails right away opens the same terminal over ssh" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh
echo "mosh $*" >>"$STUB_LOG"
exit 1
' >"$BATS_TEST_TMPDIR/bin/mosh"
  chmod +x "$BATS_TEST_TMPDIR/bin/mosh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  ssh_reply pc2 _G $'hostname 10.73.0.3\n'
  dm_tty pc2 "dm _attach main - tablet"
  grep -q '^mosh pc2' "$STUB_LOG"
  grep -q '^ssh -t .* pc2 dm _attach main - tablet' "$STUB_LOG"
  # Remembered: the next terminal on that machine goes straight to ssh.
  : >"$STUB_LOG"
  dm_tty pc2 "dm _attach api - tablet"
  ! grep -q '^mosh' "$STUB_LOG"
  grep -q '^ssh -t .* pc2 dm _attach api - tablet' "$STUB_LOG"
}

@test "this device is reached locally: dm_run and dm_tty never ssh to themselves" {
  export DM_SELF="$REPO/client/bin/dm" DM_NAME=tablet
  run dm_run tablet dm version
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run dm_tty tablet "dm version"
  [ "$status" -eq 0 ]
  ! grep -q "^ssh .*tablet" "$STUB_LOG"
  [ "$(dm_path tablet)" = tablet ]
  run dm_local rm -rf /
  [ "$status" -eq 2 ]
}

@test "auto update: a Mac or phone installs a newer signed client when dm opens, then starts on it" {
  dm_trust_active() { return 0; }
  dm_platform() { echo macos; }
  dm_version() { echo 0.9.13; }
  dm_update() { echo update >>"$STUB_LOG"; }
  printf '#!/usr/bin/env bash\necho "restarted DM_UPDATED=$DM_UPDATED"\n' >"$BATS_TEST_TMPDIR/newdm"
  export DM_SELF="$BATS_TEST_TMPDIR/newdm"
  ssh_reply hub-admin version $'0.9.14\n'
  run dm_auto_update
  [ "$status" -eq 0 ]
  [[ $output == *"0.9.14"* && $output == *"restarted DM_UPDATED=1"* ]]
  grep -q '^update$' "$STUB_LOG"
}

@test "auto update: nothing on Linux, in open mode, when up to date, or within the check interval" {
  dm_platform() { echo macos; }
  dm_version() { echo 0.9.14; }
  dm_update() { echo update >>"$STUB_LOG"; }
  ssh_reply hub-admin version $'0.9.14\n'
  dm_trust_active() { return 0; }
  run dm_auto_update
  [ "$status" -eq 0 ]
  ssh_reply hub-admin version $'0.9.15\n'
  run dm_auto_update
  [ "$status" -eq 0 ]
  rm -f "$DM_CACHE/update-check"
  dm_trust_active() { return 1; }
  run dm_auto_update
  dm_trust_active() { return 0; }
  dm_platform() { echo linux; }
  run dm_auto_update
  ! grep -q '^update$' "$STUB_LOG"
}
