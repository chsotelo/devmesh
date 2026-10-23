# shellcheck shell=bash
# dm app: the control panel as ONE live fzf screen, in the spirit of Grok Build's TUI.
#   - top bar: "‹ back" + clickable buttons ([new] [send] [fetch] [web] [↻])
#   - screens (home → machine → new terminal…) change in place; esc/‹ goes back
#   - the list and the selected terminal's screen refresh by themselves every few seconds
#   - bottom: input box with the status in its border, then a hint bar (also clickable)
# fzf runs "dm _app <cmd>" for every event; the screen stack lives in $DM_APP_STATE.
# Needs fzf >= 0.66 (every(), click-footer, footer); older fzf uses dm_ui_main.

readonly DM_APP_TICK=4

# fzf with every() and click-footer?
dm_app_supported() {
  command -v fzf >/dev/null || return 1
  fzf --filter x --footer x --bind 'every(5):ignore,click-footer:ignore' </dev/null >/dev/null 2>&1
  (($? != 2))
}

dm_app_cmd() { printf "'%s' '%s' _app" "$BASH" "$DM_SELF"; }

# --- screen stack -------------------------------------------------------------------
dm_app_top() { tail -n1 "$DM_APP_STATE/stack"; }
dm_app_depth() { wc -l <"$DM_APP_STATE/stack" | tr -d ' '; }
dm_app_push() { printf '%s\n' "$*" >>"$DM_APP_STATE/stack"; }
dm_app_pop() {
  sed '$d' "$DM_APP_STATE/stack" >"$DM_APP_STATE/stack.new"
  mv "$DM_APP_STATE/stack.new" "$DM_APP_STATE/stack"
}
dm_app_home() { printf 'home\n' >"$DM_APP_STATE/stack"; }

# --- what each screen shows -----------------------------------------------------------
dm_app_title() {
  local screen arg
  read -r screen arg <<<"$(dm_app_top)"
  case $screen in
    home) printf 'devmesh' ;;
    machine) printf 'devmesh › %s' "$arg" ;;
    new) printf '%s' "$M_TITLE_NEW" ;;
    new2) dm_t "$M_TITLE_NEW2" "$arg" ;;
    add) printf '%s' "$M_TITLE_ADD" ;;
    help) printf '%s' "$M_TITLE_HELP" ;;
  esac
}

dm_app_ghost() {
  case $(dm_app_top) in
    new2*) printf '%s' "$M_GHOST_NEW2" ;;
    add) printf '%s' "$M_GHOST_ADD" ;;
    *) printf '%s' "$M_GHOST_SEARCH" ;;
  esac
}

# Clickable top bar (fzf's footer: with reverse-list it is drawn at the top).
# Words in [brackets] are buttons (see dm_app_click).
dm_app_header() {
  local left="" right w plain pad d t r
  d=$(dm_c "$DM_C_DIM")
  t=$(dm_c "$DM_C_TEXT")
  r=$(dm_r)
  (($(dm_app_depth) > 1)) && left="${t}‹ $M_WORD_BACK$r"
  if dm_narrow; then
    right="${d}[$M_WORD_NEW] [$M_WORD_SEND] [$M_WORD_WEB] [↻]$r"
  else
    right="${d}[$M_WORD_NEW] [$M_WORD_SEND] [$M_WORD_FETCH] [$M_WORD_WEB] [↻]$r"
  fi
  w=$(($(dm_ui_listw) - 3))
  plain=$(printf '%s%s' "$left" "$right" | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')
  pad=$((w - ${#plain}))
  ((pad < 1)) && pad=1
  printf ' %s%*s%s\n' "$left" "$pad" "" "$right"
}

# Hint bar just above the input (fzf's header), like Grok's "Enter:send │ …".
# Words are clickable too.
dm_app_footer() {
  local k l s
  k=$(dm_c "$DM_C_TEXT")
  l=$(dm_c "$DM_C_FAINT")
  s="$l · "
  case $(dm_app_top) in
    home) printf ' %senter%s %s%s%sctrl+n%s %s%s%s?%s %s' "$k" "$l" "$M_HINT_OPEN" "$s" "$k" "$l" "$M_WORD_NEW" "$s" "$k" "$l" "$M_WORD_SHORTCUTS" ;;
    add) printf ' %senter%s %s%s%sesc%s %s' "$k" "$l" "$M_HINT_CREATE_INVITE" "$s" "$k" "$l" "$M_WORD_BACK" ;;
    new2*) printf ' %senter%s %s%s%sesc%s %s' "$k" "$l" "$M_HINT_CREATE" "$s" "$k" "$l" "$M_WORD_BACK" ;;
    *) printf ' %senter%s %s%s%sesc%s %s%s%s?%s %s' "$k" "$l" "$M_HINT_CHOOSE" "$s" "$k" "$l" "$M_WORD_BACK" "$s" "$k" "$l" "$M_WORD_SHORTCUTS" ;;
  esac
  dm_r
}

