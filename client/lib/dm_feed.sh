# shellcheck shell=bash
# dm feed: machine-readable data for the Go panel (dm-tui) and the launcher that starts it.
# dm-tui is only a presentation layer: everything remote or sensitive goes through dm.
# What machines send is untrusted: the panel strips escapes and control characters itself.

# _feed [HOST]: the mesh (or just one machine) as TSV, one record per line, first field is the record type:
#   V <version> <device>
#   M <machine> <OK|EMPTY|OFFLINE> <color> <ip> <lan|-> <mac|-> (the MAC itself is not sent)
#   C <machine> <sessionId> <status> <idleSecs> <tmux target|-> <rssMB> <cwd> <name>  (live Claude session)
#   H <machine> <sessionId> <ageSecs> <cwd> <name>                                    (stopped Claude session)
#   K <machine> <0|1>                                                                  (has Claude)
#   T <machine> <session> <window> <window name> <active> <command> <agent> <origin> <created> <activity> <clients>
dm_feed() {
  local only=${1:-}
  if [[ -n $only ]]; then
    [[ $only =~ ^[a-z][a-z0-9-]{0,15}$ ]] || dm_die "$M_MACHINE_UNAVAILABLE"
    dm_is_workspace_host "$only" || dm_die "$M_MACHINE_UNAVAILABLE"
  fi
  printf 'V\t%s\t%s\n' "$(dm_version)" "${DM_NAME:-}"
  [[ -n $(dm_machines) ]] || return 0
  local claude_out pid
  claude_out=$(mktemp)
  dm_claude_collect "$only" >"$claude_out" &
  pid=$!
  awk -F'\t' -v OFS='\t' '
    function dash(v) { return v == "" ? "-" : v }
    NR == FNR { ip[$1] = $3; color[$1] = $5; lan[$1] = $7; mac[$1] = ($8 == "-" || $8 == "") ? "-" : "mac"; next }
    {
      if ($1 != last) {
        print "M", $1, $2, dash(color[$1]), dash(ip[$1]), dash(lan[$1]), dash(mac[$1])
        last = $1
      }
      if ($2 == "OK") {
        line = "T"
        for (i = 1; i <= NF; i++) if (i != 2) line = line OFS $i
        print line
      }
    }' "$DM_CACHE/hosts.tsv" <(dm_collect "$only")
  wait "$pid" || true
  cat "$claude_out"
  rm -f "$claude_out"
}

# _shot HOST SESSION WINDOW: the live screen of a remote terminal (colors kept).
dm_feed_shot() {
  local host=${1:-} session=${2:-} win=${3:-}
  [[ $host =~ ^[a-z][a-z0-9-]{0,15}$ && $win =~ ^[0-9]+$ ]] || dm_die "invalid terminal"
  dm_valid_session "$session" || dm_die "invalid terminal"
  dm_run "$host" dm _capture "$session" "$win" 2>/dev/null
}

# _proj HOST: project folders of a machine, plain names only.
dm_feed_projects() {
  local host=${1:-} name
  [[ $host =~ ^[a-z][a-z0-9-]{0,15}$ ]] || dm_die "invalid machine"
  while read -r name; do
    [[ $name =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$ ]] && printf '%s\n' "$name"
  done < <(dm_run "$host" dm _projects 2>/dev/null || true)
  return 0
}

# _i18n: the active catalog as KEY=VALUE lines (escapes such as \n stay as written).
dm_feed_i18n() {
  local key
  for key in $(compgen -v M_); do
    [[ $key == M_I18N_LOADED ]] && continue
    printf '%s=%s\n' "$key" "${!key}"
  done
}

# _new [--check] HOST NAME [proj:<folder>]: the validation of the guided "new terminal"
# (same rules as the fzf panel), then open it. --check validates and prints the session name.
dm_feed_new() {
  local check=0 host name spec session
  if [[ ${1:-} == --check ]]; then
    check=1
    shift
  fi
  host=${1:-}
  name=${2:-}
  spec=${3:--}
  [[ $host =~ ^[a-z][a-z0-9-]{0,15}$ ]] || dm_die "$M_MACHINE_UNAVAILABLE"
  dm_is_workspace_host "$host" || dm_die "$M_MACHINE_UNAVAILABLE"
  [[ -n $name ]] || dm_die "$M_SAY_NAME_TERM"
  [[ $spec == - || ($spec == proj:* && ${spec#proj:} =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$) ]] ||
    dm_die "invalid project"
  session=$(dm_sanitize "$name")
  dm_valid_session "$session" || dm_die "$M_SAY_INVALID_NAME"
  if ((check)); then
    printf '%s\n' "$session"
    return 0
  fi
  dm_ui_open "$host" "$session" "" "$spec"
}

# dm_tui_bin: the dm-tui binary for this OS/arch (the share dir's bin/, else PATH), unless DM_TUI=0.
dm_tui_bin() {
  [[ ${DM_TUI:-1} != 0 ]] || return 1
  local target share bin
  target=$(tui_target) || return 1
  share=${DM_SHARE:-}
  [[ -n $share ]] || share=$(dm_share_dir)
  bin=$share/bin/dm-tui-$target
  if [[ -f $bin && -x $bin ]]; then
    printf '%s\n' "$bin"
    return 0
  fi
  command -v dm-tui
}

# dm_tui_launch: run the Go panel on a real terminal. Fails (so the caller falls back to the
# fzf panel) when there is no binary, no terminal, or the panel exits with an error.
dm_tui_launch() {
  local bin
  [[ -t 0 && -t 1 ]] || return 1
  bin=$(dm_tui_bin) || return 1
  "$bin"
}
