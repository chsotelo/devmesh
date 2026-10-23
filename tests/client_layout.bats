#!/usr/bin/env bats
# dm layout: the VS Code like terminal panel on tmux (machine tabs, list | terminal, buttons).
# tmux is a function that logs its arguments; the real server is covered by the live check.

load helpers

setup() {
  export DM_LANG=en DM_SELF="$REPO/client/bin/dm" TMUX=fake
  setup_client
  dm_share_dir() { printf '%s\n' "$DM_SHARE"; }
  tmux() {
    printf 'tmux %s\n' "$*" >>"$STUB_LOG"
    case $* in *new-session*) echo @1 ;; esac
    case $1 in
      -V) echo "tmux ${STUB_TMUX_VERSION:-3.4}" ;;
      list-windows) printf '@1 lap\n@2 pc2\n' ;;
      list-panes) printf '%%1 side\n%%2 main\n' ;;
      display-message)
        case $* in
          *'#{@dm_host}'*) echo lap ;;
          *'#{@dm_shown}'*) echo "${STUB_SHOWN-api}" ;;
        esac
        ;;
    esac
    return 0
  }
}

@test "the layout needs tmux 3.2 or newer" {
  STUB_TMUX_VERSION=3.1 run dm_ly_tmux_ok
  [ "$status" -ne 0 ]
  STUB_TMUX_VERSION=3.2 run dm_ly_tmux_ok
  [ "$status" -eq 0 ]
  STUB_TMUX_VERSION=next-3.5 run dm_ly_tmux_ok
  [ "$status" -eq 0 ]
  STUB_TMUX_VERSION=2.9a run dm_ly_tmux_ok
  [ "$status" -ne 0 ]
}

@test "the layout is the default; DM_UI=cards, DM_UI=fzf and a missing dm-tui fall back" {
  dm_tui_bin() { echo /bin/true; }
  run dm_ly_ready
  [ "$status" -eq 0 ]
  DM_UI=cards run dm_ly_ready
  [ "$status" -ne 0 ]
  DM_UI=fzf run dm_ly_ready
  [ "$status" -ne 0 ]
  dm_tui_bin() { return 1; }
  run dm_ly_ready
  [ "$status" -ne 0 ]
  dm_tui_bin() { echo /bin/true; }
  STUB_TMUX_VERSION=3.0 run dm_ly_ready
  [ "$status" -ne 0 ]
}

@test "start: a window per machine, each with the list on the left and the terminal on the right" {
  dm_tui_bin() { echo /opt/share/bin/dm-tui-x; }
  dm_ly_tm() { printf 'tm %s\n' "$*" >>"$STUB_LOG"; case $1 in has-session) return 1 ;; new-session | new-window) echo @1 ;; display-message) echo %1 ;; split-window) echo %2 ;; esac; }
  exec() { printf 'exec %s\n' "$*" >>"$STUB_LOG"; }
  dm_ly_start
  # This device (tablet, with tmux) comes first, then every machine: 1 session + 2 windows.
  grep -q '^tmux .*new-session .* -n tablet ' "$STUB_LOG"
  grep -q '^tm set-option -w -t @1 @dm_self 1$' "$STUB_LOG"
  [ "$(grep -c '^tm new-window ' "$STUB_LOG")" = 2 ]
  grep -q '^tm new-window -d -P -F #{window_id} -t =devmesh: -n lap ' "$STUB_LOG"
  grep -q '^tm new-window -d -P -F #{window_id} -t =devmesh: -n pc2 ' "$STUB_LOG"
  grep -q "^tm split-window -d -h -b -l 24 -t %1 -P -F #{pane_id} '/opt/share/bin/dm-tui-x' sidebar --host 'tablet'\$" "$STUB_LOG"
  grep -q "sidebar --host 'lap'" "$STUB_LOG"
  grep -q "sidebar --host 'pc2'" "$STUB_LOG"
  grep -q '^tm set-option -w -t @1 @dm_color 22$' "$STUB_LOG"
  grep -q '^tm set-option -w -t @1 @dm_host lap$' "$STUB_LOG"
  grep -q '^tm set-option -p -t %2 @dm_role side$' "$STUB_LOG"
  grep -q "^tm source-file $DM_SHARE/tmux/layout.conf$" "$STUB_LOG"
  grep -q 'MouseDown1Status' "$STUB_LOG"
  grep -q '^exec tmux -u -L devmesh attach-session -t =devmesh$' "$STUB_LOG"
}