dm_app_status() {
  local screen arg
  read -r screen arg <<<"$(dm_app_top)"
  case $screen in
    home) dm_ui_status "$(cat "$DM_APP_STATE/home" 2>/dev/null)" ;;
    add) printf '%s' "$M_STATUS_ADD" ;;
    new2) printf '%s · ~/PROJECTS' "$arg" ;;
    *) printf '%s' "$DM_NAME" ;;
  esac
}

dm_app_row() { printf '%s\t%s\t-\t-\t%s\n' "$1" "$2" "$(dm_ui_line "  $(dm_c "$DM_C_TEXT")$3$(dm_r)" "${4:-}")"; }
dm_app_back_row() { printf 'back\t-\t-\t-\t%s\n' "$(dm_ui_line "  $(dm_c "$DM_C_DIM")$M_ROW_BACK$(dm_r)" "esc")"; }

dm_app_rows_machine() {
  local host=$1
  dm_app_row mgo "$host" "$M_MM_MAIN"
  dm_app_row mnew "$host" "$M_MM_NEW" "ctrl+n"
  dm_app_row msend "$host" "$M_MM_SEND" "ctrl+s"
  dm_app_row mport "$host" "$M_MM_PORT" "ctrl+o"
  printf 'noop\t-\t-\t-\t \n'
  dm_app_back_row
}

# Which machines are up comes from the last home rows (no SSH probe per machine here).
dm_app_rows_new() {
  local h color
  for h in $(dm_machines); do
    color=$(dm_host_field "$h" color)
    if ! grep -q "^offline"$'\t'"$h"$'\t' "$DM_APP_STATE/home" 2>/dev/null; then
      printf 'ok\t%s\t-\t-\t%s\n' "$h" "$(dm_ui_line "  $(dm_dot "$color") \033[1m$(dm_c "$DM_C_TEXT")$h$(dm_r)" "$M_ONLINE")"
    else
      printf 'off\t%s\t-\t-\t%s\n' "$h" "$(dm_ui_line "  $(dm_dot 244) $(dm_c "$DM_C_DIM")$h$(dm_r)" "$M_OFFLINE")"
    fi
  done
  printf 'noop\t-\t-\t-\t \n'
  dm_app_back_row
}

# Folder names come from the machine: only plain names become rows, because they end
# up inside fzf actions and shell commands on this device.
dm_app_rows_new2() {
  local host=$1 name projects
  projects=$(dm_run "$host" dm _projects 2>/dev/null) || return 1
  printf 'free\t-\t-\t-\t%s\n' "$(dm_ui_line "  $(dm_c "$DM_C_TEXT")$M_ROW_NEW_NAMED$(dm_r)" "enter")"
  while read -r name; do
    [[ $name =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$ ]] && dm_app_row proj "$name" "$name"
  done <<<"$projects"
  printf 'noop\t-\t-\t-\t \n'
  dm_app_back_row
}

dm_app_rows_down() {
  printf 'noop\t-\t-\t-\t'
  dm_t "$M_ROW_DOWN" "$(dm_c "$DM_C_WAIT")" "$1" "$(dm_r)"
  printf '\n'
  printf 'noop\t-\t-\t-\t \n'
  dm_app_back_row
}

dm_app_rows_help() {
  local key action label
  while IFS='|' read -r key action label; do
    dm_app_row back - "$label" "${key/-/+}"
  done <<<"$DM_UI_ACTIONS"
  dm_app_row back - "$M_HELP_BACK" "esc"
  dm_app_row back - "$M_HELP_SHORTCUTS" "?"
  dm_app_row back - "$M_HELP_TABS" "C-a p · C-a n"
}

dm_app_rows_home() {
  if [[ -z $(dm_machines) ]]; then
    printf 'noop\t-\t-\t-\t  %s%s%s %s%s%s\n' \
      "$(dm_c "$DM_C_TEXT")" "$M_NO_MACHINES" "$(dm_r)" "$(dm_c "$DM_C_DIM")" "$M_NO_MACHINES_ADD" "$(dm_r)"
    printf 'noop\t-\t-\t-\t \n'
    dm_ui_action_rows
  else
    dm_ui_rows
  fi
}

# _app rows [fresh] — rows of the current screen (also kept in $DM_APP_STATE/rows).
# fzf ignores keys while it waits for these, so going back home shows the last rows at
# once (the background tick refreshes them) and projects are read once per machine.
dm_app_rows() {
  local screen arg rows
  read -r screen arg <<<"$(dm_app_top)"
  case $screen in
    home)
      if [[ ${1:-} == fresh || ! -s $DM_APP_STATE/home ]]; then
        dm_app_rows_home >"$DM_APP_STATE/home"
      fi
      rows=$(cat "$DM_APP_STATE/home")
      ;;
    machine) rows=$(dm_app_rows_machine "$arg") ;;
    new) rows=$(dm_app_rows_new) ;;
    new2)
      # Cached per machine, but only when the machine answered.
      if [[ ! -s $DM_APP_STATE/new2.$arg ]] && dm_app_rows_new2 "$arg" >"$DM_APP_STATE/new2.tmp"; then
        mv "$DM_APP_STATE/new2.tmp" "$DM_APP_STATE/new2.$arg"
      fi
      rows=$(cat "$DM_APP_STATE/new2.$arg" 2>/dev/null || dm_app_rows_down "$arg")
      ;;
    add) rows=$(dm_app_row create - "$M_ROW_INVITE" "enter") ;;
    help) rows=$(dm_app_rows_help) ;;
  esac
  printf '%s\n' "$rows" | tee "$DM_APP_STATE/rows"
}

