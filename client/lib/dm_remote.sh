# shellcheck shell=bash
# Machine-side helpers, invoked over SSH as "dm _<cmd>" by other devices.

# Who is attached: the attaching device exports DEVMESH_FROM; local terminals have none.
dm_client_origin() {
  local pid=$1 from="" proc=${DM_PROC:-/proc}
  if [[ -r $proc/$pid/environ ]]; then
    from=$(tr '\0' '\n' <"$proc/$pid/environ" | awk -F= '$1 == "DEVMESH_FROM" {print $2; exit}')
  elif [[ $(uname -s) == Darwin ]]; then
    # macOS has no /proc: ps shows the environment of the user's own processes.
    from=$(ps eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' | awk -F= '$1 == "DEVMESH_FROM" {print $2; exit}')
  fi
  [[ $from =~ ^[a-z][a-z0-9-]{0,15}$ ]] || from=local
  printf '%s\n' "$from"
}

# tmux replaces control characters (TAB included) with "_" in -F output when the locale
# is not UTF-8, which is the case over ssh. Use a printable separator, then convert.
readonly DM_TMUX_SEP='|~|'
dm_tmux_tsv() { awk -v sep="$DM_TMUX_SEP" '{gsub(/\|~\|/, "\t"); print}'; }

# "session<TAB>origin" for every attached client.
dm_session_clients() {
  local pid session
  tmux list-clients -F "#{client_pid}${DM_TMUX_SEP}#{session_name}" 2>/dev/null | dm_tmux_tsv |
    while IFS=$'\t' read -r pid session; do
      printf '%s\t%s\n' "$session" "$(dm_client_origin "$pid")"
    done
}

# _who: one TSV line per window:
# session win_index win_name win_active command agent origin created activity clients
dm_remote_who() {
  local fmt clients t=$DM_TMUX_SEP
  clients=$(dm_session_clients)
  fmt="#{session_name}${t}#{window_index}${t}#{window_name}${t}#{window_active}${t}#{pane_current_command}"
  fmt+="${t}#{@agent}${t}#{@origin}${t}#{@created}${t}#{window_activity}"
  tmux list-windows -a -F "$fmt" 2>/dev/null | dm_tmux_tsv |
    DM_CLIENTS=$clients awk -F'\t' -v OFS='\t' '
      BEGIN {
        n = split(ENVIRON["DM_CLIENTS"], rows, "\n")
        for (i = 1; i <= n; i++) {
          if (split(rows[i], f, "\t") < 2) continue
          # Test membership before assigning: mawk creates att[k] as soon as it is the target.
          prev = (f[1] in att) ? att[f[1]] "," : ""
          att[f[1]] = prev f[2]
        }
      }
      {
        for (i = 6; i <= 8; i++) if ($i == "") $i = "-"
        print $1, $2, $3, $4, $5, $6, $7, $8, $9, (($1 in att) ? att[$1] : "-")
      }'
}

# _clients SESSION: comma list of attached origins (tmux status bar).
dm_remote_clients() {
  dm_session_clients | awk -F'\t' -v s="$1" '$1 == s {o = o (o ? "," : "") $2} END {print o}'
}

# Portable (GNU, BSD/macOS, busybox): no find -printf.
dm_remote_projects() {
  [[ -d $DM_PROJECTS_DIR ]] || return 0
  local d
  for d in "$DM_PROJECTS_DIR"/*/; do
    [[ -d $d ]] || continue
    d=${d%/}
    printf '%s\n' "${d##*/}"
  done | sort
}

