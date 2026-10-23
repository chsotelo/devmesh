# shellcheck shell=bash
# dm watch: notify when a terminal on any machine waits for you; approve from the phone.

dm_watch_dir() { dirname "$(dm_conf_file)"; }
dm_watch_pidfile() { printf '%s/watch.pid\n' "$(dm_watch_dir)"; }
dm_watch_plist() { printf '%s/Library/LaunchAgents/net.devmesh.watch.plist\n' "$HOME"; }
dm_valid_machine() { [[ ${1:-} =~ ^[a-z][a-z0-9-]{0,15}$ ]]; }

# The dm binary the notification buttons run: a plain path or just "dm".
dm_watch_self() {
  if [[ ${DM_SELF:-} =~ ^[A-Za-z0-9_./-]+$ ]]; then printf '%s\n' "$DM_SELF"; else printf 'dm\n'; fi
}

dm_watch_running() {
  local pid
  pid=$(cat "$(dm_watch_pidfile)" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# dm_watch_notify MACHINE SESSION WINDOW PANE SINCE TITLE — every argument already validated,
# except TITLE, which is only ever passed as a plain argument (never inside a shell string).
dm_watch_notify() {
  local machine=$1 session=$2 pane=$4 since=$5 title=$6 head self id act
  # shellcheck disable=SC2059 # the format comes from the catalog
  head=$(printf "$M_WATCH_TITLE" "$machine" "$session")
  case $(dm_platform) in
    termux)
      if command -v termux-notification >/dev/null; then
        self=$(dm_watch_self)
        id=$(printf '%s' "$machine$pane" | cksum | cut -d' ' -f1)
        act="$self _notify-act $machine $pane $since"
        termux-notification --id "$id" --title "$head" --content "$title" \
          --button1 "$M_WATCH_BTN_APPROVE" --button1-action "$act 1" \
          --button2 "$M_WATCH_BTN_REJECT" --button2-action "$act Escape" \
          --button3 "$M_WATCH_BTN_OPEN" --button3-action "$self go $machine $session"
        return 0
      fi
      ;;
    macos)
      osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
        -e 'end run' "$head" "$title" >/dev/null 2>&1 || true
      return 0
      ;;
  esac
  printf '%s | %s\n' "$head" "$title" >&2
}

# _notify-act MACHINE PANE SINCE KEY: a notification button; reports the outcome as a toast.
dm_watch_act() {
  local machine=${1:-} pane=${2:-} since=${3:-} key=${4:-} out msg
  if ! dm_valid_machine "$machine" || ! [[ $pane =~ ^%[0-9]+$ && $since =~ ^[0-9]+$ ]]; then
    dm_die "invalid arguments"
  fi
  case $key in 1 | 2 | 3 | Escape | Enter) ;; *) dm_die "key not allowed" ;; esac
  out=$(dm_run "$machine" dm _key "$pane" "$since" "$key" 2>/dev/null) || true
  case $out in
    sent) msg=$M_WATCH_SENT ;;
    stale) msg=$M_WATCH_STALE ;;
    *)
      # shellcheck disable=SC2059 # the format comes from the catalog
      msg=$(printf "$M_WATCH_ERROR" "$machine")
      ;;
  esac
  if command -v termux-toast >/dev/null; then termux-toast "$msg"; else printf '%s\n' "$msg" >&2; fi
}

# dm_watch_handle MACHINE LINE — one event from a machine; unvalidated fields are dropped.
dm_watch_handle() {
  local machine=$1 session window pane state since title
  IFS=$'\t' read -r session window pane state since title <<<"$2"
  [[ $state == waiting ]] || return 0
  dm_valid_session "$session" && [[ $window =~ ^[0-9]+$ && $pane =~ ^%[0-9]+$ && $since =~ ^[0-9]+$ ]] || return 0
  dm_watch_notify "$machine" "$session" "$window" "$pane" "$since" "$(dm_watch_clean "$title")"
}

# One reader per machine: reconnect with a 2 s to 60 s exponential wait.
dm_watch_reader() {
  local machine=$1 wait=2 started n=0 line
  while :; do
    started=$(date +%s)
    while IFS= read -r line; do
      dm_watch_handle "$machine" "$line"
    done < <(dm_run "$machine" dm _watch 2>/dev/null)
    n=$((n + 1))
    [[ -n ${DM_WATCH_MAX_CONNECTS:-} && $n -ge $DM_WATCH_MAX_CONNECTS ]] && return 0
    ((($(date +%s) - started) >= 10)) && wait=2
    sleep "$wait"
    wait=$((wait * 2 > 60 ? 60 : wait * 2))
  done
}

dm_watch_run() {
  local m
  mkdir -p "$(dm_watch_dir)"
  printf '%s\n' "$$" >"$(dm_watch_pidfile)"
  if [[ $(dm_platform) == termux ]] && ! command -v termux-notification >/dev/null; then
    dm_info "$M_WATCH_NEEDS_API"
  fi
  trap 'kill $(jobs -p) 2>/dev/null; rm -f "$(dm_watch_pidfile)"; exit 0' TERM INT HUP
  for m in $(dm_machines); do
    dm_watch_reader "$m" &
  done
  wait
}

dm_watch_on_macos() {
  local plist self
  plist=$(dm_watch_plist)
  self=$(dm_watch_self)
  mkdir -p "${plist%/*}" "$(dm_watch_dir)"
  cat >"$plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>net.devmesh.watch</string>
  <key>ProgramArguments</key>
  <array>
    <string>$self</string>
    <string>watch</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$(dm_watch_dir)/watch.log</string>
</dict>
</plist>
PL
  launchctl bootout "gui/$(id -u)/net.devmesh.watch" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load -w "$plist"
}

dm_watch_on() {
  if dm_watch_running; then
    dm_info "$M_WATCH_ALREADY"
    return 0
  fi
  mkdir -p "$(dm_watch_dir)"
  if [[ $(dm_platform) == macos ]]; then
    dm_watch_on_macos
  else
    [[ $(dm_platform) == termux ]] && command -v termux-wake-lock >/dev/null && termux-wake-lock
    nohup "$(dm_watch_self)" watch run </dev/null >>"$(dm_watch_dir)/watch.log" 2>&1 &
    printf '%s\n' "$!" >"$(dm_watch_pidfile)"
  fi
  dm_info "$M_WATCH_ON"
}

dm_watch_off() {
  local pid
  if [[ $(dm_platform) == macos && -f $(dm_watch_plist) ]]; then
    launchctl bootout "gui/$(id -u)/net.devmesh.watch" >/dev/null 2>&1 || true
    rm -f "$(dm_watch_plist)"
  fi
  if dm_watch_running; then
    pid=$(cat "$(dm_watch_pidfile)")
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$(dm_watch_pidfile)"
  [[ $(dm_platform) == termux ]] && command -v termux-wake-unlock >/dev/null && termux-wake-unlock
  dm_info "$M_WATCH_OFF"
}

dm_watch_status() {
  if dm_watch_running; then printf '%s\n' "$M_WATCH_RUNNING"; else printf '%s\n' "$M_WATCH_STOPPED"; fi
}

dm_watch() {
  case ${1:-status} in
    on) dm_watch_on ;;
    off) dm_watch_off ;;
    status) dm_watch_status ;;
    run) dm_watch_run ;;
    *) dm_die "$M_WATCH_USAGE" ;;
  esac
}
