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

@test "terminal list: machine color, global id, agent state, offline machines" {
  t=$'\t'
  ssh_reply lap "dm _who" "redi${t}1${t}redi:claude${t}1${t}claude${t}waiting${t}tablet${t}1700000000${t}$(date +%s)${t}tablet,local"$'\n'
  STUB_SSH_DOWN="pc2 pc2-b" COLUMNS=120 run dm_term_lines
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "lap${t}redi${t}1${t}"* ]]
  [[ ${lines[0]} == *$'\033[38;5;22m●'* ]]
  [[ ${lines[0]} == *"lap:redi:1*"* ]]
  [[ ${lines[0]} == *"waiting"* ]]
  [[ ${lines[0]} == *"[tablet,local]"* ]]
  [[ ${lines[1]} == "pc2${t}-${t}-${t}"*"OFFLINE"* ]]
}

@test "terminal list: compact format on narrow screens" {
  t=$'\t'
  ssh_reply lap "dm _who" "main${t}0${t}x${t}1${t}zsh${t}-${t}-${t}-${t}0${t}-"$'\n'
  STUB_SSH_DOWN="pc2 pc2-b" COLUMNS=40 run dm_term_lines
  [[ ${lines[0]} == *"lap:main:0* zsh"* ]]
  [[ ${lines[0]} != *"·"* ]]
}

@test "a machine with no tmux sessions is listed as empty, not offline" {
  STUB_SSH_DOWN="pc2 pc2-b" run dm_term_lines
  [[ ${lines[0]} == *"lap  (no terminals)"* ]]
}

@test "remote who: one line per window with attached device names" {
  t=$'\t'
  s='|~|'
  printf 'redi%s1%sredi:claude%s1%sclaude%sworking%stablet%s1700000000%s1700000100\n' "$s" "$s" "$s" "$s" "$s" "$s" "$s" "$s" >"$BATS_TEST_TMPDIR/w"
  printf 'logs%s0%slogs:tail%s1%stail%s%s%s%s1700000200\n' "$s" "$s" "$s" "$s" "$s" "$s" "$s" "$s" >>"$BATS_TEST_TMPDIR/w"
  mkdir -p "$BATS_TEST_TMPDIR/proc/4242"
  printf 'HOME=/x\0DEVMESH_FROM=tablet\0' >"$BATS_TEST_TMPDIR/proc/4242/environ"
  printf '4242%sredi\n4343%sredi\n' "$s" "$s" >"$BATS_TEST_TMPDIR/c"
  DM_PROC="$BATS_TEST_TMPDIR/proc" STUB_TMUX_WINDOWS="$BATS_TEST_TMPDIR/w" STUB_TMUX_CLIENTS="$BATS_TEST_TMPDIR/c" run dm_remote_who
  [ "${lines[0]}" = "redi${t}1${t}redi:claude${t}1${t}claude${t}working${t}tablet${t}1700000000${t}1700000100${t}tablet,local" ]
  [ "${lines[1]}" = "logs${t}0${t}logs:tail${t}1${t}tail${t}-${t}-${t}-${t}1700000200${t}-" ]
}