@test "start: an existing workspace is just re-attached" {
  dm_tui_bin() { echo /bin/true; }
  dm_ly_tm() { printf 'tm %s\n' "$*" >>"$STUB_LOG"; }
  exec() { printf 'exec %s\n' "$*" >>"$STUB_LOG"; }
  dm_ly_start
  ! grep -q 'new-session\|new-window' "$STUB_LOG"
  grep -q '^exec tmux -u -L devmesh attach-session' "$STUB_LOG"
}

@test "show: respawns the right pane of the machine with a quoted, validated command" {
  dm_ly_show lap api 2 focus
  grep -q '^tmux set-option -w -t @1 @dm_shown api$' "$STUB_LOG"
  grep -q "^tmux respawn-pane -k -t %2 '.*' '.*/dm' _ws run 'lap' 'api' '2'\$" "$STUB_LOG"
  grep -q '^tmux select-pane -t %2$' "$STUB_LOG"
}

@test "show: hostile machine, session or window never reach tmux" {
  for args in "lap a;b 1" 'lap $(id) 1' "L1 api 1" "lap api 1;x" "lap api -1" "lap '' 1"; do
    : >"$STUB_LOG"
    # shellcheck disable=SC2086
    run dm_ly_show $args
    [ "$status" -ne 0 ]
    ! grep -q respawn-pane "$STUB_LOG"
  done
}

@test "hold: offline marks the machine tab and replaces the terminal by a message" {
  dm_ly_hold lap offline
  grep -q '^tmux set-option -w -t @1 @dm_offline 1$' "$STUB_LOG"
  grep -q "^tmux respawn-pane -k -t %2 .*_ws idle 'offline'" "$STUB_LOG"
  : >"$STUB_LOG"
  dm_ly_hold lap empty
  grep -q '^tmux set-option -w -t @1 -u @dm_offline$' "$STUB_LOG"
  run dm_ly_hold lap "x; id"
  [ "$status" -ne 0 ]
}

@test "shown: prints the session on screen only when it is a valid name" {
  run dm_ly_shown lap
  [ "$output" = api ]
  STUB_SHOWN='a;b' run dm_ly_shown lap
  [ -z "$output" ]
}

@test "delete: confirms with the session name, then runs the kill with validated values" {
  dm_ly_delete @1
  grep -q '^tmux confirm-before -p delete terminal api? (y/n) run-shell ".*_ws kill '"'lap' 'api'"'"$' "$STUB_LOG"
  : >"$STUB_LOG"
  STUB_SHOWN='' dm_ly_delete @1
  ! grep -q confirm-before "$STUB_LOG"
  grep -q '^tmux display-message no terminal selected$' "$STUB_LOG"
  STUB_SHOWN='a;rm' dm_ly_delete @1
  ! grep -q confirm-before "$STUB_LOG"
}

@test "kill: deletes the session on the machine and asks the list to refresh" {
  dm_ly_kill lap api
  grep -q '^ssh .* lap dm _kill api$' "$STUB_LOG"
  grep -q '^tmux send-keys -t %1 r$' "$STUB_LOG"
  run dm_ly_kill lap 'a;b'
  [ "$status" -ne 0 ]
}

@test "add: the name is validated by dm and the terminal shown on its machine" {
  dm_ly_show() { printf 'show %s\n' "$*" >>"$STUB_LOG"; }
  dm_ly_add @1 <<<"My New!"
  grep -q '^show lap my-new - focus$' "$STUB_LOG"
  : >"$STUB_LOG"
  dm_ly_add @1 <<<""
  ! grep -q '^show' "$STUB_LOG"
}

@test "toggle: a narrow screen swaps the list and the terminal, a wide one hides the list" {
  dm_ly_is_narrow() { return 0; }
  dm_ly_toggle @1
  grep -q '^tmux select-pane -t %1$' "$STUB_LOG"
  grep -q '^tmux resize-pane -Z -t %1$' "$STUB_LOG"
  : >"$STUB_LOG"
  dm_ly_is_narrow() { return 1; }
  dm_ly_toggle @1
  grep -q '^tmux resize-pane -Z -t %2$' "$STUB_LOG"
}

