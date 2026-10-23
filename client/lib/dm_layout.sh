# shellcheck shell=bash
# dm layout: the terminal panel of VS Code, on tmux.
#   - one tmux window per machine; the status bar is the machine selector (tabs)
#   - each window has two panes: LEFT the list of that machine's terminals (dm-tui sidebar),
#     RIGHT the real interactive remote terminal of the selected one
#   - status buttons: + new terminal, trash delete the selected one, x leave (all keeps running)
# Everything that touches a machine goes through the validated "dm" commands below
# ("dm _ws <sub>"); the sidebar only draws. Values reaching a tmux command string are
# validated first (machine name, session name, digits) and only then single quoted.

readonly DM_LY_SIDE_COLS=24
readonly DM_LY_NARROW_COLS=70
readonly DM_LY_SETTLE=0.4
readonly DM_LY_HOST_RE='^[a-z][a-z0-9-]{0,15}$'

# tmux >= 3.2 (status ranges and popups) and a dm-tui binary: else the fzf panel is used.
dm_ly_tmux_ok() {
  local v
  v=$(tmux -V 2>/dev/null) || return 1
  [[ $v =~ ([0-9]+)\.([0-9]+) ]] || return 1
  ((BASH_REMATCH[1] > 3 || (BASH_REMATCH[1] == 3 && BASH_REMATCH[2] >= 2)))
}

dm_ly_ready() {
  [[ ${DM_UI:-layout} == layout ]] || return 1
  dm_ly_tmux_ok || return 1
  dm_tui_bin >/dev/null || return 1
  [[ -n $(dm_workspace_hosts) ]]
}

dm_ly_need_tmux() { [[ -n ${TMUX:-} ]] || dm_die "this runs inside the devmesh workspace"; }

dm_ly_check_host() { [[ ${1:-} =~ $DM_LY_HOST_RE ]] || dm_die "invalid machine"; }

dm_ly_check_wid() { [[ ${1:-} =~ ^@[0-9]+$ ]] || dm_die "invalid window"; }

# The window of a machine.
dm_ly_win_of_host() {
  tmux list-windows -F '#{window_id} #{@dm_host}' | awk -v h="$1" '$2 == h {print $1; exit}'
}

# The pane with a role (main = terminal, side = list) in a window.
dm_ly_pane() {
  tmux list-panes -t "$1" -F '#{pane_id} #{@dm_role}' | awk -v r="$2" '$2 == r {print $1; exit}'
}

dm_ly_host_of() { tmux display-message -p -t "$1" '#{@dm_host}'; }

dm_ly_is_narrow() {
  local w
  w=$(tmux display-message -p '#{client_width}' 2>/dev/null)
  [[ $w =~ ^[0-9]+$ && $w -gt 0 ]] || w=$(tmux display-message -p -t "${1:-}" '#{window_width}')
  [[ $w =~ ^[0-9]+$ ]] && ((w < DM_LY_NARROW_COLS))
}

# --- what runs inside the right pane ----------------------------------------------------
dm_ly_idle() {
  while true; do read -r -s -n 1 -t 3600 _ || true; done
}

# _ws idle KIND: a message instead of a terminal.
dm_ly_hold_screen() {
  local msg
  case ${1:-} in
    empty) msg=$M_LY_EMPTY ;;
    offline) msg=$M_LY_OFFLINE ;;
    loading) msg=$M_LY_LOADING ;;
    *) msg=$M_LY_DETACHED ;;
  esac
  printf '\033[2J\033[H\n\n  \033[38;5;240m%s\033[0m\n' "$msg"
  dm_ly_idle
}