@test "remote attach creates the session with trace metadata in the project dir" {
  mkdir -p "$HOME/PROJECTS/redi"
  run dm_remote_attach redi proj:redi tablet
  grep -q "tmux new-session -d -s redi -c $HOME/PROJECTS/redi" "$STUB_LOG"
  grep -q 'tmux set-option -t =redi @origin tablet' "$STUB_LOG"
  grep -q 'tmux set-option -t =redi @created [0-9]' "$STUB_LOG"
  grep -q 'tmux attach-session -t =redi' "$STUB_LOG"
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

@test "agent state is set on the calling pane only" {
  TMUX_PANE=%3 dm_agent waiting
  grep -q 'tmux set-option -p -t %3 @agent waiting' "$STUB_LOG"
  TMUX_PANE=%3 dm_agent clear
  grep -q 'tmux set-option -p -u -t %3 @agent' "$STUB_LOG"
  run env -u TMUX_PANE bash -c "source '$REPO/client/lib/dm_core.sh'; source '$REPO/client/lib/dm_remote.sh'; dm_agent working"
  [ "$status" -eq 0 ]
  TMUX_PANE=%3 run dm_agent hacked
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
  [[ $output == *"dm new"* ]]
  run env DM_CONF=/nonexistent bash "$REPO/client/bin/dm" terms
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
  for f in dm_terms dm_new dm_who; do
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

@test "remote who survives tmux's C-locale tab mangling (real tmux, LC_ALL=C)" {
  command -v /opt/homebrew/bin/tmux >/dev/null || skip "no real tmux"
  sock="$BATS_TEST_TMPDIR/tmux.sock"
  tm() { LC_ALL=C /opt/homebrew/bin/tmux -S "$sock" "$@"; }
  tm new-session -d -s work -n "redi:claude"
  # dm_remote_who calls "tmux"; point it at the private server under the C locale.
  tmux() { LC_ALL=C /opt/homebrew/bin/tmux -S "$sock" "$@"; }
  run dm_remote_who
  tm kill-server
  [[ ${lines[0]} == "work"$'\t'"0"$'\t'"redi:claude"$'\t'* ]] || {
    echo "got: ${lines[0]}"
    return 1
  }
}

@test "panel: one card per machine, its terminals with state, then the big actions" {
  t=$'\t'
  ssh_reply lap "dm _who" "redi${t}1${t}redi:claude${t}1${t}claude${t}waiting${t}tablet${t}1700000000${t}$(date +%s)${t}tablet"$'\n'
  STUB_SSH_DOWN="pc2 pc2-b" run dm_ui_rows
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "machine${t}lap${t}-${t}-${t}"*"lap"*"1 terminal"* ]]
  [[ ${lines[0]} != *"toca para"* ]]
  [[ ${lines[1]} == "term${t}lap${t}redi${t}1${t}"*"redi"*"claude"*"esperando"* ]]
  printf '%s\n' "${lines[@]}" | grep -q "^offline${t}pc2"
  printf '%s\n' "${lines[@]}" | grep -q "^action${t}new${t}.*Nueva terminal"
  printf '%s\n' "${lines[@]}" | grep -q "^action${t}quit"
}

@test "panel preview shows the live screen of a terminal and explains actions" {
  ssh_reply lap "dm _capture redi 1" $'$ claude\n> working on it\n'
  run dm_ui_preview term lap redi 1
  [[ $output == *"lap:redi:1"* && $output == *"> working on it"* ]]
  run dm_ui_preview action new
  [[ $output == *"Crea una terminal"* ]]
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
}

@test "workspace: opening a terminal focuses its tab, or creates it with the machine color" {
  TMUX=fake
  printf '@7 mac:redi\n' >"$BATS_TEST_TMPDIR/wins"
  tmux() {
    printf 'tmux %s\n' "$*" >>"$STUB_LOG"
    case $1 in
      list-windows) cat "$BATS_TEST_TMPDIR/wins" ;;
      new-window) echo @9 ;;
    esac
  }
  dm_ws_open mac redi
  grep -q '^tmux select-window -t @7$' "$STUB_LOG"
  ! grep -q new-window "$STUB_LOG"
  : >"$STUB_LOG"
  dm_ws_open lap api
  grep -q '^tmux new-window -P -F #{window_id} -n lap:api ' "$STUB_LOG"
  grep -q '^tmux set-option -w -t @9 @dm_color 22$' "$STUB_LOG"
}

@test "workspace tab: a clean detach closes it, a dropped link offers reconnect or close" {
  tmux() { printf 'tmux %s\n' "$*" >>"$STUB_LOG"; }
  dm_tty() { return 0; }
  run dm_ws_tab lap main - -
  [ "$status" -eq 0 ]
  grep -q 'tmux select-window -t :=panel' "$STUB_LOG"
  dm_tty() { return 255; }
  run dm_ws_tab lap main - - <<<"q"
  [ "$status" -eq 0 ]
  [[ $output == *"Conexión con lap perdida"* ]]
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

@test "workspace tabs: this device first, then the other machines" {
  export DM_NAME=lap
  [ "$(dm_workspace_hosts | tr '\n' ' ')" = "lap pc2 " ]
  export DM_NAME=tablet
  [ "$(dm_workspace_hosts | tr '\n' ' ')" = "tablet lap pc2 " ]
}
