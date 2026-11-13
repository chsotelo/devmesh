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
  # No tmux server yet (a phone, a fresh machine) is "no clients", not an error.
  { tmux list-clients -F "#{client_pid}${DM_TMUX_SEP}#{session_name}" 2>/dev/null || true; } | dm_tmux_tsv |
    while IFS=$'\t' read -r pid session; do
      printf '%s\t%s\n' "$session" "$(dm_client_origin "$pid")"
    done
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
    # set-option does not take the "=name" exact-match form; the name was validated above.
    tmux set-option -t "$session" @origin "$from"
    tmux set-option -t "$session" @created "$(date +%s)"
  fi
  if [[ $win =~ ^[0-9]+$ ]]; then
    tmux select-window -t "=$session:$win" 2>/dev/null || true
  fi
  export DEVMESH_FROM=$from
  # -u: UTF-8 always. Over ssh the locale variables do not arrive, and without UTF-8 tmux
  # draws every accent and symbol as "_".
  exec tmux -u attach-session -t "=$session"
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