# Demo hook (DM_DEMO=1): the canned screen of the terminal instead of a live connection.
dm_ly_demo() {
  local win=${3/#-/1}
  printf '\033[2J\033[H'
  dm_run "$1" dm _capture "$2" "$win" 2>/dev/null || true
  dm_ly_idle
}

# _ws run HOST SESSION WINDOW: the live remote terminal (reconnects by itself).
dm_ly_run() {
  local host=${1:-} session=${2:-} win=${3:--}
  dm_ly_check_host "$host"
  dm_valid_session "$session" || dm_die "invalid session name"
  [[ $win == - || $win =~ ^[0-9]{1,5}$ ]] || dm_die "invalid window"
  if [[ ${DM_DEMO:-0} == 1 ]]; then
    dm_ly_demo "$host" "$session" "$win"
  else
    dm_ws_tab "$host" "$session" "$win" -
  fi
  dm_ly_hold_screen detached
}

# --- actions on the right pane ------------------------------------------------------------
# On a narrow screen the terminal fills the window; the list comes back with the menu button.
dm_ly_focus_main() {
  local wid=$1 pane=$2
  tmux select-pane -t "$pane"
  if dm_ly_is_narrow "$wid" && [[ $(tmux display-message -p -t "$wid" '#{window_zoomed_flag}') != 1 ]]; then
    tmux resize-pane -Z -t "$pane"
  fi
}

# _ws show HOST SESSION [WINDOW] [focus]: put that terminal in the right pane.
dm_ly_show() {
  local host=${1:-} session=${2:-} win=${3:--} focus=${4:-} wid pane
  dm_ly_need_tmux
  dm_ly_check_host "$host"
  dm_valid_session "$session" || dm_die "invalid session name"
  [[ $win == - || $win =~ ^[0-9]{1,5}$ ]] || dm_die "invalid window"
  wid=$(dm_ly_win_of_host "$host")
  pane=$(dm_ly_pane "$wid" main)
  [[ $wid =~ ^@[0-9]+$ && $pane =~ ^%[0-9]+$ ]] || dm_die "no workspace window for $host"
  tmux set-option -w -t "$wid" -u @dm_offline
  tmux set-option -w -t "$wid" @dm_shown "$session"
  tmux respawn-pane -k -t "$pane" "'$BASH' '$DM_SELF' _ws run '$host' '$session' '$win'"
  [[ $focus == focus ]] && dm_ly_focus_main "$wid" "$pane"
  return 0
}

# _ws hold HOST empty|offline: a message in the right pane (nothing is selected).
dm_ly_hold() {
  local host=${1:-} kind=${2:-} wid pane
  dm_ly_need_tmux
  dm_ly_check_host "$host"
  [[ $kind == empty || $kind == offline ]] || dm_die "invalid kind"
  wid=$(dm_ly_win_of_host "$host")
  pane=$(dm_ly_pane "$wid" main)
  [[ $wid =~ ^@[0-9]+$ && $pane =~ ^%[0-9]+$ ]] || dm_die "no workspace window for $host"
  tmux set-option -w -t "$wid" -u @dm_shown
  if [[ $kind == offline ]]; then
    tmux set-option -w -t "$wid" @dm_offline 1
  else
    tmux set-option -w -t "$wid" -u @dm_offline
  fi
  tmux respawn-pane -k -t "$pane" "'$BASH' '$DM_SELF' _ws idle '$kind'"
}

# _ws shown HOST: the session in the right pane ("" when none).
dm_ly_shown() {
  local host=${1:-} wid session
  dm_ly_need_tmux
  dm_ly_check_host "$host"
  wid=$(dm_ly_win_of_host "$host")
  [[ $wid =~ ^@[0-9]+$ ]] || return 0
  session=$(tmux display-message -p -t "$wid" '#{@dm_shown}')
  dm_valid_session "$session" && printf '%s\n' "$session"
  return 0
}

# --- the buttons ------------------------------------------------------------------------------
# _ws add WID: runs in a popup. The name is read here, never pasted into a tmux command.
dm_ly_add() {
  local wid=${1:-} host name session
  dm_ly_check_wid "$wid"
  host=$(dm_ly_host_of "$wid")
  dm_ly_check_host "$host"
  printf '\n  \033[38;5;244m%s\033[0m\n\n' "$M_LY_NAME_HINT"
  read -r -e -p "  $M_LY_NAME_PROMPT" name || return 0
  [[ -n $name ]] || return 0
  if ! session=$(dm_feed_new --check "$host" "$name"); then
    sleep 2
    return 0
  fi
  dm_ly_show "$host" "$session" - focus
}

# Ask before deleting the terminal that is on screen.
dm_ly_delete() {
  local wid=${1:-} host session prompt
  dm_ly_check_wid "$wid"
  host=$(dm_ly_host_of "$wid")
  dm_ly_check_host "$host"
  session=$(tmux display-message -p -t "$wid" '#{@dm_shown}')
  if ! dm_valid_session "$session"; then
    tmux display-message "$M_LY_NO_TERMINAL"
    return 0
  fi
  prompt=$(dm_t "$M_LY_DELETE_PROMPT" "$session")
  tmux confirm-before -p "$prompt" \
    "run-shell \"'$BASH' '$DM_SELF' _ws kill '$host' '$session'\""
}

# _ws kill HOST SESSION: the confirmed delete. The sidebar then shows the next terminal.
dm_ly_kill() {
  local host=${1:-} session=${2:-} wid side
  dm_ly_need_tmux
  dm_ly_check_host "$host"
  dm_valid_session "$session" || dm_die "invalid session name"
  dm_run "$host" dm _kill "$session" || tmux display-message "$host: $session not deleted"
  wid=$(dm_ly_win_of_host "$host")
  [[ $wid =~ ^@[0-9]+$ ]] || return 0
  dm_ly_hold "$host" empty
  side=$(dm_ly_pane "$wid" side)
  [[ $side =~ ^%[0-9]+$ ]] && tmux send-keys -t "$side" r
  return 0
}

# Show the list (narrow screens) or hide it (wide ones).
dm_ly_toggle() {
  local wid=${1:-} main side zoomed active
  dm_ly_check_wid "$wid"
  main=$(dm_ly_pane "$wid" main)
  side=$(dm_ly_pane "$wid" side)
  [[ $main =~ ^%[0-9]+$ && $side =~ ^%[0-9]+$ ]] || return 0
  zoomed=$(tmux display-message -p -t "$wid" '#{window_zoomed_flag}')
  active=$(tmux display-message -p -t "$wid" '#{pane_id}')
  if dm_ly_is_narrow "$wid"; then
    if [[ $zoomed == 1 && $active == "$side" ]]; then
      dm_ly_focus_main "$wid" "$main"
    else
      tmux select-pane -t "$side"
      [[ $(tmux display-message -p -t "$wid" '#{window_zoomed_flag}') == 1 ]] || tmux resize-pane -Z -t "$side"
    fi
  else
    tmux resize-pane -Z -t "$main"
  fi
}

# The name prompt as a popup, as wide as the screen allows.
dm_ly_popup_add() {
  local cols width=64
  cols=$(tmux display-message -p '#{client_width}' 2>/dev/null)
  [[ $cols =~ ^[0-9]+$ ]] && ((cols - 2 < width)) && width=$((cols - 2))
  tmux display-popup -E -w "$width" -h 6 "'$BASH' '$DM_SELF' _ws add '$1'"
}

# _ws click RANGE WID: a status button.
dm_ly_click() {
  local what=${1:-} wid=${2:-}
  dm_ly_need_tmux
  dm_ly_check_wid "$wid"
  case $what in
    add) dm_ly_popup_add "$wid" ;;
    delete) dm_ly_delete "$wid" ;;
    exit) tmux detach-client ;;
    menu) dm_ly_toggle "$wid" ;;
  esac
}

