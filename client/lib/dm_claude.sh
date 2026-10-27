# shellcheck shell=bash
# Claude Code sessions across machines: the machine side ("dm _claude*", over SSH) and the
# controller side that the panel calls ("dm _c*"). Everything a machine sends is untrusted.
# Claude keeps ~/.claude/sessions/<pid>.json for each running session and one transcript
# ~/.claude/projects/<encoded cwd>/<sessionId>.jsonl per session (name = last "customTitle").

readonly DM_CLAUDE_TAIL_BYTES=49152
readonly DM_CLAUDE_HISTORY_MAX=60
readonly DM_CLAUDE_HISTORY_SCAN=150
readonly DM_CLAUDE_HISTORY_DAYS=30
readonly DM_CLAUDE_STOP_TRIES=25
readonly DM_CLAUDE_AUTOSTOP_DEFAULT=120 # minutes idle before a tmux session stops itself
readonly DM_CLAUDE_REAP_LOCK_MIN=10     # a reap lock older than this is stale
readonly DM_CLAUDE_UUID='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
readonly DM_CLAUDE_TMUX_TARGET='^[A-Za-z0-9_.-]+:@[0-9]+\.%[0-9]+$'
DM_CLAUDE_MAX_TRANSCRIPT=268435456     # 256 MiB: the biggest transcript a move carries (not readonly: tests lower it)
readonly DM_CLAUDE_MAX_COLLECT=2097152 # 2 MiB: the biggest "_claude" answer read from a machine
readonly DM_CLAUDE_COLLECT_TIMEOUT=30  # seconds one machine may take to answer
readonly DM_CLAUDE_FOLDER='^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$'

dm_claude_valid_sid() { [[ ${1:-} =~ $DM_CLAUDE_UUID ]]; }

# A project folder under $DM_PROJECTS_DIR: one or more plain names joined by "/".
dm_claude_valid_rel() {
  local part
  [[ -n ${1:-} && $1 != */ ]] || return 1
  local IFS=/
  for part in $1; do
    [[ $part =~ $DM_CLAUDE_FOLDER ]] || return 1
  done
}

# No control characters (TAB and newline included).
dm_claude_clean() { printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]'; }

