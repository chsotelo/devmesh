# shellcheck shell=bash
# Terminals across machines: list (color + global ID), enter, create on a chosen machine, close.

# dm_collect: query every machine in parallel.
# Output: host<TAB>OK<TAB><who fields...> | host<TAB>EMPTY | host<TAB>OFFLINE
dm_collect() (
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  local h
  for h in $(dm_machines); do
    (dm_run "$h" dm _who >"$tmp/$h.out" 2>/dev/null && : >"$tmp/$h.ok") &
  done
  wait
  for h in $(dm_machines); do
    if [[ ! -e $tmp/$h.ok ]]; then
      printf '%s\tOFFLINE\n' "$h"
    elif [[ ! -s $tmp/$h.out ]]; then
      printf '%s\tEMPTY\n' "$h"
    else
      awk -v h="$h" '{print h "\tOK\t" $0}' "$tmp/$h.out"
    fi
  done
)

dm_agent_label() {
  case $1 in
    working) printf '\033[33m⚙ working\033[0m' ;;
    waiting) printf '\033[31m⏳ waiting\033[0m' ;;
    idle) printf '\033[32m✓ idle\033[0m' ;;
    *) printf '' ;;
  esac
}

# dm_term_lines: picker lines "host<TAB>session<TAB>window<TAB>display".
dm_term_lines() {
  local host st session win active cmd agent origin activity clients color id
  while IFS=$'\t' read -r host st session win _ active cmd agent origin _ activity clients; do
    color=$(dm_host_field "$host" color)
    case $st in
      OFFLINE)
        printf '%s\t-\t-\t%s %s\n' "$host" "$(dm_dot 244)" "$(dm_grey "$host  OFFLINE")"
        continue
        ;;
      EMPTY)
        printf '%s\t-\t-\t%s %s\n' "$host" "$(dm_dot "$color")" "$(dm_grey "$host  (no terminals)")"
        continue
        ;;
    esac
    id="$host:$session:$win"
    [[ $active == 1 ]] && id+="*"
    if dm_narrow; then
      printf '%s\t%s\t%s\t%s %s %s %s\n' "$host" "$session" "$win" "$(dm_dot "$color")" "$id" "$cmd" \
        "$(dm_agent_label "$agent")"
    else
      printf '%s\t%s\t%s\t%s %-26s %-10s %-22s %s · %s  %s\n' "$host" "$session" "$win" "$(dm_dot "$color")" \
        "$id" "$cmd" "$(dm_agent_label "$agent")" "${origin/#-/local}" "$(dm_ago "$activity")" \
        "$([[ $clients == - ]] || printf '[%s]' "$clients")"
    fi
  done < <(dm_collect)
}

dm_terms() {
  local lines pick host session win
  dm_require_machines
  lines=$(dm_term_lines)
  [[ -n $lines ]] || dm_die "no machines enrolled"
  pick=$(dm_pick terminal --delimiter=$'\t' --with-nth=4 <<<"$lines") || return 0
  IFS=$'\t' read -r host session win _ <<<"$pick"
  if [[ $session == - ]]; then
    dm_info "$host has no terminal to enter (use: dm new)"
    return 0
  fi
  dm_tty "$host" "dm _attach $session - $DM_NAME $win"
}

# dm_who: same data as a plain table (scriptable).
dm_who() {
  dm_require_machines
  printf '%-28s %-10s %-8s %-14s %-8s %-6s %s\n' TERMINAL COMMAND AGENT FROM CREATED SEEN CLIENTS
  local host st session win cmd agent origin created activity clients
  while IFS=$'\t' read -r host st session win _ _ cmd agent origin created activity clients; do
    case $st in
      OFFLINE | EMPTY) printf '%-28s %s\n' "$host" "$st" ;;
      *) printf '%-28s %-10s %-8s %-14s %-8s %-6s %s\n' "$host:$session:$win" "$cmd" "$agent" \
        "${origin/#-/local}" "$(dm_ago "$created")" "$(dm_ago "$activity")" "$clients" ;;
    esac
  done < <(dm_collect)
}

# dm_pick_machine PROMPT — only reachable machines can be chosen.
dm_pick_machine() (
  prompt=$1
  dm_require_machines
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  local h lines="" color
  for h in $(dm_machines); do
    (dm_path "$h" >/dev/null 2>&1 && : >"$tmp/$h") &
  done
  wait
  for h in $(dm_machines); do
    color=$(dm_host_field "$h" color)
    if [[ -e $tmp/$h ]]; then
      lines+="$h"$'\t'"$(dm_dot "$color") $h"$'\n'
    else
      lines+="-"$'\t'"$(dm_dot 244) $(dm_grey "$h (offline)")"$'\n'
    fi
  done
  local pick
  pick=$(printf '%s' "$lines" | dm_pick "$prompt" --delimiter=$'\t' --with-nth=2) || exit 1
  pick=${pick%%$'\t'*}
  [[ $pick != - ]] || dm_die "that machine is offline"
  printf '%s\n' "$pick"
)

dm_go() {
  local host=${1:-} session=${2:-main}
  dm_require_machines
  [[ -n $host ]] || host=$(dm_pick_machine machine) || return 0
  dm_valid_session "$session" || dm_die "invalid session name"
  dm_tty "$host" "dm _attach $session - $DM_NAME"
}

# dm_new: always asks the machine first, then the project (R14).
dm_new() {
  local host projects pick name spec=- session answer
  dm_require_machines
  host=$(dm_pick_machine "new terminal on") || return 0
  projects=$(dm_run "$host" dm _projects 2>/dev/null || true)
  pick=$(printf '+ custom name\n%s\n' "$projects" | grep -v '^$' | dm_pick "project on $host") || return 0
  if [[ $pick == "+ custom name" ]]; then
    printf 'Terminal name: ' >&2
    read -r name
  else
    name=$pick
    [[ $name =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] && spec="proj:$name"
  fi
  session=$(dm_sanitize "$name")
  dm_valid_session "$session" || dm_die "invalid name '$name'"
  if dm_run "$host" dm _has "$session"; then
    printf '%s:%s already exists. Enter it? [Y/n] ' "$host" "$session" >&2
    read -r answer
    [[ ${answer,,} == n* ]] && return 0
  fi
  dm_tty "$host" "dm _attach $session $spec $DM_NAME"
}

dm_close() {
  local lines pick host session
  dm_require_machines
  lines=$(dm_term_lines | awk -F'\t' '$2 != "-" && !seen[$1 FS $2]++')
  [[ -n $lines ]] || dm_die "no terminals"
  pick=$(dm_pick "close terminal" --delimiter=$'\t' --with-nth=4 <<<"$lines") || return 0
  IFS=$'\t' read -r host session _ <<<"$pick"
  dm_confirm "$session" || dm_die "not confirmed"
  dm_run "$host" dm _kill "$session"
  dm_info "closed $host:$session"
}