# _ws layout: keep the list at its width, and the terminal alone on narrow screens.
# Runs from the client-resized / client-attached / after-select-window hooks, which fire
# together: zooming toggles, so only one run may apply the layout.
dm_ly_layout() {
  local lock=$DM_CACHE/layout.lock
  dm_ly_need_tmux
  find "$DM_CACHE" -maxdepth 1 -name layout.lock -mmin +1 -exec rmdir {} + 2>/dev/null || true
  mkdir "$lock" 2>/dev/null || return 0
  sleep "$DM_LY_SETTLE" # tmux resizes the windows after it runs the hooks: let it finish
  dm_ly_layout_apply || true
  rmdir "$lock"
}

dm_ly_layout_apply() {
  local wid side main narrow=0
  dm_ly_is_narrow && narrow=1
  for wid in $(tmux list-windows -F '#{window_id}'); do
    side=$(dm_ly_pane "$wid" side)
    main=$(dm_ly_pane "$wid" main)
    [[ $side =~ ^%[0-9]+$ && $main =~ ^%[0-9]+$ ]] || continue
    if ((narrow)); then
      dm_ly_apply_narrow "$wid" "$main"
    else
      dm_ly_apply_wide "$wid" "$main" "$side"
    fi
  done
  return 0
}

dm_ly_zoomed() { [[ $(tmux display-message -p -t "$1" '#{window_zoomed_flag}') == 1 ]]; }

dm_ly_apply_narrow() {
  dm_ly_zoomed "$1" && return 0
  tmux select-pane -t "$2"
  tmux resize-pane -Z -t "$2"
  tmux set-option -w -t "$1" @dm_auto_zoom 1
}

dm_ly_apply_wide() {
  if [[ $(tmux display-message -p -t "$1" '#{@dm_auto_zoom}') == 1 ]]; then
    tmux set-option -w -t "$1" -u @dm_auto_zoom
    dm_ly_zoomed "$1" && tmux resize-pane -Z -t "$2"
  fi
  dm_ly_zoomed "$1" || tmux resize-pane -t "$3" -x "$DM_LY_SIDE_COLS"
  return 0
}

# _ws <sub> ...: the commands the layout runs on itself (panes, buttons, hooks).
dm_ly_dispatch() {
  local sub=${1:-}
  shift || true
  case $sub in
    run) dm_ly_run "$@" ;;
    idle) dm_ly_hold_screen "$@" ;;
    show) dm_ly_show "$@" ;;
    hold) dm_ly_hold "$@" ;;
    shown) dm_ly_shown "$@" ;;
    add) dm_ly_add "$@" ;;
    kill) dm_ly_kill "$@" ;;
    click) dm_ly_click "$@" ;;
    layout) dm_ly_layout ;;
    *) dm_die "unknown workspace command: $sub" ;;
  esac
}