@test "click: every status button has an action, anything else is ignored" {
  dm_ly_popup_add() { echo "popup $1"; }
  dm_ly_delete() { echo "delete $1"; }
  dm_ly_toggle() { echo "toggle $1"; }
  run dm_ly_click add @3
  [ "$output" = "popup @3" ]
  run dm_ly_click delete @3
  [ "$output" = "delete @3" ]
  run dm_ly_click menu @3
  [ "$output" = "toggle @3" ]
  dm_ly_click exit @3
  grep -q '^tmux detach-client$' "$STUB_LOG"
  run dm_ly_click add 'x;y'
  [ "$status" -ne 0 ]
}

@test "the pane command shows a message after a detach and runs the demo screen with DM_DEMO=1" {
  dm_ws_tab() { echo "tab $*"; }
  dm_ly_idle() { :; }
  run dm_ly_run lap api 2
  [[ $output == *"tab lap api 2 -"* ]]
  [[ $output == *"terminal closed"* ]]
  ssh_reply lap "dm _capture api 1" "canned screen"
  DM_DEMO=1 run dm_ly_run lap api -
  [[ $output == *"canned screen"* ]]
  run dm_ly_run lap 'a;b' 1
  [ "$status" -ne 0 ]
}

@test "_feed HOST: only that machine is asked" {
  run dm_feed lap
  [ "$status" -eq 0 ]
  ! grep -q 'pc2' "$STUB_LOG"
  grep -q 'lap dm _who' "$STUB_LOG"
  run dm_feed nope
  [ "$status" -ne 0 ]
}

@test "the layout config parses in a real tmux and defines the selector tabs and buttons" {
  real=$(PATH=${PATH#"$REPO/tests/stubs:"} command -v tmux) || skip "no real tmux"
  sock="$BATS_TEST_TMPDIR/tmux.sock"
  "$real" -S "$sock" -f /dev/null new-session -d -s t -x 100 -y 20
  run "$real" -S "$sock" source-file "$REPO/client/tmux/layout.conf"
  "$real" -S "$sock" kill-server
  [ -z "$output" ]
  for range in menu add delete exit; do grep -q "range=user|$range" "$REPO/client/tmux/layout.conf"; done
}

@test "dm inside the workspace itself opens nothing" {
  TMUX=/tmp/tmux-501/devmesh,1,0 run dm_ws_start
  [ "$status" -eq 0 ]
  [[ $output == *"already the devmesh panel"* ]]
  ! grep -q "detach-client" "$STUB_LOG"
}

@test "dm inside a terminal another device is watching refuses to nest a panel" {
  dm_client_origin() { echo tablet; }
  tmux() {
    printf 'tmux %s\n' "$*" >>"$STUB_LOG"
    [[ $1 == display-message ]] && echo 4242
    return 0
  }
  TMUX=/tmp/tmux-501/default,1,0 run dm_ws_start
  [ "$status" -ne 0 ]
  [[ $output == *"from tablet"* ]]
  ! grep -q "detach-client" "$STUB_LOG"
}

@test "dm inside a local tmux hands the window over instead of nesting" {
  dm_client_origin() { echo local; }
  tmux() {
    printf 'tmux %s\n' "$*" >>"$STUB_LOG"
    [[ $1 == display-message ]] && echo 4242
    return 0
  }
  TMUX=/tmp/tmux-501/default,1,0 run dm_ws_start
  grep -q "tmux detach-client -E" "$STUB_LOG"
}

@test "a workspace left by an older dm is replaced by the layout, a current one is kept" {
  dm_tui_bin() { echo /bin/true; }
  tmux() {
    printf 'tmux %s\n' "$*" >>"$STUB_LOG"
    case $* in
      *has-session*) [[ ! -e $BATS_TEST_TMPDIR/killed ]] ;;
      *show-options*) echo "${STUB_LAYOUT-}" ;;
      *kill-server*) : >"$BATS_TEST_TMPDIR/killed" ;;
      *new-session* | *new-window* | *split-window*) echo @1 ;;
      *display-message*) echo %1 ;;
    esac
  }
  run dm_ly_start
  grep -q "kill-server" "$STUB_LOG"
  grep -q "set-option -t devmesh @dm_layout layout-$(dm_version)" "$STUB_LOG"
  : >"$STUB_LOG"
  rm -f "$BATS_TEST_TMPDIR/killed"
  STUB_LAYOUT="layout-$(dm_version)" run dm_ly_start
  ! grep -q "kill-server" "$STUB_LOG"
}
