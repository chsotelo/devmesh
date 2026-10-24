# shellcheck shell=bash
# dm workspace: the panel and every remote terminal live in ONE screen as tabs.
#   - inside any tmux: tabs are opened in that tmux
#   - outside tmux: a private tmux server ("-L devmesh") is started for the workspace
#   - each tab reconnects by itself when the connection drops
# Without tmux at all (rare), dm falls back to opening terminals full screen.

readonly DM_WS_SOCKET=${DM_WS_SOCKET:-devmesh}

dm_ws_available() { [[ -n ${TMUX:-} ]]; }

# Ensure tmux exists on Termux (older enrollments did not install it).
dm_ws_ensure_tmux() {
  command -v tmux >/dev/null && return 0
  if [[ $(dm_platform) == termux ]]; then
    dm_info "installing tmux (one time)…"
    pkg install -y tmux >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Inside a tmux that is not the workspace, opening the panel there would nest it: the
# panel shows this machine's terminals, one of which is the one you are in, and so on.
# - the workspace itself: nothing to open
# - a terminal another device is looking at: refuse (the panel lives on that device)
# - a local terminal (machines start every terminal in tmux): hand the real window over
#   to the panel (detach-client -E); the local session keeps running
dm_ws_in_tmux() {
  local socket client origin
  socket=${TMUX%%,*}
  if [[ ${socket##*/} == "$DM_WS_SOCKET" ]]; then
    dm_info "$M_WS_ALREADY"
    return 0
  fi
  client=$(tmux display-message -p '#{client_pid}' 2>/dev/null)
  origin=local
  [[ $client =~ ^[0-9]+$ ]] && origin=$(dm_client_origin "$client")
  if [[ $origin != local ]]; then
    dm_info "$(dm_t "$M_WS_REMOTE" "$origin")"
    return 1
  fi
  exec tmux detach-client -E "'$BASH' '$DM_SELF'"
}

# The join line leaves the dm-tui binary out (several MB) and "dm update" brings it: a device
# just enrolled fetches it once here, so every device shows the same layout from the start.
dm_ws_get_tui() {
  local mark
  mark="$DM_CACHE/tui-fetched-$(dm_version)"
  [[ ${DM_UI:-layout} == layout && ${DM_TUI:-1} != 0 && ! -e $mark ]] || return 0
  dm_tui_bin >/dev/null && return 0
  touch "$mark"
  dm_info "$M_LY_GET_TUI"
  dm_update || true
}

# dm (no args): start or re-attach the workspace with the panel as its first tab.
dm_ws_start() {
  if dm_ws_available; then
    dm_ws_in_tmux
    return
  fi
  if ! dm_ws_ensure_tmux; then
    dm_app_main
    return
  fi
  # The VS Code like layout is the default; DM_UI=cards keeps the card panel, DM_UI=fzf the fzf one.
  [[ ${DM_UI:-layout} == fzf ]] && export DM_TUI=0
  dm_ws_get_tui
  if dm_ly_ready; then
    dm_ly_start || dm_die "could not start the workspace"
  fi
  local share
  share=$(dm_share_dir)
  exec tmux -u -L "$DM_WS_SOCKET" -f "$share/tmux/workspace.conf" new-session -A -s "devmesh" -n panel \
    "'$BASH' '$DM_SELF' panel"
}

# dm_ws_window_name HOST SESSION — tab title.
dm_ws_window_name() { printf '%s:%s\n' "$1" "$2"; }

# dm_ws_open HOST SESSION [WINDOW] [DIRSPEC] — focus the tab for that terminal, creating it
# (and the remote session) if needed. Returns immediately: the panel stays usable.
dm_ws_open() {
  local host=$1 session=$2 win=${3:-} spec=${4:--} name color target
  name=$(dm_ws_window_name "$host" "$session")
  target=$(tmux list-windows -F '#{window_id} #{window_name}' 2>/dev/null | awk -v n="$name" '$2 == n {print $1; exit}')
  if [[ -n $target ]]; then
    tmux select-window -t "$target"
    return 0
  fi
  color=$(dm_host_field "$host" color)
  target=$(tmux new-window -P -F '#{window_id}' -n "$name" \
    "'$BASH' '$DM_SELF' _tab '$host' '$session' '${win:--}' '$spec'")
  [[ $color =~ ^[0-9]+$ ]] && tmux set-option -w -t "$target" @dm_color "$color"
  tmux set-option -w -t "$target" automatic-rename off
}

# _tab HOST SESSION WINDOW DIRSPEC — runs inside a tab: connect, and reconnect on drops.
# A normal detach (Ctrl+b d on the remote side) closes the tab and returns to the panel.
dm_ws_tab() {
  local host=$1 session=$2 win=$3 spec=$4 rc key
  [[ $win == - ]] && win=""
  dm_valid_session "$session" || dm_die "invalid session name"
  while true; do
    rc=0
    # A subshell: an unreachable machine (dm_die) is a dropped link to retry, not the end
    # of the pane.
    (dm_tty "$host" "dm _attach $session $spec $DM_NAME $win") || rc=$?
    if ((rc == 0)); then
      tmux select-window -t :=panel 2>/dev/null || true
      return 0
    fi
    dm_t "$M_CONN_LOST" "$host"
    key=""
    read -r -s -n 1 -t 3 key || true
    [[ $key == q ]] && return 0
    spec=-
  done
}

# Open a terminal the best way available: a tab in the workspace, else full screen.
dm_ui_open() {
  local host=$1 session=$2 win=${3:-} spec=${4:--}
  if dm_ws_available; then
    dm_ws_open "$host" "$session" "$win" "$spec"
  else
    dm_tty "$host" "dm _attach $session $spec $DM_NAME $win"
  fi
}