# The claude executable: ssh sessions often lack ~/.local/bin in PATH.
dm_claude_bin() {
  local c
  command -v claude && return 0
  for c in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    if [[ -x $c ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# Shell-quote one word for tmux's shell-command.
dm_claude_q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# --- awk: reads JSON strings without a JSON parser -------------------------------------
DM_CLAUDE_AWK_LIB=$(
  cat <<'AWK'
function unesc(s) {
  gsub(/\\\\/, "\002", s)
  gsub(/\\"/, "\"", s)
  gsub(/\\\//, "/", s)
  gsub(/\\[ntrbf]/, " ", s)
  gsub(/\\u[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/, "", s)
  gsub(/\002/, "\\\\", s)
  gsub(/[[:cntrl:]]/, "", s)
  return s
}
# The first "key":"value" in s, unescaped ("" when absent).
function first_str(s, key,   re) {
  re = "\"" key "\":\"([^\"\\\\]|\\\\.)*\""
  if (!match(s, re)) return ""
  return unesc(substr(s, RSTART + length(key) + 4, RLENGTH - length(key) - 5))
}
function first_num(s, key,   re) {
  re = "\"" key "\":[0-9]+"
  if (!match(s, re)) return ""
  return substr(s, RSTART + length(key) + 3, RLENGTH - length(key) - 3)
}
function enc(p) { gsub(/[^A-Za-z0-9]/, "-", p); return p }
AWK
)

# Registry rows of every session file: pid, sessionId, status, statusUpdatedAt, tmux, cwd, name.
dm_claude_registry() {
  local dir=$HOME/.claude/sessions
  compgen -G "$dir/*.json" >/dev/null || return 0
  awk -v RS='\001' -v OFS='\t' "$DM_CLAUDE_AWK_LIB"'
    {
      n = FILENAME; sub(/^.*\//, "", n); sub(/\.json$/, "", n)
      pid = first_num($0, "pid"); sid = first_str($0, "sessionId")
      if (pid == "" || pid != n || sid !~ /^[0-9a-fA-F-]+$/ || length(sid) != 36) next
      st = first_str($0, "status"); up = first_num($0, "statusUpdatedAt")
      print pid, sid, st, up, first_str($0, "tmux"), first_str($0, "cwd"), first_str($0, "name")
    }' "$dir"/*.json 2>/dev/null
}

# RSS_KB[pid] for the pids on stdin: /proc where it exists, else one ps call.
dm_claude_load_rss() {
  local pid kb
  RSS_KB=()
  while read -r pid; do
    [[ -r /proc/$pid/status ]] || continue
    RSS_KB[$pid]=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
  done <<<"$1"
  while read -r pid kb; do
    [[ -n ${pid:-} && -z ${RSS_KB[$pid]:-} ]] && RSS_KB[$pid]=$kb
  done < <(ps -o pid=,rss= -p "$(tr '\n' ',' <<<"$1" | sed 's/,$//')" 2>/dev/null || true)
}

# Is PID a running Claude Code? A registry file can be stale or forged: a pid that was
# recycled (or 0 = our process group, 1 = init) must never be treated as a session or signalled.
dm_claude_is_claude() {
  local pid=${1:-} args first word base
  [[ $pid =~ ^[0-9]{1,10}$ ]] && ((10#$pid > 1)) || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  read -r first _ <<<"$args"
  base=${first##*/}
  [[ $base == claude ]] && return 0
  # Node-based install: node .../@anthropic-ai/claude-code/cli.js, or node .../bin/claude
  [[ $base == node || $base == bun ]] || return 1
  for word in $args; do
    [[ $word == */@anthropic-ai/claude-code/* || ${word##*/} == claude ]] && return 0
  done
  return 1
}

# Live sessions: registry rows whose pid is a running Claude (first row wins per sessionId).
dm_claude_live_rows() {
  local pid sid st up target cwd name
  local -A seen=()
  while IFS=$'\t' read -r pid sid st up target cwd name; do
    dm_claude_is_claude "$pid" || continue
    [[ -z ${seen[$sid]:-} ]] || continue
    seen[$sid]=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$sid" "$st" "$up" "$target" "$cwd" "$name"
  done < <(dm_claude_registry)
}

# The pid of the live session SID, only when its registry file says so.
dm_claude_live_pid() {
  # Reads to the end: an early exit would SIGPIPE the producer under pipefail.
  dm_claude_live_rows | awk -F'\t' -v s="$1" '$2 == s && !found {print $1; found = 1}'
}

# L <sessionId> <status> <idleSecs> <tmuxTarget|-> <rssMB> <cwd> <name>
dm_claude_live() {
  local rows=$1 now pid sid st up target cwd name idle kb
  local -A RSS_KB
  now=$(date +%s)
  dm_claude_load_rss "$(cut -f1 <<<"$rows")"
  while IFS=$'\t' read -r pid sid st up target cwd name; do
    [[ $st =~ ^[a-z]{1,16}$ ]] || st=idle
    [[ $target =~ $DM_CLAUDE_TMUX_TARGET ]] || target=-
    idle=0
    [[ $up =~ ^[0-9]{1,16}$ ]] && idle=$((now - 10#$up / 1000))
    ((idle >= 0)) || idle=0
    kb=${RSS_KB[$pid]:-0}
    [[ $kb =~ ^[0-9]+$ ]] || kb=0
    printf 'L\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sid" "$st" "$idle" "$target" "$((kb / 1024))" "$cwd" "$name"
  done <<<"$rows"
}

# "<age secs> <path>" for the newest transcripts of the last N days.
dm_claude_files() {
  local root=$HOME/.claude/projects now fmt
  [[ -d $root ]] || return 0
  now=$(date +%s)
  if stat -c %Y / >/dev/null 2>&1; then fmt=(-c '%Y %n'); else fmt=(-f '%m %N'); fi
  find "$root" -mindepth 2 -maxdepth 2 -name '*.jsonl' -mtime "-$((DM_CLAUDE_HISTORY_DAYS + 1))" \
    -exec stat "${fmt[@]}" {} + 2>/dev/null | sort -rn | awk -v n="$DM_CLAUDE_HISTORY_SCAN" 'NR <= n' |
    awk -v now="$now" -v max=$((DM_CLAUDE_HISTORY_DAYS * 86400)) '
      { m = $1; p = substr($0, length($1) + 2); a = now - m; if (a < 0) a = 0
        if (a <= max && p ~ /\/[0-9a-fA-F-]+\.jsonl$/) print a " " p }'
}

# GNU tail (gtail on a Mac with coreutils) reads many files far faster than BSD tail.
dm_claude_tail_bin() { command -v gtail || printf 'tail\n'; }

# The tails of the files, reduced to file headers and "customTitle" / "cwd" fields (grep is
# much faster than awk over megabytes).
dm_claude_tail_matches() {
  "$(dm_claude_tail_bin)" -c "$DM_CLAUDE_TAIL_BYTES" -- /dev/null "$@" 2>/dev/null |
    { LC_ALL=C grep -aoE '^==> .* <==$|"customTitle":"([^"\\]|\\.)*"|"cwd":"([^"\\]|\\.)*"' || true; }
}

# H <sessionId> <ageSecs> <cwd> <name> for the transcripts listed on stdin ("age path"), read
# through their tails only. ALL=1 keeps unnamed ones; LIVE is a space-separated list to skip.
# The cwd is the last one recorded that matches the folder the transcript lives in.
dm_claude_scan() {
  local list=$1 live=${2:-} all=${3:-0} paths
  [[ -n $list ]] || return 0
  mapfile -t paths < <(printf '%s\n' "$list" | cut -d' ' -f2-)
  awk -v live="$live" -v all="$all" -v max="$DM_CLAUDE_HISTORY_MAX" -v OFS='\t' "$DM_CLAUDE_AWK_LIB"'
    function flush(   id, d, a) {
      if (cur == "" || (!all && n >= max)) { cur = ""; return }
      id = cur; sub(/^.*\//, "", id); sub(/\.jsonl$/, "", id)
      d = cur; sub(/\/[^\/]*$/, "", d); sub(/^.*\//, "", d)
      c = (match_cwd != "") ? match_cwd : last_cwd
      if (!(id in skip) && c != "" && (all || title != "")) { print "H", id, age[cur], c, title; n++ }
      cur = ""
    }
    BEGIN { m = split(live, l, " "); for (i = 1; i <= m; i++) skip[l[i]] = 1 }
    NR == FNR { a = $1; p = substr($0, length($1) + 2); age[p] = a; next }
    /^==> .* <==$/ {
      p = substr($0, 5, length($0) - 8)
      flush()
      if (p in age) { cur = p; title = ""; last_cwd = ""; match_cwd = ""
        d = p; sub(/\/[^\/]*$/, "", d); sub(/^.*\//, "", d); dir = d }
      next
    }
    cur != "" && /^"customTitle":"/ { t = unesc(substr($0, 16, length($0) - 16)); if (t != "") title = t; next }
    cur != "" && /^"cwd":"/ {
      v = unesc(substr($0, 8, length($0) - 8))
      if (substr(v, 1, 1) == "/") { last_cwd = v; if (enc(v) == dir) match_cwd = v }
    }
    END { flush() }' <(printf '%s\n' "$list") \
    <(dm_claude_tail_matches "${paths[@]}")
}

# _claude: X <0|1>, then L records, then H records.
dm_claude() {
  local rows live_ids
  if dm_claude_bin >/dev/null; then printf 'X\t1\n'; else printf 'X\t0\n'; fi
  rows=$(dm_claude_live_rows)
  [[ -z $rows ]] || dm_claude_live "$rows"
  live_ids=$(awk -F'\t' '{printf "%s ", $2}' <<<"$rows")
  dm_claude_scan "$(dm_claude_files)" "$live_ids" 0
}

# The transcript of a session id.
dm_claude_transcript() {
  local f
  for f in "$HOME"/.claude/projects/*/"$1.jsonl"; do
    [[ -f $f ]] && {
      printf '%s\n' "$f"
      return 0
    }
  done
  return 1
}

# "<cwd><TAB><name>" of a transcript (name may be empty).
dm_claude_session_meta() {
  dm_claude_scan "0 $1" "" 1 | awk -F'\t' 'NR == 1 {print $4 "\t" $5}'
}

# A tmux session name from NAME that is not taken yet.
dm_claude_unique() {
  local base=$1 n=1 cand
  [[ -n $base ]] || base=claude
  cand=$base
  while tmux has-session -t "=$cand" 2>/dev/null; do
    n=$((n + 1))
    cand="${base:0:$((29 - ${#n}))}-$n"
  done
  printf '%s\n' "$cand"
}

# dm_claude_launch NAME DIR COMMAND: a new tmux session running COMMAND; prints its name.
dm_claude_launch() {
  local session
  session=$(dm_claude_unique "$(dm_sanitize "$1")")
  dm_valid_session "$session" || dm_die "invalid session name"
  tmux new-session -d -s "$session" -c "$2" "$3" || dm_die "could not start the session"
  tmux set-option -t "$session" @origin local
  tmux set-option -t "$session" @created "$(date +%s)"
  printf '%s\n' "$session"
}

# _claude_stop SESSION_ID: SIGTERM the live process of that session and wait for it.
dm_claude_stop() {
  local sid=${1:-} pid i
  dm_claude_valid_sid "$sid" || dm_die "invalid session id"
  pid=$(dm_claude_live_pid "$sid")
  [[ -n $pid ]] || return 0
  dm_claude_is_claude "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  for ((i = 0; i < DM_CLAUDE_STOP_TRIES; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  dm_die "the session did not stop"
}

# dm_claude_still_idle SID MIN_SECS: the live session SID is idle for at least MIN_SECS, now.
dm_claude_still_idle() {
  local rows k st idle
  rows=$(dm_claude_live_rows) || return 1
  [[ -n $rows ]] || return 1
  while IFS=$'\t' read -r k _ st idle _; do
    [[ $k == L && $st == idle && $idle =~ ^[0-9]+$ ]] && ((idle >= $2)) && return 0
  done < <(dm_claude_live "$(awk -F'\t' -v s="$1" '$2 == s' <<<"$rows")")
  return 1
}

# _claude_reap: stop the live sessions that sat idle for DM_CLAUDE_AUTOSTOP_MIN minutes
# (default 120, 0 = off). Only sessions inside tmux: one started elsewhere (a VS Code
# terminal) is never touched. They stay resumable. Safe to run often and concurrently.
dm_claude_reap() {
  local mins=${DM_CLAUDE_AUTOSTOP_MIN:-$DM_CLAUDE_AUTOSTOP_DEFAULT} cache lock rows
  local k sid st idle target
  [[ $mins =~ ^[0-9]+$ ]] || mins=$DM_CLAUDE_AUTOSTOP_DEFAULT
  ((mins > 0)) || return 0
  cache=${DM_CACHE:-$HOME/.cache/devmesh}
  mkdir -p "$cache"
  lock=$cache/claude-reap.lock
  find "$cache" -maxdepth 1 -name claude-reap.lock -mmin "+$DM_CLAUDE_REAP_LOCK_MIN" -exec rmdir {} + 2>/dev/null || true
  mkdir "$lock" 2>/dev/null || return 0
  rows=$(dm_claude_live_rows) || rows=
  if [[ -n $rows ]]; then
    while IFS=$'\t' read -r k sid st idle target _; do
      [[ $k == L && $st == idle && $target != - && $idle =~ ^[0-9]+$ ]] || continue
      ((idle >= mins * 60)) || continue
      # The row may be old by now: look again right before stopping (a prompt was typed).
      dm_claude_still_idle "$sid" "$((mins * 60))" || continue
      if (dm_claude_stop "$sid") 2>/dev/null; then
        printf 'devmesh: stopped idle Claude session %s (idle %s min, %s)\n' "$sid" "$((idle / 60))" "$target" >&2
      fi
    done < <(dm_claude_live "$rows")
  fi
  rmdir "$lock" 2>/dev/null || true
}

# _claude_resume SESSION_ID [CWD]: tmux session running "claude --resume"; prints its name.
dm_claude_resume() {
  local sid=${1:-} cwd=${2:-} bin file meta name
  dm_claude_valid_sid "$sid" || dm_die "invalid session id"
  bin=$(dm_claude_bin) || dm_die "claude is not installed"
  [[ -z $(dm_claude_live_pid "$sid") ]] || dm_die "the session is already running"
  file=$(dm_claude_transcript "$sid") || dm_die "no transcript for that session"
  meta=$(dm_claude_session_meta "$file")
  name=${meta#*$'\t'}
  [[ -n $cwd ]] || cwd=${meta%%$'\t'*}
  [[ $cwd == /* && $cwd == "$(dm_claude_clean "$cwd")" && -d $cwd ]] || dm_die "the session folder does not exist"
  dm_claude_launch "$name" "$cwd" "$(dm_claude_q "$bin") --resume $sid"
}

# _claude_new NAME proj:FOLDER: tmux session running "claude --name NAME" in the project; prints its name.
dm_claude_new() {
  local name spec=${2:-} bin dir
  name=$(dm_claude_clean "${1:-}")
  [[ -n $name && ${#name} -le 100 && $name != -* ]] || dm_die "invalid name"
  [[ $spec == proj:* ]] || dm_die "invalid project"
  dm_claude_valid_rel "${spec#proj:}" || dm_die "invalid project"
  dir=$DM_PROJECTS_DIR/${spec#proj:}
  [[ -d $dir ]] || dm_die "no such project"
  bin=$(dm_claude_bin) || dm_die "claude is not installed"
  dm_claude_launch "$name" "$dir" "$(dm_claude_q "$bin") --name $(dm_claude_q "$name")"
}

# --- Moving a session: machine-side helpers ---------------------------------------------

# "<git: none|clean|dirty><TAB><HEAD|->" of a folder.
dm_claude_git_state() {
  local dir=$1 head state=clean
  if ! command -v git >/dev/null || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'none\t-\n'
    return 0
  fi
  # A repo's own config must not run anything here (fsmonitor, hooks).
  local -a g=(git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$dir")
  head=$("${g[@]}" rev-parse HEAD 2>/dev/null) || head=-
  [[ -z $("${g[@]}" status --porcelain 2>/dev/null) ]] || state=dirty
  printf '%s\t%s\n' "$state" "$head"
}

# _claude_info SESSION_ID: "<cwd> <live 0|1> <projects dir> <dir exists 0|1> <git> <HEAD>" (TAB).
dm_claude_info() {
  local sid=${1:-} file meta cwd live=0 exists=0
  dm_claude_valid_sid "$sid" || dm_die "invalid session id"
  file=$(dm_claude_transcript "$sid") || dm_die "no transcript for that session"
  meta=$(dm_claude_session_meta "$file")
  cwd=${meta%%$'\t'*}
  [[ -z $(dm_claude_live_pid "$sid") ]] || live=1
  [[ -d $cwd ]] && exists=1
  printf '%s\t%s\t%s\t%s\t%s\n' "$cwd" "$live" "$DM_PROJECTS_DIR" "$exists" \
    "$([[ $exists == 1 ]] && dm_claude_git_state "$cwd" || printf 'none\t-')"
}

# Does this machine already have SID, as a transcript or as a running session?
dm_claude_sid_taken() {
  dm_claude_transcript "$1" >/dev/null && return 0
  [[ -n $(dm_claude_live_pid "$1") ]]
}

# _claude_probe REL [SID]: "<claude 0|1> <projects dir> <dir exists 0|1> <git> <HEAD> <sid taken 0|1>" (TAB).
dm_claude_probe() {
  local rel=${1:-} sid=${2:-} has=0 exists=0 taken=0
  dm_claude_valid_rel "$rel" || dm_die "invalid project"
  if [[ -n $sid ]]; then
    dm_claude_valid_sid "$sid" || dm_die "invalid session id"
    ! dm_claude_sid_taken "$sid" || taken=1
  fi
  dm_claude_bin >/dev/null && has=1
  [[ -d $DM_PROJECTS_DIR/$rel ]] && exists=1
  printf '%s\t%s\t%s\t%s\t%s\n' "$has" "$DM_PROJECTS_DIR" "$exists" \
    "$([[ $exists == 1 ]] && dm_claude_git_state "$DM_PROJECTS_DIR/$rel" || printf 'none\t-')" "$taken"
}

# _claude_export SESSION_ID: the transcript on stdout.
dm_claude_export() {
  local file
  dm_claude_valid_sid "${1:-}" || dm_die "invalid session id"
  file=$(dm_claude_transcript "$1") || dm_die "no transcript for that session"
  cat "$file"
}

# _claude_import SESSION_ID REL: store the transcript on stdin under the encoded cwd of
# $DM_PROJECTS_DIR/REL; prints that cwd.
dm_claude_import() {
  local sid=${1:-} rel=${2:-} cwd dest tmp raw
  dm_claude_valid_sid "$sid" || dm_die "invalid session id"
  dm_claude_valid_rel "$rel" || dm_die "invalid project"
  cwd=$DM_PROJECTS_DIR/$rel
  [[ -d $cwd ]] || dm_die "no such project"
  dest=$HOME/.claude/projects/${cwd//[^A-Za-z0-9]/-}
  ! dm_claude_sid_taken "$sid" || dm_die "that session already exists here"
  mkdir -p "$dest"
  tmp=$(mktemp "$dest/.import.XXXXXX")
  raw=$(mktemp "$dest/.import.XXXXXX")
  # At most the cap (+1 byte to tell "exactly the cap" from "more").
  head -c $((DM_CLAUDE_MAX_TRANSCRIPT + 1)) >"$raw"
  if (($(wc -c <"$raw") > DM_CLAUDE_MAX_TRANSCRIPT)); then
    rm -f "$tmp" "$raw"
    dm_die "transcript too big"
  fi
  # Only JSON object lines are kept, and the first non-empty line must be one.
  LC_ALL=C awk '
    !started && $0 ~ /^[ \t\r]*$/ { next }
    { if (!started && !(substr($0, 1, 1) == "{")) bad = 1; started = 1 }
    substr($0, 1, 1) == "{" && substr($0, length($0), 1) == "}" { print }
    END { exit bad }' <"$raw" >"$tmp" || {
    rm -f "$tmp" "$raw"
    dm_die "not a transcript"
  }
  rm -f "$raw"
  [[ -s $tmp ]] || {
    rm -f "$tmp"
    dm_die "empty transcript"
  }
  # mv -n never replaces; the source file still existing afterwards means someone got there first.
  mv -n "$tmp" "$dest/$sid.jsonl"
  if [[ -e $tmp ]]; then
    rm -f "$tmp"
    dm_die "that session already exists here"
  fi
  printf '%s\n' "$cwd"
}

# --- Controller side (the device that shows the panel) ----------------------------------

dm_claude_host() {
  [[ ${1:-} =~ ^[a-z][a-z0-9-]{0,15}$ ]] || dm_die "$M_MACHINE_UNAVAILABLE"
  dm_is_workspace_host "$1" || dm_die "$M_MACHINE_UNAVAILABLE"
}

dm_claude_check_sid() { dm_claude_valid_sid "${1:-}" || dm_die "$M_CLAUDE_BAD_ID"; }

# A tmux session name coming back from a machine.
dm_claude_session_out() {
  local out
  out=$(printf '%s' "$1" | tail -n 1)
  dm_valid_session "$out" || dm_die "$M_CLAUDE_FAILED"
  printf '%s\n' "$out"
}

# dm_claude_collect [HOST]: C/H/K records of every machine (or HOST), fetched in parallel.
# A machine that is offline, or too old to know "_claude", gives nothing.
dm_claude_collect() (
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  local h
  local tmo=""
  command -v timeout >/dev/null && tmo=timeout
  [[ -n $tmo ]] || ! command -v gtimeout >/dev/null || tmo=gtimeout
  local DM_RUN_PREFIX=()
  # shellcheck disable=SC2034 # read by dm_run (dynamic scope)
  [[ -z $tmo ]] || DM_RUN_PREFIX=("$tmo" "$DM_CLAUDE_COLLECT_TIMEOUT")
  for h in ${1:-$(dm_machines)}; do
    # Capped: a machine answering without end must not fill this one.
    (dm_run "$h" dm _claude 2>/dev/null | head -c "$DM_CLAUDE_MAX_COLLECT" >"$tmp/$h.out" || : >"$tmp/$h.out") &
  done
  wait
  for h in ${1:-$(dm_machines)}; do
    [[ -s $tmp/$h.out ]] && dm_claude_records "$h" <"$tmp/$h.out"
  done
  return 0
)

# dm_claude_records MACHINE < _claude output: validated C/H/K lines.
dm_claude_records() {
  # The regex goes through ENVIRON: -v would unescape its backslashes.
  DM_TMUXRE=$DM_CLAUDE_TMUX_TARGET awk -F'\t' -v OFS='\t' -v m="$1" '
    BEGIN { tmuxre = ENVIRON["DM_TMUXRE"] }
    function sid_ok(s) { return length(s) == 36 && s ~ /^[0-9a-fA-F-]+$/ && gsub(/-/, "-", s) == 4 }
    function tail_from(k,   i, v) { v = ""; for (i = k; i <= NF; i++) v = v (i > k ? " " : "") $i; gsub(/[[:cntrl:]]/, "", v); return v }
    $1 == "X" && ($2 == "0" || $2 == "1") && !x++ { print "K", m, $2 }
    $1 == "L" && NF >= 7 && sid_ok($2) && $3 ~ /^[a-z]+$/ && length($3) <= 16 && $4 ~ /^[0-9]+$/ && ($5 == "-" || $5 ~ tmuxre) \
      && $6 ~ /^[0-9]+$/ && substr($7, 1, 1) == "/" { gsub(/[[:cntrl:]]/, "", $7); print "C", m, $2, $3, $4, $5, $6, $7, tail_from(8) }
    $1 == "H" && NF >= 4 && sid_ok($2) && $3 ~ /^[0-9]+$/ && substr($4, 1, 1) == "/" { gsub(/[[:cntrl:]]/, "", $4); print "H", m, $2, $3, $4, tail_from(5) }'
}

# _cstop HOST SESSION_ID
dm_claude_cstop() {
  dm_claude_host "${1:-}"
  dm_claude_check_sid "${2:-}"
  dm_run "$1" dm _claude_stop "$2" >/dev/null 2>&1 || dm_die "$M_CLAUDE_FAILED"
}

# _cresume HOST SESSION_ID: prints the tmux session to open.
dm_claude_cresume() {
  local out
  dm_claude_host "${1:-}"
  dm_claude_check_sid "${2:-}"
  out=$(dm_run "$1" dm _claude_resume "$2" 2>/dev/null) || dm_die "$M_CLAUDE_FAILED"
  dm_claude_session_out "$out"
}

# _cnew HOST NAME proj:FOLDER: prints the tmux session to open.
dm_claude_cnew() {
  local host=${1:-} name spec=${3:-} out
  dm_claude_host "$host"
  name=$(dm_claude_clean "${2:-}")
  [[ -n $name && ${#name} -le 100 && $name != -* ]] || dm_die "$M_SAY_NAME_TERM"
  [[ $spec == proj:* ]] || dm_die "$M_CLAUDE_FAILED"
  dm_claude_valid_rel "${spec#proj:}" || dm_die "$M_CLAUDE_FAILED"
  out=$(dm_run "$host" dm _claude_new "$name" "$spec" 2>/dev/null) || dm_die "$M_CLAUDE_FAILED"
  dm_claude_session_out "$out"
}

# dm_claude_fail KEY ARGS...: die with a catalog message that has %s placeholders.
dm_claude_fail() {
  local key=$1 fmt
  shift
  fmt=${!key}
  # shellcheck disable=SC2059 # the catalog message is the format
  dm_die "$(printf "$fmt" "$@")"
}

# The checks that decide whether SID can run on DST: dies with the reason.
dm_claude_move_checks() {
  local src=$1 dst=$2 rel=$3 sgit=$4 shead=$5 sid=$6 probe has dexists dhead taken
  probe=$(dm_run "$dst" dm _claude_probe "$rel" "$sid" 2>/dev/null) || dm_claude_fail M_CLAUDE_NO_CLAUDE "$dst"
  IFS=$'\t' read -r has _ dexists _ dhead taken <<<"$probe"
  [[ $has == 1 ]] || dm_claude_fail M_CLAUDE_NO_CLAUDE "$dst"
  [[ $dexists == 1 ]] || dm_claude_fail M_CLAUDE_NO_FOLDER "$rel" "$dst"
  [[ $sgit != dirty ]] || dm_claude_fail M_CLAUDE_DIRTY "$src" "$dst"
  [[ $sgit == none || $dhead == "$shead" ]] || dm_claude_fail M_CLAUDE_HEAD_DIFF "$dst" "$src" "$dst"
  [[ $taken == 0 ]] || dm_claude_fail M_CLAUDE_EXISTS "$dst"
}

# Copy the transcript from SRC to DST through a temp file; prints the cwd it got on DST.
dm_claude_transfer() {
  local src=$1 dst=$2 sid=$3 rel=$4 tmp dcwd rc=0 exp_rc
  tmp=$(mktemp)
  # Capped (+1 byte to see an oversize one); head closing the pipe ends the export early.
  dm_run "$src" dm _claude_export "$sid" 2>/dev/null | head -c $((DM_CLAUDE_MAX_TRANSCRIPT + 1)) >"$tmp"
  exp_rc=${PIPESTATUS[0]}
  if (($(wc -c <"$tmp") > DM_CLAUDE_MAX_TRANSCRIPT)); then
    rm -f "$tmp"
    dm_die "$M_CLAUDE_TOO_BIG"
  fi
  if [[ $exp_rc == 0 && -s $tmp ]]; then
    dcwd=$(dm_run "$dst" dm _claude_import "$sid" "$rel" <"$tmp" 2>/dev/null | tail -n 1) || rc=1
  else
    rc=1
  fi
  rm -f "$tmp"
  # Goes back through ssh as an argument: plain absolute path characters only.
  [[ $rc == 0 && $dcwd =~ ^/[A-Za-z0-9._/-]+$ && $dcwd != *..* ]] || return 1
  printf '%s\n' "$dcwd"
}

# _cmove SRC SESSION_ID DST: stop on SRC (if live), copy the transcript, resume on DST.
dm_claude_cmove() {
  local src=${1:-} sid=${2:-} dst=${3:-} info cwd live sproj sexists sgit shead rel dcwd out
  dm_claude_host "$src"
  dm_claude_host "$dst"
  dm_claude_check_sid "$sid"
  [[ $src != "$dst" ]] || dm_die "$M_CLAUDE_SAME"
  info=$(dm_run "$src" dm _claude_info "$sid" 2>/dev/null) || dm_die "$M_CLAUDE_FAILED"
  IFS=$'\t' read -r cwd live sproj sexists sgit shead <<<"$info"
  [[ -n $sproj && $cwd == "$sproj"/* ]] || dm_die "$M_CLAUDE_OUTSIDE"
  rel=${cwd#"$sproj"/}
  dm_claude_valid_rel "$rel" || dm_die "$M_CLAUDE_OUTSIDE"
  [[ $sexists == 1 ]] || dm_claude_fail M_CLAUDE_NO_FOLDER "$rel" "$src"
  dm_claude_move_checks "$src" "$dst" "$rel" "$sgit" "$shead" "$sid"
  [[ $live != 1 ]] || dm_claude_cstop "$src" "$sid"
  dcwd=$(dm_claude_transfer "$src" "$dst" "$sid" "$rel") || dm_die "$M_CLAUDE_FAILED"
  out=$(dm_run "$dst" dm _claude_resume "$sid" "$dcwd" 2>/dev/null) || dm_die "$M_CLAUDE_FAILED"
  dm_claude_session_out "$out"
}
