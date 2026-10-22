# shellcheck shell=bash
# dm UI: a full-screen, touch-friendly control panel on fzf, styled like modern agent TUIs
# (Grok Build): monochrome grays, rounded cards, the input box at the bottom with the status
# written in its border, shortcuts right-aligned. Machine colors are only small accent dots.
# Rows are "type<TAB>key<TAB>session<TAB>window<TAB>label"; only the label is shown.

# Palette (truecolor; fzf and tmux approximate it on 256-color terminals).
readonly DM_C_TEXT='225;225;225' DM_C_DIM='108;108;108' DM_C_FAINT='80;80;88'
readonly DM_C_WAIT='230;180;80' DM_C_WORK='120;170;220' DM_C_IDLE='120;190;140'

dm_c() { printf '\033[38;2;%sm' "$1"; }
dm_r() { printf '\033[0m'; }

# dm_ui_fzf_at_least VERSION — feature checks (input/list borders 0.58, ghost and gutter 0.62).
dm_ui_fzf_at_least() {
  local v
  v=$(fzf --version 2>/dev/null | awk '{print $1}')
  [[ $(printf '%s\n%s\n' "$v" "$1" | sort -V | head -n1) == "$1" ]]
}

# $(tput cols) cannot see the terminal from inside a pipe: ask the tty once and export it.
dm_ui_detect_cols() {
  local cols
  cols=$({ stty size </dev/tty 2>/dev/null || true; } | awk '{print $2}')
  [[ $cols =~ ^[0-9]+$ ]] && export COLUMNS=$cols
  return 0
}

# Inside fzf actions COLUMNS is not set: fzf exports its own size as FZF_COLUMNS.
dm_ui_cols() { printf '%s\n' "${FZF_COLUMNS:-${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}}"; }

# Width of a row inside the list card: borders, pointer and gutter take 6 columns, and the
# preview takes 55% on wide screens.
dm_ui_listw() {
  local cols
  cols=$(dm_ui_cols)
  if dm_narrow; then
    printf '%s\n' $((cols - 6))
  else
    printf '%s\n' $((cols - (cols * 55 + 99) / 100 - 6))
  fi
}

# dm_ui_line LEFT RIGHT — LEFT, then RIGHT (dim) flush to the right edge of the card.
# RIGHT is dropped when it does not fit.
dm_ui_line() {
  local left=$1 right=$2 w plain pad
  w=$(dm_ui_listw)
  plain=$(printf '%b' "$left" | sed $'s/\033\\[[0-9;]*m//g')
  pad=$((w - ${#plain} - ${#right}))
  if ((pad < 2)); then
    printf '%b' "$left"
    return 0
  fi
  printf '%b%*s%s%s%s' "$left" "$pad" "" "$(dm_c "$DM_C_DIM")" "$right" "$(dm_r)"
}

dm_ui_preview_window() {
  if dm_narrow; then
    printf 'down,45%%,border-rounded,wrap\n'
  else
    printf 'right,55%%,border-rounded,wrap\n'
  fi
}

# dm_ui_pick TITLE STATUS [fzf args...] < rows — the common look.
dm_ui_pick() {
  local title=$1 status=$2 extra=()
  shift 2
  if dm_ui_fzf_at_least 0.58; then
    extra+=(--layout=reverse-list --no-scrollbar
      --list-border=rounded --list-label=" $title " --list-label-pos=3
      --input-border=rounded --input-label=" $status " --input-label-pos=-3:bottom)
  else
    extra+=(--layout=reverse --border --header="  $title · $status")
  fi
  dm_ui_fzf_at_least 0.62 && extra+=(--gutter=' ' --ghost="$M_GHOST_SEARCH")
  [[ ${DM_TAP_ACCEPT:-0} == 1 ]] && extra+=(--bind 'left-click:accept')
  fzf --ansi --height=100% --no-sort --info=hidden --cycle \
    --delimiter=$'\t' --with-nth=5 --prompt='❯ ' --pointer='›' --marker=' ' \
    --color='fg:#6c6c6c,fg+:#ffffff,bg+:#141414,hl:#e1e1e1,hl+:#ffffff,border:#333333,label:#787878' \
    --color='list-border:#333333,input-border:#333333,preview-border:#333333,list-label:#e1e1e1' \
    --color='input-label:#6c6c6c,prompt:#e1e1e1,pointer:#e1e1e1,query:#e1e1e1,ghost:#505058,info:#505058' \
    "${extra[@]}" "$@"
}

dm_ui_state() {
  case $1 in
    working) printf '%s● %s%s' "$(dm_c "$DM_C_WORK")" "$M_STATE_WORKING" "$(dm_r)" ;;
    waiting) printf '%s● %s%s' "$(dm_c "$DM_C_WAIT")" "$M_STATE_WAITING" "$(dm_r)" ;;
    idle) printf '%s● %s%s' "$(dm_c "$DM_C_IDLE")" "$M_STATE_IDLE" "$(dm_r)" ;;
  esac
}