# _app tick — runs in the background every few seconds. Home is re-read and redrawn only
# when something changed; the preview (a terminal's live screen) always refreshes.
# One tick at a time: with an offline machine a tick can take longer than the interval.
dm_app_tick() {
  local rows
  if [[ $(dm_app_top) == home ]] && mkdir "$DM_APP_STATE/tick.lock" 2>/dev/null; then
    rows=$(dm_app_rows_home)
    rmdir "$DM_APP_STATE/tick.lock"
    # The user may have navigated while this was running: then drop the result.
    if [[ $(dm_app_top) == home && $rows != "$(cat "$DM_APP_STATE/home" 2>/dev/null)" ]]; then
      printf '%s\n' "$rows" >"$DM_APP_STATE/home.tmp"
      mv "$DM_APP_STATE/home.tmp" "$DM_APP_STATE/home"
      printf 'transform-input-label(%s status)+reload-sync(%s rows)+' "$(dm_app_cmd)" "$(dm_app_cmd)"
    fi
  fi
  printf 'refresh-preview'
}

# --- actions printed back to fzf ------------------------------------------------------
# Full redraw of the current screen (after navigating).
dm_app_render() {
  local c search=enable-search
  c=$(dm_app_cmd)
  [[ $(dm_app_top) == add ]] && search=disable-search
  # reload-sync goes last: fzf drops the actions chained after it.
  printf 'clear-query+%s+change-ghost(%s)+transform-footer(%s header)+transform-header(%s footer)' \
    "$search" "$(dm_app_ghost)" "$c" "$c"
  printf '+transform-list-label(%s label)+transform-input-label(%s status)+reload-sync(%s rows)' "$c" "$c" "$c"
}

dm_app_go() {
  dm_app_push "$@"
  dm_app_render
}

dm_app_back() {
  if (($(dm_app_depth) <= 1)); then
    printf 'clear-query'
    return 0
  fi
  dm_app_pop
  dm_app_render
}

dm_app_say() { printf 'change-input-label( %s%s%s )' "$(dm_c "$DM_C_WAIT")" "$1" "$(dm_r)"; }

# Run a dm command that needs the whole screen (file pickers, QR…), then come back.
dm_app_exec() { printf 'execute(%s run %s)+%s' "$(dm_app_cmd)" "$*" "$(dm_app_render)"; }

# Open a terminal: a new tab in the workspace (the panel stays here), else full screen.
dm_app_open() {
  local c
  c=$(dm_app_cmd)
  if dm_ws_available; then
    printf 'execute-silent(%s open %s)' "$c" "$*"
  else
    printf 'execute(%s open %s)' "$c" "$*"
  fi
  if [[ $(dm_app_top) != home ]]; then
    dm_app_home
    printf '+%s' "$(dm_app_render)"
  fi
}

