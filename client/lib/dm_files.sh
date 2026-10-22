# shellcheck shell=bash
# Files between devices (any tool: Claude, Codex, ...) and dev-server previews.

dm_local_inbox() {
  if [[ $(dm_platform) == termux ]]; then
    printf '%s/storage/downloads/devmesh\n' "$HOME"
  else
    printf '%s/Downloads/devmesh\n' "$HOME"
  fi
}

# Recent local files to offer (newest first).
dm_local_candidates() {
  local roots=()
  if [[ $(dm_platform) == termux ]]; then
    roots=("$HOME/storage/downloads" "$HOME/storage/dcim" "$HOME/storage/pictures" "$HOME/storage/shared/Pictures/Screenshots")
  else
    roots=("$HOME/Downloads" "$HOME/Pictures" "$HOME/Desktop")
  fi
  local existing=() r
  for r in "${roots[@]}"; do
    [[ -d $r ]] && existing+=("$r")
  done
  ((${#existing[@]})) || return 0
  # Portable (GNU, busybox, BSD find): newest first via ls -t.
  { find "${existing[@]}" -maxdepth 3 -type f -mtime -30 -exec ls -1t {} + 2>/dev/null || true; } |
    head -n 200
}

# dm_scp HOST SRC DEST — scp over path A, else path B.
dm_scp() {
  local host=$1 src=$2 dst=$3 alias
  alias=$(dm_path "$host") || dm_die "$host is unreachable"
  scp -q -o BatchMode=yes -o ConnectTimeout=6 "${src//@HOST@/$alias}" "${dst//@HOST@/$alias}"
}

dm_send() {
  local file=${1:-} host spec dest projects
  dm_require_machines
  if [[ -z $file ]]; then
    file=$(dm_local_candidates | dm_pick "file to send") || return 0
  fi
  [[ -f $file ]] || dm_die "no such file: $file"
  host=$(dm_pick_machine "send to") || return 0
  projects=$(dm_run "$host" dm _projects 2>/dev/null | sed 's/^/proj:/' || true)
  spec=$(printf 'inbox\n%s\n' "$projects" | grep -v '^$' | dm_pick "folder on $host") || return 0
  dest=$(dm_run "$host" dm _dest "$spec") || dm_die "invalid destination on $host"
  dm_scp "$host" "$file" "@HOST@:$dest/"
  printf '%s:%s/%s\n' "$host" "$dest" "${file##*/}"
}

dm_fetch() {
  local host remote local_dir
  dm_require_machines
  host=$(dm_pick_machine "fetch from") || return 0
  remote=$(dm_run "$host" dm _recent | dm_pick "file on $host (inbox/outbox)") || return 0
  [[ $remote =~ ^/[A-Za-z0-9._/@+-]+$ ]] || dm_die "unsupported path (use plain names in ~/devmesh-outbox)"
  local_dir=$(dm_local_inbox)
  mkdir -p "$local_dir"
  dm_scp "$host" "@HOST@:$remote" "$local_dir/"
  printf '%s/%s\n' "$local_dir" "${remote##*/}"
}

dm_open_url() {
  if command -v termux-open-url >/dev/null; then
    termux-open-url "$1"
  elif [[ $(dm_platform) == macos ]]; then
    open "$1"
  elif command -v xdg-open >/dev/null; then
    xdg-open "$1" >/dev/null 2>&1 &
  fi
}

# dm_port: forward a machine's dev server to this device. Works for servers bound to
# localhost too, over path A or B, so it is the one way to preview a UI.
dm_port() {
  [[ ${1:-} == stop ]] || dm_require_machines
  if [[ ${1:-} == stop ]]; then
    if pkill -f 'ssh .*-L 127\.0\.0\.1:[0-9]+:127\.0\.0\.1:'; then
      dm_info "forwards stopped"
    else
      dm_info "no forwards"
    fi
    return 0
  fi
  local host alias pick port lport
  host=$(dm_pick_machine "preview from") || return 0
  pick=$(dm_run "$host" dm _ports | dm_pick "port on $host") || return 0
  port=${pick%%$'\t'*}
  [[ $port =~ ^[0-9]+$ ]] || dm_die "invalid port"
  alias=$(dm_path "$host") || dm_die "$host is unreachable"
  for lport in "$port" $((port + 10000)); do
    ((lport < 65536)) || continue
    # Its own connection (not the shared master): the forward must outlive ControlPersist
    # and "dm port stop" must find it by its command line.
    if ssh -f -N -o ControlMaster=no -o ControlPath=none -o ExitOnForwardFailure=yes -o BatchMode=yes -L "127.0.0.1:$lport:127.0.0.1:$port" "$alias" 2>/dev/null; then
      printf 'http://localhost:%s  (%s:%s via %s; stop with: dm port stop)\n' "$lport" "$host" "$port" "$alias"
      dm_open_url "http://localhost:$lport"
      return 0
    fi
  done
  dm_die "could not forward $host:$port"
}