# Shortcuts of the main panel: "key|action|label" (also shown as rows to tap).
readonly DM_UI_ACTIONS="ctrl-n|new|$M_ACT_NEW
ctrl-s|send|$M_ACT_SEND
ctrl-t|fetch|$M_ACT_FETCH
ctrl-o|port|$M_ACT_PORT
ctrl-l|devices|$M_ACT_DEVICES
ctrl-g|add|$M_ACT_ADD
ctrl-r|refresh|$M_ACT_REFRESH
ctrl-q|quit|$M_ACT_QUIT"

dm_ui_action_rows() {
  local key action label
  while IFS='|' read -r key action label; do
    printf 'action\t%s\t-\t-\t%s\n' "$action" \
      "$(dm_ui_line "  $(dm_c "$DM_C_TEXT")$label$(dm_r)" "${key/-/+}")"
  done <<<"$DM_UI_ACTIONS"
}

# Rows for the main panel, from dm_collect.
dm_ui_rows() {
  local host st session win active cmd agent activity clients color last="" count collected
  local t d tname right
  t=$(dm_c "$DM_C_TEXT")
  d=$(dm_c "$DM_C_DIM")
  collected=$(dm_collect)
  while IFS=$'\t' read -r host st session win _ active cmd agent _ _ activity clients; do
    color=$(dm_host_field "$host" color)
    if [[ $host != "$last" ]]; then
      [[ -n $last ]] && printf 'noop\t-\t-\t-\t \n'
      case $st in
        OFFLINE)
          printf 'offline\t%s\t-\t-\t%s\n' "$host" "$(dm_ui_line "  $(dm_dot 244) $d$host$(dm_r)" "$M_OFFLINE")"
          ;;
        *)
          count=$(awk -F'\t' -v h="$host" '$1 == h && $2 == "OK"' <<<"$collected" | wc -l | tr -d ' ')
          printf 'machine\t%s\t-\t-\t%s\n' "$host" \
            "$(dm_ui_line "  $(dm_dot "$color") \033[1m$t$host$(dm_r)" "$(dm_count "$count" "$M_TERMINAL_ONE" "$M_TERMINAL_MANY")")"
          ;;
      esac
      last=$host
    fi
    [[ $st == OK ]] || continue
    tname="$session$([[ $active == 1 ]] || printf ':%s' "$win")"
    right=$(dm_ago "$activity")
    [[ $clients == - ]] || dm_narrow || right="$clients · $right"
    printf 'term\t%s\t%s\t%s\t%s\n' "$host" "$session" "$win" \
      "$(dm_ui_line "    $t$(printf '%-12.12s' "$tname")$(dm_r) $d$(printf '%-8.8s' "$cmd")$(dm_r) $(dm_ui_state "$agent")" "$right")"
  done <<<"$collected"
  printf 'noop\t-\t-\t-\t \n'
  dm_ui_action_rows
}