dm_app_new() {
  local machines
  machines=$(dm_machines)
  if [[ -z $machines ]]; then
    dm_app_say "$M_SAY_NO_MACHINES"
  elif (($(wc -w <<<"$machines") == 1)); then
    dm_app_go new2 "$machines"
  else
    dm_app_go new
  fi
}

dm_app_new_named() {
  local host=$1 name=$2 spec=${3:--} session
  session=$(dm_sanitize "$name")
  if [[ -z $name ]]; then
    dm_app_say "$M_SAY_NAME_TERM"
  elif ! dm_valid_session "$session"; then
    dm_app_say "$M_SAY_INVALID_NAME"
  else
    dm_app_open "$host" "$session" - "$spec"
  fi
}

# dm_app_action ACTION — one of DM_UI_ACTIONS (row, shortcut or top-bar button).
dm_app_action() {
  case $1 in
    new) dm_app_new ;;
    add) dm_app_go add ;;
    help) dm_app_go help ;;
    quit) printf 'abort' ;;
    refresh)
      rm -f "$DM_APP_STATE"/new2.*
      printf 'execute-silent(%s run refresh)+%s' "$(dm_app_cmd)" "$(dm_app_render | sed 's/ rows)$/ rows fresh)/')"
      ;;
    send | fetch | port | devices) dm_app_exec "$1" ;;
  esac
}

# _app enter TYPE KEY SESSION WINDOW QUERY
dm_app_enter() {
  local type=$1 key=$2 session=$3 win=$4 query=${5:-} screen arg
  read -r screen arg <<<"$(dm_app_top)"
  case $type in
    term) dm_app_open "$key" "$session" "$win" - ;;
    machine) dm_app_go machine "$key" ;;
    offline) dm_app_exec wake "$key" ;;
    action) dm_app_action "$key" ;;
    mgo) dm_app_open "$key" main - - ;;
    mnew | ok) dm_app_go new2 "$key" ;;
    off) dm_app_say "$M_SAY_MACHINE_OFF" ;;
    msend) dm_app_exec send ;;
    mport) dm_app_exec port ;;
    proj) dm_app_new_named "$arg" "$key" "proj:$key" ;;
    create)
      if [[ $query =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
        dm_app_pop
        dm_app_exec add "$query"
      else
        dm_app_say "$M_SAY_NAME_RULE"
      fi
      ;;
    back) dm_app_back ;;
    noop) ;;
    *)
      # No row matched what was typed: on the project screen the text is the new name.
      if [[ $screen == new2 ]]; then
        dm_app_new_named "$arg" "$query"
      fi
      ;;
  esac
  return 0
}

# _app key KEY — ctrl shortcuts. On a machine screen they act on that machine.
dm_app_key() {
  local screen arg action
  read -r screen arg <<<"$(dm_app_top)"
  [[ $1 == '?' ]] && {
    dm_app_go help
    return 0
  }
  action=$(awk -F'|' -v k="$1" '$1 == k {print $2}' <<<"$DM_UI_ACTIONS")
  if [[ $screen == machine && $action == new ]]; then
    dm_app_go new2 "$arg"
  else
    dm_app_action "$action"
  fi
}

# dm_app_words — "word|action" for every clickable word: the words of the active catalog
# (so [new] and [nueva] reach the same action) plus the language-free symbols and keys.
dm_app_words() {
  printf '%s\n' "‹|back" "esc|back" "$M_WORD_BACK|back" \
    "ctrl+n|new" "$M_WORD_NEW|new" \
    "$M_WORD_SEND|send" "$M_WORD_FETCH|fetch" "$M_WORD_WEB|port" "$M_WORD_DEVICES|devices" \
    "↻|refresh" "?|help" "$M_WORD_SHORTCUTS|help" \
    "ctrl+q|quit" "$M_WORD_QUIT|quit"
}

# _app click WORD — top-bar buttons and hint-bar words.
dm_app_click() {
  local word=${1//[\[\]]/} action
  action=$(awk -F'|' -v w="$word" '$1 == w {print $2; exit}' < <(dm_app_words))
  case $action in
    back) dm_app_back ;;
    new) dm_app_key ctrl-n ;;
    help) dm_app_go help ;;
    quit) printf 'abort' ;;
    '') ;;
    *) dm_app_action "$action" ;;
  esac
  return 0
}