# --- start --------------------------------------------------------------------------------------
# Buttons, keys and hooks. Values come from this script (paths) or from tmux formats.
dm_ly_tm() { tmux -L "$DM_WS_SOCKET" "$@"; }

dm_ly_bind() {
  local base="'$BASH' '$DM_SELF' _ws"
  # Button labels in the user's language (the status bar reads them as options).
  dm_ly_tm set-option -g @dm_b_new "$M_LY_BTN_NEW"
  dm_ly_tm set-option -g @dm_b_delete "$M_LY_BTN_DELETE"
  dm_ly_tm set-option -g @dm_b_exit "$M_LY_BTN_EXIT"
  dm_ly_tm set-option -g @dm_b_list "$M_LY_BTN_LIST"
  dm_ly_tm bind-key -n MouseDown1Status if-shell -F '#{==:#{mouse_status_range},window}' \
    'select-window -t=' "run-shell \"$base click '#{mouse_status_range}' '#{window_id}'\""
  dm_ly_tm bind-key + run-shell "$base click add '#{window_id}'"
  dm_ly_tm bind-key x run-shell "$base click delete '#{window_id}'"
  dm_ly_tm bind-key s run-shell "$base click menu '#{window_id}'"
  dm_ly_tm set-hook -g client-resized "run-shell -b \"$base layout\""
  dm_ly_tm set-hook -g client-attached "run-shell -b \"$base layout\""
  dm_ly_tm set-hook -g after-select-window "run-shell -b \"$base layout\""
}

# dm_ly_build_window HOST FIRST(0|1) BIN: one window of the workspace: list | terminal.
dm_ly_build_window() {
  local m=$1 first=$2 bin=$3 wid main side color right share
  share=$(dm_share_dir)
  right="'$BASH' '$DM_SELF' _ws idle loading"
  if ((first)); then
    wid=$(tmux -L "$DM_WS_SOCKET" -f "$share/tmux/workspace.conf" new-session -d -P -F '#{window_id}' \
      -s devmesh -n "$m" -x 160 -y 45 "$right") || return 1
  else
    wid=$(dm_ly_tm new-window -d -P -F '#{window_id}' -t =devmesh: -n "$m" "$right")
  fi
  color=$(dm_host_field "$m" color)
  [[ $color =~ ^[0-9]+$ ]] && dm_ly_tm set-option -w -t "$wid" @dm_color "$color"
  dm_ly_tm set-option -w -t "$wid" @dm_host "$m"
  dm_is_self "$m" && dm_ly_tm set-option -w -t "$wid" @dm_self 1
  dm_ly_tm set-option -w -t "$wid" automatic-rename off
  main=$(dm_ly_tm display-message -p -t "$wid" '#{pane_id}')
  dm_ly_tm set-option -p -t "$main" @dm_role main
  side=$(dm_ly_tm split-window -d -h -b -l "$DM_LY_SIDE_COLS" -t "$main" -P -F '#{pane_id}' \
    "'$bin' sidebar --host '$m'")
  dm_ly_tm set-option -p -t "$side" @dm_role side
}

# dm_ly_start: re-attach the workspace, or build it: a window per machine.
dm_ly_start() {
  local bin m first=1
  bin=$(dm_tui_bin) || return 1
  # A workspace built by another dm version (older layout, card panel, or processes still
  # running old code) is rebuilt. It only holds views; the terminals live on the machines.
  local stamp
  stamp="layout-$(dm_version)"
  if dm_ly_tm has-session -t =devmesh 2>/dev/null &&
    [[ $(dm_ly_tm show-options -qv -t devmesh @dm_layout 2>/dev/null) != "$stamp" ]]; then
    dm_ly_tm kill-server 2>/dev/null || true
  fi
  if ! dm_ly_tm has-session -t =devmesh 2>/dev/null; then
    for m in $(dm_workspace_hosts); do
      [[ $m =~ $DM_LY_HOST_RE ]] || continue
      dm_ly_build_window "$m" "$first" "$bin" || return 1
      first=0
    done
    ((first)) && return 1
    dm_ly_tm source-file "$(dm_share_dir)/tmux/layout.conf"
    dm_ly_bind
    dm_ly_tm set-option -t devmesh @dm_layout "$stamp"
  fi
  # -u: UTF-8 always. Over ssh the locale variables do not arrive, and without UTF-8 tmux
  # draws every accent and symbol as "_".
  exec tmux -u -L "$DM_WS_SOCKET" attach-session -t =devmesh
}