# _preview TYPE KEY SESSION WINDOW — the preview card.
dm_ui_preview() {
  local type=$1 host=$2 session=$3 win=$4 d t r
  d=$(dm_c "$DM_C_DIM")
  t=$(dm_c "$DM_C_TEXT")
  r=$(dm_r)
  case $type in
    term)
      printf '\033[1m%s%s:%s:%s%s  %s%s%s\n\n' "$t" "$host" "$session" "$win" "$r" "$d" "$M_PREVIEW_TERM_HINT" "$r"
      dm_run "$host" dm _capture "$session" "$win" 2>/dev/null || printf '%s%s%s\n' "$d" "$M_PREVIEW_NO_SCREEN" "$r"
      ;;
    machine | mgo | mnew | msend | mport | ok)
      printf '\033[1m%s%s%s\n\n' "$t" "$host" "$r"
      printf '%s  ip    %s%s%s\n' "$d" "$t" "$(dm_host_field "$host" ip)" "$r"
      printf '%s  lan   %s%s%s\n\n' "$d" "$t" "$(dm_host_field "$host" lan)" "$r"
      printf '%s%s%s\n' "$d" "$(dm_t "$M_PREVIEW_MACHINE_HELP")" "$r"
      ;;
    proj) printf '%s%s%s%s%s\n' "$d" "$M_PREVIEW_PROJECT" "$t" "$host" "$r" ;;
    free) printf '%s%s%s\n' "$d" "$(dm_t "$M_PREVIEW_FREE")" "$r" ;;
    create) printf '%s%s%s\n' "$d" "$(dm_t "$M_PREVIEW_CREATE")" "$r" ;;
    offline | off)
      printf '\033[1m%s%s%s  %s%s%s\n\n' "$t" "$host" "$r" "$d" "$M_PREVIEW_OFF_NOTE" "$r"
      printf '%s%s%s\n' "$d" "$(dm_t "$M_PREVIEW_OFF_HELP")" "$r"
      ;;
    action)
      printf '%s' "$d"
      case $host in
        new) dm_t "$M_DESC_NEW" ;;
        send) dm_t "$M_DESC_SEND" ;;
        fetch) dm_t "$M_DESC_FETCH" ;;
        port) dm_t "$M_DESC_PORT" ;;
        devices) dm_t "$M_DESC_DEVICES" ;;
        add) dm_t "$M_DESC_ADD" ;;
        refresh) dm_t "$M_DESC_REFRESH" ;;
        quit) dm_t "$M_DESC_QUIT" ;;
      esac
      printf '%s' "$r"
      ;;
  esac
}

dm_ui_pause() {
  printf '\n%s  %s%s ' "$(dm_c "$DM_C_FAINT")" "$M_PAUSE" "$(dm_r)" >&2
  read -r _ || true
}

# dm_ui_ask PROMPT — one line of input, in the same style.
dm_ui_ask() {
  local answer
  printf '\n  %s❯%s %s%s%s ' "$(dm_c "$DM_C_TEXT")" "$(dm_r)" "$(dm_c "$DM_C_DIM")" "$1" "$(dm_r)" >&2
  read -r answer
  printf '%s\n' "$answer"
}

# Machine card → its own small menu.
dm_ui_machine() {
  local host=$1 pick t r
  t=$(dm_c "$DM_C_TEXT")
  r=$(dm_r)
  pick=$(printf '%s\n' \
    "go"$'\t'"$host"$'\t-\t-\t'"  $t$M_MM_MAIN$r" \
    "new"$'\t'"$host"$'\t-\t-\t'"  $t$M_MM_NEW$r" \
    "send"$'\t'"$host"$'\t-\t-\t'"  $t$M_MM_SEND$r" \
    "port"$'\t'"$host"$'\t-\t-\t'"  $t$M_MM_PORT$r" \
    "back"$'\t-\t-\t-\t'"  $(dm_c "$DM_C_DIM")$M_MM_BACK$r" |
    dm_ui_pick "$host" "$M_PICK_OPTION") || return 0
  case ${pick%%$'\t'*} in
    go) dm_ui_open "$host" main ;;
    new) dm_ui_new "$host" ;;
    send) "$DM_SELF" send || dm_ui_pause ;;
    port) "$DM_SELF" port || dm_ui_pause ;;
  esac
}