# _attach SESSION DIRSPEC FROM [WINDOW]: create (with trace metadata) or attach.
# DIRSPEC: "proj:<name>" -> $DM_PROJECTS_DIR/<name>; "-" -> $HOME.
dm_remote_attach() {
  local session=$1 spec=$2 from=$3 win=${4:-} dir=$HOME
  dm_valid_session "$session" || dm_die "invalid session name"
  [[ $from =~ ^[a-z][a-z0-9-]{0,15}$ ]] || from=local
  if [[ $spec == proj:* && ${spec#proj:} =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && -d $DM_PROJECTS_DIR/${spec#proj:} ]]; then
    dir=$DM_PROJECTS_DIR/${spec#proj:}
  fi
  if ! tmux has-session -t "=$session" 2>/dev/null; then
    tmux new-session -d -s "$session" -c "$dir"
    tmux set-option -t "=$session" @origin "$from"
    tmux set-option -t "=$session" @created "$(date +%s)"
  fi
  if [[ $win =~ ^[0-9]+$ ]]; then
    tmux select-window -t "=$session:$win" 2>/dev/null || true
  fi
  export DEVMESH_FROM=$from
  exec tmux attach-session -t "=$session"
}

# _dest SPEC: absolute upload folder ("inbox" or "proj:<name>"), created if needed.
dm_remote_dest() {
  local spec=$1 dir
  case $spec in
    inbox) dir=$HOME/devmesh-inbox ;;
    proj:*)
      [[ ${spec#proj:} =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || dm_die "invalid project"
      dir=$DM_PROJECTS_DIR/${spec#proj:}
      [[ -d $dir ]] || dm_die "no such project"
      ;;
    *) dm_die "invalid destination" ;;
  esac
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# _capture SESSION WINDOW: the current screen of a terminal (colors kept), for previews.
dm_remote_capture() {
  dm_valid_session "$1" || dm_die "invalid session name"
  [[ $2 =~ ^[0-9]+$ ]] || dm_die "invalid window"
  LC_ALL=${LC_ALL:-en_US.UTF-8} tmux capture-pane -p -e -J -t "=$1:$2" 2>/dev/null |
    awk '{lines[NR] = $0} END {while (NR > 0 && lines[NR] ~ /^[[:space:]]*$/) NR--; for (i = (NR > 40 ? NR - 39 : 1); i <= NR; i++) print lines[i]}'
}

dm_remote_kill() {
  dm_valid_session "$1" || dm_die "invalid session name"
  tmux kill-session -t "=$1"
}

dm_remote_has() { tmux has-session -t "=$1" 2>/dev/null; }

# _ports: listening TCP ports on this machine (excluding sshd), "port<TAB>process".
dm_remote_ports() {
  if ! command -v ss >/dev/null; then
    # macOS: lsof lists this user's listening sockets ("name port").
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {n = split($9, a, ":"); p = a[n]; if (p != 22 && p != 2223 && !(p in s)) {s[p] = 1; print p "\t" $1}}' | sort -n
    return 0
  fi
  ss -Hltnp 2>/dev/null | awk '
    {
      n = split($4, a, ":"); port = a[n]
      proc = "-"
      if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
      if (port != 22 && !(port in seen)) { seen[port] = 1; print port "\t" proc }
    }' | sort -n
}

# _recent: files in the devmesh inbox/outbox, newest first.
dm_remote_recent() {
  mkdir -p "$HOME/devmesh-outbox" "$HOME/devmesh-inbox"
  # Portable newest-first listing (GNU and BSD find).
  { find "$HOME/devmesh-outbox" "$HOME/devmesh-inbox" -maxdepth 2 -type f -exec ls -1t {} + 2>/dev/null || true; } |
    head -n 100
}

# _wol MAC: magic packet broadcast from this machine's LAN.
dm_remote_wol() {
  [[ $1 =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || dm_die "invalid MAC"
  python3 - "$1" <<'PY'
import socket, sys
mac = bytes.fromhex(sys.argv[1].replace(":", ""))
packet = b"\xff" * 6 + mac * 16
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.sendto(packet, ("255.255.255.255", 9))
PY
}

# agent <working|waiting|idle|clear>: called by tool hooks (Claude Code, Codex, ...).
dm_agent() {
  local state=${1:-}
  [[ -n ${TMUX_PANE:-} ]] || return 0
  case $state in
    working | waiting | idle)
      tmux set-option -p -t "$TMUX_PANE" @agent "$state"
      tmux set-option -p -t "$TMUX_PANE" @agent_since "$(date +%s)"
      ;;
    clear)
      tmux set-option -p -u -t "$TMUX_PANE" @agent
      tmux set-option -p -u -t "$TMUX_PANE" @agent_since
      ;;
    *) dm_die "usage: dm agent working|waiting|idle|clear" ;;
  esac
}

# One pane title, safe for a TSV line and a notification: no control characters, max 80.
dm_watch_clean() {
  local t
  t=$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]')
  printf '%s' "${t:0:80}"
}

# _watch: long-running; one TSV line per agent state change in any pane:
# session window pane_id state since title. Ends when the reader closes the pipe.
dm_remote_watch() {
  local -A prev=()
  local i=0 max=${DM_WATCH_ITERATIONS:-0} t=$DM_TMUX_SEP
  local session window pane state since title key
  while :; do
    while IFS=$'\t' read -r session window pane state since title; do
      [[ -n $state && $state != - ]] || continue
      [[ $since =~ ^[0-9]+$ ]] || since=0
      key="$state $since"
      [[ ${prev[$pane]:-} == "$key" ]] && continue
      prev[$pane]=$key
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$session" "$window" "$pane" "$state" "$since" \
        "$(dm_watch_clean "$title")" || exit 0
    done < <(tmux list-panes -a -F "#{session_name}${t}#{window_index}${t}#{pane_id}${t}#{@agent}${t}#{@agent_since}${t}#{pane_title}" 2>/dev/null | dm_tmux_tsv | awk -F'\t' -v OFS='\t' '{for (i = 1; i <= 5; i++) if ($i == "") $i = "-"; print}')
    i=$((i + 1))
    ((max > 0 && i >= max)) && return 0
    sleep "${DM_WATCH_INTERVAL:-1}"
  done
}

# _key PANE SINCE KEY: answer a waiting prompt, only if it is still the one that was notified.
dm_remote_key() {
  local pane=${1:-} since=${2:-} key=${3:-} cur
  if ! [[ $pane =~ ^%[0-9]+$ && $since =~ ^[0-9]+$ ]]; then
    printf 'usage: dm _key %%<pane> <since> 1|2|3|Escape|Enter\n' >&2
    exit 2
  fi
  case $key in
    1 | 2 | 3 | Escape | Enter) ;;
    *)
      printf 'key not allowed\n' >&2
      exit 2
      ;;
  esac
  cur=$(tmux display-message -p -t "$pane" "#{@agent}${DM_TMUX_SEP}#{@agent_since}" 2>/dev/null | dm_tmux_tsv) || cur=""
  if [[ $cur != "waiting"$'\t'"$since" ]]; then
    printf 'stale\n'
    exit 3
  fi
  tmux send-keys -t "$pane" "$key"
  printf 'sent\n'
}