# _app run CMD… — full-screen commands started from the panel.
dm_app_run() {
  local cmd=$1
  shift
  case $cmd in
    refresh) dm_refresh >/dev/null 2>&1 || true ;;
    devices | add)
      "$DM_SELF" "$cmd" "$@" || true
      dm_ui_pause
      ;;
    *) "$DM_SELF" "$cmd" "$@" || dm_ui_pause ;;
  esac
}

dm_app_dispatch() {
  local cmd=$1
  [[ -n ${DM_APP_DEBUG:-} ]] && printf '%s\n' "$*" >>"$DM_APP_DEBUG"
  shift
  case $cmd in
    rows) dm_app_rows "$@" ;;
    tick) dm_app_tick ;;
    header) dm_app_header ;;
    footer) dm_app_footer ;;
    label) printf ' \033[1m%s%s%s ' "$(dm_c "$DM_C_TEXT")" "$(dm_app_title)" "$(dm_r)" ;;
    status) printf ' %s ' "$(dm_app_status)" ;;
    enter) dm_app_enter "$@" ;;
    key) dm_app_key "$@" ;;
    click) dm_app_click "$@" ;;
    back) dm_app_back ;;
    open) dm_ui_open "$1" "$2" "${3/#-/}" "${4:--}" ;;
    run) dm_app_run "$@" ;;
    *) dm_die "unknown app command: $cmd" ;;
  esac
}

# dm panel: the live app (or the classic loop on older fzf).
dm_app_main() {
  # The Go panel (dm-tui) when this device has a binary for it; else the fzf panel below.
  dm_tui_launch && return 0
  dm_ui_detect_cols
  if ! dm_app_supported; then
    dm_ui_main
    return
  fi
  local c keys="" k blue extra=()
  DM_APP_STATE=$(mktemp -d)
  export DM_APP_STATE
  # Closing the tab (SIGHUP) or a kill must not leave the state behind.
  trap 'rm -rf "$DM_APP_STATE"; exit 1' HUP TERM
  dm_app_home
  c=$(dm_app_cmd)
  blue="#7aa2f7"
  while IFS='|' read -r k _; do keys+="${keys:+,}$k:transform($c key $k)"; done <<<"$DM_UI_ACTIONS"
  printf '%s  %s%s\r' "$(dm_c "$DM_C_FAINT")" "$M_LOADING" "$(dm_r)" >&2
  dm_app_rows fresh >/dev/null
  [[ ${DM_TAP_ACCEPT:-0} == 1 ]] && extra+=(--bind 'left-click:accept')
  fzf --ansi --height=100% --no-sort --info=hidden --cycle --no-scrollbar --layout=reverse-list \
    --with-shell "$BASH -c" --delimiter=$'\t' --with-nth=5 --track --id-nth=1..4 \
    --prompt='❯ ' --pointer='❯' --marker=' ' --gutter=' ' --ghost="$(dm_app_ghost)" \
    --list-border=rounded --list-label="$(dm_app_dispatch label)" --list-label-pos=3 \
    --input-border=rounded --input-label="$(dm_app_dispatch status)" --input-label-pos=-3:bottom \
    --footer="$(dm_app_header)" --footer-border=none --header="$(dm_app_footer)" --header-border=none \
    --preview="'$BASH' '$DM_SELF' _preview {1} {2} {3} {4}" --preview-window="$(dm_ui_preview_window)" \
    --color="fg:#6c6c6c,fg+:#ffffff,bg+:#242424,hl:$blue,hl+:$blue,border:#333333,label:#787878" \
    --color="list-border:#333333,input-border:#505058,preview-border:#333333,list-label:#e1e1e1" \
    --color="input-label:#6c6c6c,prompt:#e1e1e1,pointer:$blue,query:#e1e1e1,ghost:#505058,info:#505058" \
    --bind "enter:transform($c enter {1} {2} {3} {4} {q})" \
    --bind "esc:transform($c back),?:transform($c key ?)" \
    --bind "$keys" \
    --bind "click-header:transform($c click \"\$FZF_CLICK_HEADER_WORD\")" \
    --bind "click-footer:transform($c click \"\$FZF_CLICK_FOOTER_WORD\")" \
    --bind "resize:transform-footer($c header)+reload-sync($c rows fresh)" \
    --bind "every($DM_APP_TICK):bg-transform($c tick)" \
    "${extra[@]}" <"$DM_APP_STATE/rows" >/dev/null || true
  rm -rf "$DM_APP_STATE"
}