# Guided "new terminal": 1) machine (if not given) 2) project or free name → open it.
dm_ui_new() {
  local host=${1:-} rows pick name spec=- session h color t r
  t=$(dm_c "$DM_C_TEXT")
  r=$(dm_r)
  dm_require_machines
  if [[ -z $host ]]; then
    rows=""
    for h in $(dm_machines); do
      color=$(dm_host_field "$h" color)
      if dm_path "$h" >/dev/null 2>&1; then
        rows+="ok"$'\t'"$h"$'\t-\t-\t'"$(dm_ui_line "  $(dm_dot "$color") \033[1m$t$h$r" "$M_ONLINE")"$'\n'
      else
        rows+="off"$'\t'"$h"$'\t-\t-\t'"$(dm_ui_line "  $(dm_dot 244) $(dm_c "$DM_C_DIM")$h$r" "$M_OFFLINE")"$'\n'
      fi
    done
    pick=$(printf '%s' "$rows" | dm_ui_pick "$M_NEW_STEP1" "$M_ASK_MACHINE") || return 0
    [[ ${pick%%$'\t'*} == ok ]] || {
      dm_info "$M_MACHINE_UNAVAILABLE"
      dm_ui_pause
      return 0
    }
    host=$(cut -f2 <<<"$pick")
  fi
  rows="free"$'\t-\t-\t-\t'"  $t$M_FREE_NAME$r"$'\n'
  while read -r name; do
    [[ -n $name ]] && rows+="proj"$'\t'"$name"$'\t-\t-\t'"$(dm_ui_line "  $t$name$r" "$M_PROJECT_TAG")"$'\n'
  done < <(dm_run "$host" dm _projects 2>/dev/null || true)
  pick=$(printf '%s' "$rows" | dm_ui_pick "$(dm_t "$M_NEW_STEP2" "$host")" "$M_ASK_PROJECT") || return 0
  if [[ ${pick%%$'\t'*} == free ]]; then
    name=$(dm_ui_ask "$M_ASK_TERM_NAME")
  else
    name=$(cut -f2 <<<"$pick")
    [[ $name =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] && spec="proj:$name"
  fi
  session=$(dm_sanitize "$name")
  dm_valid_session "$session" || {
    dm_info "$M_INVALID_NAME"
    dm_ui_pause
    return 0
  }
  dm_ui_open "$host" "$session" "" "$spec"
}

# Status for the input border: "tablet · 2 machines · 3 terminals".
dm_ui_status() {
  local machines terms
  machines=$(dm_machines | grep -c . || true)
  terms=$(grep -c '^term' <<<"$1" || true)
  dm_t "$M_STATUS_LINE" "$DM_NAME" "$(dm_count "$machines" "$M_MACHINE_ONE" "$M_MACHINE_MANY")" \
    "$(dm_count "$terms" "$M_TERMINAL_ONE" "$M_TERMINAL_MANY")"
}

# dm_ui_run_action ACTION — returns 1 for "quit".
dm_ui_run_action() {
  local self=$DM_SELF
  case $1 in
    quit) return 1 ;;
    new) dm_ui_new ;;
    refresh) dm_refresh >/dev/null 2>&1 || true ;;
    add)
      "$self" add "$(dm_ui_ask "$M_ASK_DEVICE_NAME")" || true
      dm_ui_pause
      ;;
    devices)
      "$self" devices || true
      dm_ui_pause
      ;;
    *) "$self" "$1" || dm_ui_pause ;;
  esac
}

# dm panel: loops until "Quit" (ctrl+q, or esc).
dm_ui_main() {
  local rows out key pick type keyfield session win expect="" k
  while IFS='|' read -r k _; do expect+="${expect:+,}$k"; done <<<"$DM_UI_ACTIONS"
  while true; do
    if [[ -z $(dm_machines) ]]; then
      rows="noop"$'\t-\t-\t-\t'"  $(dm_c "$DM_C_TEXT")$M_NO_MACHINES$(dm_r) $(dm_c "$DM_C_DIM")$M_NO_MACHINES_WHY$(dm_r)"$'\n'
      rows+="noop"$'\t-\t-\t-\t \n'"$(dm_ui_action_rows)"
    else
      printf '%s  %s%s\r' "$(dm_c "$DM_C_FAINT")" "$M_LOADING" "$(dm_r)" >&2
      rows=$(dm_ui_rows)
    fi
    out=$(printf '%s\n' "$rows" | dm_ui_pick "devmesh $(dm_version)" "$(dm_ui_status "$rows")" \
      --expect="$expect" --preview="'$BASH' '$DM_SELF' _preview {1} {2} {3} {4}" \
      --preview-window="$(dm_ui_preview_window)") || return 0
    key=$(head -n1 <<<"$out")
    pick=$(sed -n '2p' <<<"$out")
    if [[ -n $key ]]; then
      dm_ui_run_action "$(awk -F'|' -v k="$key" '$1 == k {print $2}' <<<"$DM_UI_ACTIONS")" || return 0
      continue
    fi
    IFS=$'\t' read -r type keyfield session win _ <<<"$pick"
    case $type in
      term) dm_ui_open "$keyfield" "$session" "$win" ;;
      machine) dm_ui_machine "$keyfield" ;;
      offline) "$DM_SELF" wake "$keyfield" || dm_ui_pause ;;
      action) dm_ui_run_action "$keyfield" || return 0 ;;
    esac
  done
}
