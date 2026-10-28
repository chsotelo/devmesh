#!/usr/bin/env bats
# Claude sessions: the machine side (_claude, _claude_stop/_resume/_new, ...) over fake
# ~/.claude trees, and the controller side (_feed records, _cstop/_cresume/_cnew/_cmove) over stub ssh.

bats_require_minimum_version 1.5.0
load helpers

SID1=11111111-1111-4111-8111-111111111111
SID2=22222222-2222-4222-8222-222222222222
SID3=33333333-3333-4333-8333-333333333333

setup() {
  export DM_LANG=en
  setup_client
  dm_share_dir() { printf '%s\n' "$DM_SHARE"; }
  t=$'\t'
  export DM_PROJECTS_DIR="$HOME/PROJECTS"
  mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$DM_PROJECTS_DIR/redi"
  SLEEPERS=()
}

teardown() {
  local p
  for p in "${SLEEPERS[@]:-}"; do [[ -n $p ]] && kill "$p" 2>/dev/null || true; done
}

# touch_days FILE DAYS: mtime N days ago (GNU or BSD date).
touch_days() {
  touch -t "$(date -d "-$2 days" +%Y%m%d%H%M 2>/dev/null || date -v-"$2"d +%Y%m%d%H%M)" "$1"
}

# live_session SID STATUS TMUX CWD NAME: a registry file for a real (sleeping) process.
live_session() {
  # exec -a: the process shows up as "claude 300" in ps, like a real Claude Code.
  bash -c 'exec -a claude sleep 300' &
  local pid=$!
  SLEEPERS+=("$pid")
  local up=$(($(date +%s) * 1000 - 120000))
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","name":"%s","status":"%s","statusUpdatedAt":%s,"tmux":"%s","entrypoint":"cli"}' \
    "$pid" "$1" "$4" "$5" "$2" "$up" "$3" >"$HOME/.claude/sessions/$pid.json"
  LIVE_PID=$pid
}

# registry_file PID SID STATUS: a registry file for any pid (no process behind it needed).
registry_file() {
  local up=$(($(date +%s) * 1000 - 120000))
  printf '{"pid":%s,"sessionId":"%s","cwd":"/x","name":"n","status":"%s","statusUpdatedAt":%s,"tmux":"redi:@3.%%7"}' \
    "$1" "$2" "$3" "$up" >"$HOME/.claude/sessions/$1.json"
}

# transcript SID CWD [TITLE...]: a transcript under the encoded cwd; each TITLE is a customTitle record.
transcript() {
  local sid=$1 cwd=$2 enc f title
  shift 2
  enc=${cwd//[^A-Za-z0-9]/-}
  mkdir -p "$HOME/.claude/projects/$enc"
  f=$HOME/.claude/projects/$enc/$sid.jsonl
  printf '{"type":"user","cwd":"%s","message":"hi"}\n' "$cwd" >"$f"
  for title in "$@"; do
    printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$title" "$sid" >>"$f"
  done
  printf '{"type":"assistant","cwd":"%s"}\n' "$cwd" >>"$f"
  TRANSCRIPT=$f
}

# --- _claude -------------------------------------------------------------------------

@test "_claude: live sessions as L records, stale and mismatching registry files ignored" {
  live_session "$SID1" busy "redi:@3.%7" "$DM_PROJECTS_DIR/redi" '19Oct - redi \"general\"'
  printf '{"pid":999999,"sessionId":"%s","cwd":"/x","name":"dead","status":"idle"}' "$SID2" >"$HOME/.claude/sessions/999999.json"
  printf '{"pid":%s,"sessionId":"%s","cwd":"/x","name":"liar","status":"idle"}' "$LIVE_PID" "$SID3" >"$HOME/.claude/sessions/12345.json"
  printf '%s' '{"pid":1,"sessionId":"not-a-uuid","name":"x"}' >"$HOME/.claude/sessions/1.json"
  run dm_claude
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "X${t}1" ]
  [ "${#lines[@]}" -eq 2 ]
  IFS=$'\t' read -r k sid st idle target rss cwd name <<<"${lines[1]}"
  [ "$k" = L ] && [ "$sid" = "$SID1" ] && [ "$st" = busy ] && [ "$target" = "redi:@3.%7" ]
  [[ $idle =~ ^[0-9]+$ && $idle -ge 119 && $idle -lt 200 ]]
  [[ $rss =~ ^[0-9]+$ ]]
  [ "$cwd" = "$DM_PROJECTS_DIR/redi" ]
  [ "$name" = '19Oct - redi "general"' ]
}

@test "_claude: the real dm (set -e) lists a live session; on Linux its RSS comes from /proc" {
  live_session "$SID1" busy "redi:@3.%7" "$DM_PROJECTS_DIR/redi" 'x'
  run "$REPO/client/bin/dm" _claude
  [ "$status" -eq 0 ]
  [[ ${lines[1]} == "L${t}${SID1}${t}"* ]]
}

@test "_claude: no tmux, bad values and control characters are cleaned" {
  live_session "$SID1" 'bad status' 'x;rm -rf' /srv/app $'a\\tb\\u0007c'
  run dm_claude
  IFS=$'\t' read -r _ _ st _ target _ cwd name <<<"${lines[1]}"
  [ "$st" = idle ] && [ "$target" = - ]
  [ "$name" = "a bc" ]
  [ "$(awk -F'\t' 'NR == 2 {print NF}' <<<"$output")" = 8 ]
}

@test "_claude: history is named, recent, not live, newest first, with the cwd of its folder" {
  live_session "$SID1" idle - "$DM_PROJECTS_DIR/redi" live-one
  transcript "$SID1" "$DM_PROJECTS_DIR/redi" "live-one"
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" "first title" '20Oct - redi \"api\"'
  touch_days "$TRANSCRIPT" 2
  transcript "$SID3" "$DM_PROJECTS_DIR/redi" "old one"
  touch_days "$TRANSCRIPT" 40
  transcript 44444444-4444-4444-8444-444444444444 "$DM_PROJECTS_DIR/redi"
  transcript 55555555-5555-4555-8555-555555555555 "$HOME/my proj.x" "dotted dir"
  touch_days "$TRANSCRIPT" 1
  run dm_claude
  [ "$status" -eq 0 ]
  mapfile -t h < <(grep '^H' <<<"$output")
  [ "${#h[@]}" -eq 2 ]
  IFS=$'\t' read -r _ sid age cwd name <<<"${h[0]}"
  [ "$sid" = 55555555-5555-4555-8555-555555555555 ] && [ "$cwd" = "$HOME/my proj.x" ] && [ "$name" = "dotted dir" ]
  [[ $age -ge 86300 && $age -lt 90000 ]]
  IFS=$'\t' read -r _ sid age cwd name <<<"${h[1]}"
  [ "$sid" = "$SID2" ] && [ "$cwd" = "$DM_PROJECTS_DIR/redi" ] && [ "$name" = '20Oct - redi "api"' ]
}

@test "_claude: a cwd that moved inside the session does not replace the transcript's folder" {
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" "named"
  printf '{"type":"user","cwd":"%s/redi/sub"}\n' "$DM_PROJECTS_DIR" >>"$TRANSCRIPT"
  run dm_claude
  IFS=$'\t' read -r _ _ _ cwd _ <<<"$(grep '^H' <<<"$output")"
  [ "$cwd" = "$DM_PROJECTS_DIR/redi" ]
}

@test "local_cwd: a session last working in a subfolder resumes in the folder it started in" {
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" "named"
  mkdir -p "$DM_PROJECTS_DIR/redi/sub"
  run dm_claude_local_cwd "$TRANSCRIPT" "$DM_PROJECTS_DIR/redi/sub"
  [ "$output" = "$DM_PROJECTS_DIR/redi" ]
  run dm_claude_local_cwd "$TRANSCRIPT" "/elsewhere/PROJECTS/redi/sub"
  [ "$output" = "$DM_PROJECTS_DIR/redi" ]
}

@test "_claude: at most 60 history records and 300 transcripts stay fast" {
  local i
  for i in $(seq 1 300); do
    transcript "$(printf '%08d-0000-4000-8000-000000000000' "$i")" "$DM_PROJECTS_DIR/redi" "session $i"
  done
  local start=$SECONDS
  run dm_claude
  [ "$((SECONDS - start))" -le 2 ]
  [ "$(grep -c '^H' <<<"$output")" -eq 60 ]
}

@test "_claude: X 0 when claude is not installed, still lists history" {
  dm_claude_bin() { return 1; }
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" "named"
  run dm_claude
  [ "${lines[0]}" = "X${t}0" ]
  [[ ${lines[1]} == "H${t}$SID2"* ]]
}

@test "_claude: no ~/.claude at all prints only X" {
  rm -rf "$HOME/.claude"
  run dm_claude
  [ "$status" -eq 0 ]
  [ "$output" = "X${t}1" ]
}

# --- _claude_stop --------------------------------------------------------------------

@test "_claude_stop: signals the live pid of that session and waits for it" {
  live_session "$SID1" idle - /x n1
  local keep=$LIVE_PID
  live_session "$SID2" idle - /x n2
  run dm_claude_stop "$SID2"
  [ "$status" -eq 0 ]
  ! kill -0 "$LIVE_PID" 2>/dev/null
  kill -0 "$keep"
}

@test "_claude_stop: never signals a pid whose registry file names another session" {
  live_session "$SID1" idle - /x n1
  run dm_claude_stop "$SID3"
  [ "$status" -eq 0 ]
  kill -0 "$LIVE_PID"
}

@test "a registry pid that is not Claude is ignored and never signalled" {
  sleep 300 &
  local pid=$!
  SLEEPERS+=("$pid")
  registry_file "$pid" "$SID1" idle
  [ -z "$(dm_claude_live_rows)" ]
  kill() { printf 'kill %s\n' "$*" >>"$BATS_TEST_TMPDIR/kills"; builtin kill "$@"; }
  run dm_claude_stop "$SID1"
  [ "$status" -eq 0 ]
  ! grep -q -- "-TERM" "$BATS_TEST_TMPDIR/kills" 2>/dev/null
  unset -f kill
  builtin kill -0 "$pid"
}

@test "registry pids 0 and 1 are never live and never signalled" {
  registry_file 0 "$SID1" idle
  registry_file 1 "$SID2" idle
  [ -z "$(dm_claude_live_rows)" ]
  kill() { printf 'kill %s\n' "$*" >>"$BATS_TEST_TMPDIR/kills"; }
  run dm_claude_stop "$SID1"
  run dm_claude_stop "$SID2"
  [ ! -s "$BATS_TEST_TMPDIR/kills" ]
  unset -f kill
}

@test "dm_claude_is_claude: claude binary and node install forms, nothing else" {
  live_session "$SID1" idle - /x n1
  dm_claude_is_claude "$LIVE_PID"
  ! dm_claude_is_claude abc
  ! dm_claude_is_claude 99999999999
  ps() { printf '%s\n' "$PS_ARGS"; }
  PS_ARGS='/Users/me/.local/bin/claude --resume abc' dm_claude_is_claude "$LIVE_PID"
  PS_ARGS='node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js' dm_claude_is_claude "$LIVE_PID"
  ! PS_ARGS='/usr/bin/vim claude' dm_claude_is_claude "$LIVE_PID"
  ! PS_ARGS='/bin/sleep 300' dm_claude_is_claude "$LIVE_PID"
  unset -f ps
}

@test "_claude_stop: rejects an id that is not a UUID" {
  run dm_claude_stop '../x'
  [ "$status" -ne 0 ]
}

# --- _claude_reap --------------------------------------------------------------------

@test "_claude_reap: stops idle tmux sessions past the limit, logs one line each, leaves the rest" {
  export DM_CACHE="$BATS_TEST_TMPDIR/cache" DM_CLAUDE_AUTOSTOP_MIN=1
  live_session "$SID1" idle "redi:@3.%7" /x idle-tmux
  local victim=$LIVE_PID
  live_session "$SID2" busy "redi:@4.%8" /x busy-tmux
  local busy=$LIVE_PID
  live_session "$SID3" idle - /x idle-vscode
  local nontmux=$LIVE_PID
  run --separate-stderr dm_claude_reap
  [ "$status" -eq 0 ]
  ! kill -0 "$victim" 2>/dev/null
  kill -0 "$busy"
  kill -0 "$nontmux"
  [ "$(grep -c 'stopped idle Claude session' <<<"$stderr")" -eq 1 ]
  [[ $stderr == *"$SID1"* ]]
  [ ! -d "$DM_CACHE/claude-reap.lock" ]
}

@test "_claude_reap: the stopped session's terminal stays, asleep, when the pane is back at its shell" {
  export DM_CACHE="$BATS_TEST_TMPDIR/cache" DM_CLAUDE_AUTOSTOP_MIN=1 DM_SELF="$REPO/client/bin/dm"
  export STUB_TMUX_DISPLAY="$BATS_TEST_TMPDIR/display"
  echo zsh >"$STUB_TMUX_DISPLAY"
  live_session "$SID1" idle "redi:@3.%7" /x n1
  run --separate-stderr dm_claude_reap
  [ "$status" -eq 0 ]
  grep -q "^tmux respawn-pane -k -t %7 '.*bash' '.*/dm' _claude_sleep $SID1\$" "$STUB_LOG"
}

@test "_claude_reap: a pane running anything but a shell is never replaced" {
  export DM_CACHE="$BATS_TEST_TMPDIR/cache" DM_CLAUDE_AUTOSTOP_MIN=1 DM_CLAUDE_SLEEP_WAIT=1
  export STUB_TMUX_DISPLAY="$BATS_TEST_TMPDIR/display"
  echo vim >"$STUB_TMUX_DISPLAY"
  live_session "$SID1" idle "redi:@3.%7" /x n1
  run --separate-stderr dm_claude_reap
  [ "$status" -eq 0 ]
  ! grep -q "respawn-pane" "$STUB_LOG"
}

@test "_claude_sleep: shows the session asleep; Enter resumes it in its folder, then a shell" {
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" $'19Oct - redi\033[31m'
  run env SHELL=/bin/echo bash -c "cd / && source \"$REPO/client/bin/dm\" && dm_load_conf && dm_claude_sleep $SID2" <<<""
  [ "$status" -eq 0 ]
  [[ $output == *"19Oct - redi"* ]]
  [[ $output != *$'\033[31m'* ]]
  [[ $output == *"Enter"* ]]
  grep -q "^claude --resume $SID2\$" "$STUB_LOG"
  [[ ${lines[-1]} == "-l" ]]
}

@test "_claude_sleep: a session resumed or moved elsewhere meanwhile is not started twice" {
  run env SHELL=/bin/echo bash -c "source \"$REPO/client/bin/dm\" && dm_load_conf && dm_claude_sleep $SID2" <<<""
  [ "$status" -eq 0 ]
  ! grep -q "^claude --resume" "$STUB_LOG"
  [[ ${lines[-1]} == "-l" ]]
}

@test "_claude_reap: a session that stopped being idle meanwhile is not stopped" {
  export DM_CACHE="$BATS_TEST_TMPDIR/cache" DM_CLAUDE_AUTOSTOP_MIN=1
  live_session "$SID1" idle "redi:@3.%7" /x n1
  local flag=$BATS_TEST_TMPDIR/second
  eval "orig_$(declare -f dm_claude_live_rows)"
  dm_claude_live_rows() {
    if [[ -e $flag ]]; then
      sed 's/"status":"idle"/"status":"busy"/' "$HOME/.claude/sessions/$LIVE_PID.json" >"$HOME/.claude/sessions/x.new"
      mv "$HOME/.claude/sessions/x.new" "$HOME/.claude/sessions/$LIVE_PID.json"
    else
      : >"$flag"
    fi
    orig_dm_claude_live_rows
  }
  run --separate-stderr dm_claude_reap
  [ "$status" -eq 0 ]
  kill -0 "$LIVE_PID"
  [[ $stderr != *"stopped idle"* ]]
}

@test "_claude_reap: below the limit, disabled with 0, and a bad value falls back to the default" {
  export DM_CACHE="$BATS_TEST_TMPDIR/cache"
  live_session "$SID1" idle "redi:@3.%7" /x n1
  DM_CLAUDE_AUTOSTOP_MIN=3 run dm_claude_reap
  kill -0 "$LIVE_PID"
  DM_CLAUDE_AUTOSTOP_MIN=0 run dm_claude_reap
  kill -0 "$LIVE_PID"
  DM_CLAUDE_AUTOSTOP_MIN=abc run dm_claude_reap
  kill -0 "$LIVE_PID"
  unset DM_CLAUDE_AUTOSTOP_MIN
  run dm_claude_reap
  kill -0 "$LIVE_PID"
}

@test "_claude_reap: does nothing while another reap holds the lock, replaces a stale one" {
  export DM_CACHE="$BATS_TEST_TMPDIR/cache" DM_CLAUDE_AUTOSTOP_MIN=1
  mkdir -p "$DM_CACHE/claude-reap.lock"
  live_session "$SID1" idle "redi:@3.%7" /x n1
  run dm_claude_reap
  kill -0 "$LIVE_PID"
  touch -t 202001010000 "$DM_CACHE/claude-reap.lock"
  run dm_claude_reap
  ! kill -0 "$LIVE_PID" 2>/dev/null
}

@test "dm _claude_reap is dispatched" {
  run grep -q '_claude_reap) dm_claude_reap' "$REPO/client/bin/dm"
  [ "$status" -eq 0 ]
}

# --- _claude_resume / _claude_new ----------------------------------------------------

@test "_claude_resume: new tmux session named after the session, in its cwd, running claude --resume" {
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" "19Oct - Redi General"
  run dm_claude_resume "$SID2"
  [ "$status" -eq 0 ]
  [ "$output" = 19oct-redi-general ]
  grep -q "^tmux new-session -d -s 19oct-redi-general -c $DM_PROJECTS_DIR/redi '.*claude' --resume $SID2\$" "$STUB_LOG"
}

@test "_claude_resume: the name is made unique and an explicit cwd wins" {
  mkdir -p "$HOME/elsewhere"
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" "notes"
  STUB_TMUX_HAS="notes notes-2" run dm_claude_resume "$SID2" "$HOME/elsewhere"
  [ "$output" = notes-3 ]
  grep -q "new-session -d -s notes-3 -c $HOME/elsewhere" "$STUB_LOG"
}

@test "_claude_resume: refuses a running session, an unknown one and bad input" {
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" "notes"
  live_session "$SID2" idle - /x notes
  run dm_claude_resume "$SID2"
  [ "$status" -ne 0 ]
  run dm_claude_resume "$SID3"
  [ "$status" -ne 0 ]
  run dm_claude_resume 'x;y'
  [ "$status" -ne 0 ]
  run dm_claude_resume "$SID3" /nonexistent
  [ "$status" -ne 0 ]
  ! grep -q new-session "$STUB_LOG"
}

@test "_claude_new: starts claude --name in the project, quoting the name" {
  run dm_claude_new "27Oct - it's \$(x)" proj:redi
  [ "$status" -eq 0 ]
  [ "$output" = 27oct-it-s-x ]
  grep -qF -- "-c $DM_PROJECTS_DIR/redi" "$STUB_LOG"
  grep -qF -- "--name '27Oct - it'\\''s \$(x)'" "$STUB_LOG"
}

@test "_claude_new: rejects bad names and folders" {
  run dm_claude_new '' proj:redi
  [ "$status" -ne 0 ]
  run dm_claude_new '-x' proj:redi
  [ "$status" -ne 0 ]
  run dm_claude_new ok 'proj:../etc'
  [ "$status" -ne 0 ]
  run dm_claude_new ok proj:nope
  [ "$status" -ne 0 ]
  run dm_claude_new ok redi
  [ "$status" -ne 0 ]
  ! grep -q new-session "$STUB_LOG"
}

# --- move helpers on the machine -----------------------------------------------------

@test "_claude_info: cwd, live flag, projects dir and git state" {
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" "t"
  git -C "$DM_PROJECTS_DIR/redi" init -q
  git -C "$DM_PROJECTS_DIR/redi" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  local head
  head=$(git -C "$DM_PROJECTS_DIR/redi" rev-parse HEAD)
  run dm_claude_info "$SID2"
  [ "$output" = "$DM_PROJECTS_DIR/redi${t}0${t}$DM_PROJECTS_DIR${t}1${t}clean${t}$head" ]
  touch "$DM_PROJECTS_DIR/redi/new.txt"
  run dm_claude_info "$SID2"
  [[ $output == *"${t}dirty${t}$head" ]]
  live_session "$SID2" idle - /x n
  run dm_claude_info "$SID2"
  [[ $output == "$DM_PROJECTS_DIR/redi${t}1${t}"* ]]
}

@test "_claude_probe: claude, projects dir, folder and git state; rejects odd folders" {
  run dm_claude_probe redi
  [ "$output" = "1${t}$DM_PROJECTS_DIR${t}1${t}none${t}-${t}0" ]
  run dm_claude_probe nope
  [ "$output" = "1${t}$DM_PROJECTS_DIR${t}0${t}none${t}-${t}0" ]
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" "t"
  run dm_claude_probe redi "$SID2"
  [[ $output == *"${t}1" ]]
  live_session "$SID3" idle - /x n3
  run dm_claude_probe redi "$SID3"
  [[ $output == *"${t}1" ]]
  run dm_claude_probe redi "$SID1"
  [[ $output == *"${t}0" ]]
  run dm_claude_probe redi bad
  [ "$status" -ne 0 ]
  run dm_claude_probe '../x'
  [ "$status" -ne 0 ]
  run dm_claude_probe 'a/../b'
  [ "$status" -ne 0 ]
}

@test "_claude_export and _claude_import move a transcript under the encoded cwd" {
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" "t"
  local src=$TRANSCRIPT
  run dm_claude_export "$SID2"
  [ "$status" -eq 0 ]
  dm_claude_export "$SID2" >"$BATS_TEST_TMPDIR/copy"
  rm -rf "$HOME/.claude/projects"
  mkdir -p "$DM_PROJECTS_DIR/deep/app"
  run dm_claude_import "$SID2" deep/app <"$BATS_TEST_TMPDIR/copy"
  [ "$status" -eq 0 ]
  [ "$output" = "$DM_PROJECTS_DIR/deep/app" ]
  cmp "$BATS_TEST_TMPDIR/copy" "$HOME/.claude/projects/${output//[^A-Za-z0-9]/-}/$SID2.jsonl"
  [ -e "$src" ] || true
  run dm_claude_import "$SID2" nope </dev/null
  [ "$status" -ne 0 ]
  run dm_claude_import "$SID2" deep/app </dev/null
  [ "$status" -ne 0 ]
}

@test "_claude_import: an existing session id with another history is refused and never overwritten" {
  mkdir -p "$DM_PROJECTS_DIR/deep"
  printf '{"a":1}\n' | dm_claude_import "$SID2" deep >/dev/null
  local f
  f=$(dm_claude_transcript "$SID2")
  run dm_claude_import "$SID2" deep <<<'{"b":2}'
  [ "$status" -ne 0 ]
  [ "$(cat "$f")" = '{"a":1}' ]
  [ -z "$(find "$(dirname "$f")" -name '.import.*')" ]
}

@test "_claude_import: a stale copy left by an earlier move is replaced by the longer history" {
  mkdir -p "$DM_PROJECTS_DIR/deep"
  printf '{"a":1}\n' | dm_claude_import "$SID2" deep >/dev/null
  run dm_claude_import "$SID2" deep <<<$'{"a":1}\n{"b":2}'
  [ "$status" -eq 0 ]
  [ "$(cat "$(dm_claude_transcript "$SID2")")" = $'{"a":1}\n{"b":2}' ]
  [ "$(find "$HOME/.claude/projects" -name "$SID2.jsonl" | wc -l | tr -d ' ')" = 1 ]
}

@test "_claude_import: a session running here is never replaced" {
  mkdir -p "$DM_PROJECTS_DIR/deep"
  live_session "$SID1" idle "deep:@1.%1" "$DM_PROJECTS_DIR/deep" 'x'
  run dm_claude_import "$SID1" deep <<<'{"a":1}'
  [ "$status" -ne 0 ]
}

@test "_claude_forget: removes this machine's copy, never one of a running session" {
  transcript "$SID2" "$DM_PROJECTS_DIR/redi" "t"
  run dm_claude_forget "$SID2"
  [ "$status" -eq 0 ]
  ! dm_claude_transcript "$SID2"
  live_session "$SID1" idle "redi:@1.%1" "$DM_PROJECTS_DIR/redi" 'x'
  transcript "$SID1" "$DM_PROJECTS_DIR/redi" "t"
  run dm_claude_forget "$SID1"
  [ "$status" -ne 0 ]
  dm_claude_transcript "$SID1"
}

@test "_claude_info and _claude_resume: a moved transcript uses this machine's project folder" {
  mkdir -p "$DM_PROJECTS_DIR/app"
  # Written by the other machine: its cwd, stored here under this machine's folder.
  printf '{"type":"user","cwd":"/home/other/code/app"}\n' |
    dm_claude_import "$SID2" app >/dev/null
  run dm_claude_info "$SID2"
  [ "$status" -eq 0 ]
  [ "$(cut -f1 <<<"$output")" = "$DM_PROJECTS_DIR/app" ]
  [ "$(cut -f4 <<<"$output")" = 1 ]
}

@test "_claude_import: only JSON object lines are kept, a non-JSON start is refused" {
  mkdir -p "$DM_PROJECTS_DIR/deep"
  run dm_claude_import "$SID2" deep <<<$'\n{"a":1}\nrm -rf /\n{"b":2}\n[1]'
  [ "$status" -eq 0 ]
  [ "$(cat "$(dm_claude_transcript "$SID2")")" = $'{"a":1}\n{"b":2}' ]
  run dm_claude_import "$SID3" deep <<<$'hello\n{"a":1}'
  [ "$status" -ne 0 ]
  [ -z "$(dm_claude_transcript "$SID3" || true)" ]
}

@test "_claude_import: a stream over the cap is refused" {
  mkdir -p "$DM_PROJECTS_DIR/deep"
  DM_CLAUDE_MAX_TRANSCRIPT=20
  run dm_claude_import "$SID2" deep <<<$'{"a":1}\n{"b":2}\n{"c":3}'
  [ "$status" -ne 0 ]
  [[ $output == *"too big"* ]]
  [ -z "$(dm_claude_transcript "$SID2" || true)" ]
}

# --- _feed records -------------------------------------------------------------------

@test "_feed: C, H and K records per machine, after the machine's terminals" {
  ssh_reply lap "dm _claude" "X${t}1"$'\n'"L${t}$SID1${t}busy${t}30${t}redi:@3.%7${t}412${t}/home/dev/PROJECTS/redi${t}19Oct - redi"$'\n'"H${t}$SID2${t}86400${t}/home/dev/PROJECTS/api${t}20Oct - api"$'\n'
  ssh_reply pc2 "dm _claude" "X${t}0"$'\n'
  run dm_feed
  [ "$status" -eq 0 ]
  [[ $output == *$'\n'"K${t}lap${t}1"$'\n'* ]]
  [[ $output == *$'\n'"C${t}lap${t}$SID1${t}busy${t}30${t}redi:@3.%7${t}412${t}/home/dev/PROJECTS/redi${t}19Oct - redi"$'\n'* ]]
  [[ $output == *$'\n'"H${t}lap${t}$SID2${t}86400${t}/home/dev/PROJECTS/api${t}20Oct - api"* ]]
  [[ $output == *$'\n'"K${t}pc2${t}0"* ]]
}

@test "_feed: an old remote, an offline machine and garbage give no Claude records and no error" {
  ssh_reply pc2 "dm _claude" $'L\tnot-a-uuid\tbusy\t1\t-\t1\t/x\tn\nC\tx\nH\t'"$SID2"$'\tabc\t/x\tn\nL\t'"$SID1"$'\tbusy\t1\tevil;cmd\t1\t/x\tn\nH\t'"$SID2"$'\t5\trelative\tn\nX\t7\n'
  STUB_SSH_DOWN="lap lap-b" run dm_feed
  [ "$status" -eq 0 ]
  [ -z "$(grep -E '^[CHK]' <<<"$output")" ]
}

@test "_feed: names keep their words, control characters are dropped" {
  ssh_reply lap "dm _claude" "L${t}$SID1${t}idle${t}5${t}-${t}1${t}/x${t}two${t}words"$'\x01'"here"$'\n'
  run dm_feed
  [[ $output == *"${t}/x${t}two words"*"here" ]]
  [[ $output != *$'\x01'* ]]
}

# --- controller actions --------------------------------------------------------------

@test "_cstop: runs _claude_stop on the machine and prints nothing" {
  run dm_claude_cstop lap "$SID1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q "^ssh .*lap dm _claude_stop $SID1\$" "$STUB_LOG"
}

@test "_cstop, _cresume, _cnew: validate machine, id, name and folder before any ssh" {
  : >"$STUB_LOG"
  run dm_claude_cstop 'lap;x' "$SID1"
  [ "$status" -ne 0 ] && [[ $output == *"not available"* ]]
  run dm_claude_cstop nosuch "$SID1"
  [ "$status" -ne 0 ]
  run dm_claude_cstop lap 'x y'
  [ "$status" -ne 0 ] && [[ $output == *"Invalid session"* ]]
  run dm_claude_cresume lap '../x'
  [ "$status" -ne 0 ]
  run dm_claude_cnew lap '' proj:redi
  [ "$status" -ne 0 ]
  run dm_claude_cnew lap name 'proj:../x'
  [ "$status" -ne 0 ]
  run dm_claude_cnew lap name redi
  [ "$status" -ne 0 ]
  ! grep -q '^ssh .*dm _claude' "$STUB_LOG"
}

@test "_cresume: prints the tmux session name the machine answers, and nothing else" {
  ssh_reply lap "dm _claude_resume $SID1" $'my-session\n'
  run dm_claude_cresume lap "$SID1"
  [ "$status" -eq 0 ]
  [ "$output" = my-session ]
  ssh_reply lap "dm _claude_resume $SID1" $'bad name; rm\n'
  run dm_claude_cresume lap "$SID1"
  [ "$status" -ne 0 ]
  [[ $output == *"Could not complete"* ]]
}

@test "_cnew: sends the cleaned name and project, prints the session" {
  ssh_reply lap "dm _claude_new 27Oct_-_redi proj:redi" $'27oct-redi\n'
  run dm_claude_cnew lap "27Oct_-_redi"$'\t' proj:redi
  [ "$status" -eq 0 ]
  [ "$output" = 27oct-redi ]
}

@test "_cstop and _cresume are wired in the dm command" {
  run "$REPO/client/bin/dm" _cstop lap bad
  [ "$status" -ne 0 ]
  [[ $output == *"Invalid session"* ]]
  run "$REPO/client/bin/dm" _cmove lap "$SID1" lap
  [ "$status" -ne 0 ]
  [[ $output == *"different machine"* ]]
}

# --- _cmove --------------------------------------------------------------------------

# move_replies SRC_GIT SRC_HEAD DST_HAS DST_EXISTS DST_GIT DST_HEAD [LIVE]
move_replies() {
  ssh_reply lap "dm _claude_info $SID1" "/home/dev/PROJECTS/redi${t}${7:-0}${t}/home/dev/PROJECTS${t}1${t}$1${t}$2"$'\n'
  ssh_reply pc2 "dm _claude_probe redi $SID1" "$3${t}/srv/PROJECTS${t}$4${t}$5${t}$6${t}${8:-0}"$'\n'
  ssh_reply lap "dm _claude_export $SID1" $'{"type":"user"}\n'
  ssh_reply pc2 "dm _claude_import $SID1 redi" $'/srv/PROJECTS/redi\n'
  ssh_reply pc2 "dm _claude_resume $SID1 /srv/PROJECTS/redi" $'redi-sess\n'
}

@test "_cmove: stops on the source when live, copies the transcript, resumes on the destination" {
  move_replies clean abc 1 1 clean abc 1
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -eq 0 ]
  [ "$output" = redi-sess ]
  local stop export import resume
  stop=$(grep -n "lap dm _claude_stop $SID1" "$STUB_LOG" | head -1 | cut -d: -f1)
  export=$(grep -n "lap dm _claude_export" "$STUB_LOG" | head -1 | cut -d: -f1)
  import=$(grep -n "pc2 dm _claude_import" "$STUB_LOG" | head -1 | cut -d: -f1)
  resume=$(grep -n "pc2 dm _claude_resume" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ "$stop" -lt "$export" ] && [ "$export" -lt "$import" ] && [ "$import" -lt "$resume" ]
  # A move, not a copy: the source forgets its transcript once the destination runs it.
  local forget
  forget=$(grep -n "lap dm _claude_forget $SID1" "$STUB_LOG" | head -1 | cut -d: -f1)
  [ -n "$forget" ] && [ "$resume" -lt "$forget" ]
}

@test "_cmove: a stopped session is not stopped again; folders that are not git repos are fine" {
  move_replies none - 1 1 none -
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -eq 0 ]
  ! grep -q "_claude_stop" "$STUB_LOG"
}

@test "_cmove: refuses when the destination has no Claude or no such folder" {
  move_replies clean abc 0 1 clean abc
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -ne 0 ] && [[ $output == *"pc2 does not have Claude"* ]]
  move_replies clean abc 1 0 none -
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -ne 0 ] && [[ $output == *"The folder redi does not exist on pc2"* ]]
  ! grep -q "_claude_import\|_claude_resume\|_claude_stop" "$STUB_LOG"
}

@test "_cmove: refuses a session outside the projects folder" {
  ssh_reply lap "dm _claude_info $SID1" "/srv/other/app${t}0${t}/home/dev/PROJECTS${t}1${t}none${t}-"$'\n'
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -ne 0 ] && [[ $output == *"outside the projects folder"* ]]
  ssh_reply lap "dm _claude_info $SID1" "/home/dev/PROJECTS/../x${t}0${t}/home/dev/PROJECTS${t}1${t}none${t}-"$'\n'
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -ne 0 ]
}

@test "_cmove: refuses uncommitted changes and a different HEAD, nothing is stopped or copied" {
  move_replies dirty abc 1 1 clean abc 1
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -ne 0 ] && [[ $output == *"uncommitted changes on lap"*"pull on pc2"* ]]
  move_replies clean abc 1 1 clean def 1
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -ne 0 ] && [[ $output == *"not up to date"*"pull on pc2"* ]]
  ! grep -q "_claude_import\|_claude_resume\|_claude_stop" "$STUB_LOG"
}

@test "the move refusals exist in Spanish and English with the same placeholders" {
  run env DM_LANG=es DM_SHARE="$REPO/client" bash -c 'source "$1/client/lib/dm_core.sh"; printf "$M_CLAUDE_DIRTY" lap pc2' _ "$REPO"
  [ "$output" = "Hay cambios sin commit en lap: haz commit y push, y en pc2 haz pull." ]
  run env DM_LANG=es DM_SHARE="$REPO/client" bash -c 'source "$1/client/lib/dm_core.sh"; printf "$M_CLAUDE_NO_CLAUDE" pc2' _ "$REPO"
  [ "$output" = "pc2 no tiene Claude." ]
}

@test "_cmove: same machine, unknown machine and bad ids are refused" {
  run dm_claude_cmove lap "$SID1" lap
  [ "$status" -ne 0 ]
  run dm_claude_cmove lap "$SID1" 'x;y'
  [ "$status" -ne 0 ]
  run dm_claude_cmove lap bad pc2
  [ "$status" -ne 0 ]
}

@test "_cmove: refuses when the destination already has that session, nothing is stopped or copied" {
  move_replies clean abc 1 1 clean abc 1 1
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -ne 0 ] && [[ $output == *"already exists on pc2"* ]]
  ! grep -q "_claude_import\|_claude_resume\|_claude_stop" "$STUB_LOG"
}

@test "_cmove: a transcript over the cap is refused before the import" {
  move_replies clean abc 1 1 clean abc
  DM_CLAUDE_MAX_TRANSCRIPT=5
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -ne 0 ] && [[ $output == *"too big"* ]]
  ! grep -q "_claude_import\|_claude_resume" "$STUB_LOG"
}

@test "_cmove: a destination cwd with shell metacharacters is refused" {
  move_replies clean abc 1 1 clean abc
  ssh_reply pc2 "dm _claude_import $SID1 redi" $'/srv/x;touch /tmp/p\n'
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -ne 0 ]
  ! grep -q "_claude_resume" "$STUB_LOG"
}

@test "_cmove: a failed copy stops before resuming" {
  move_replies clean abc 1 1 clean abc
  rm "$STUB_SSH_DIR/lap/dm__claude_export_$SID1"
  run dm_claude_cmove lap "$SID1" pc2
  [ "$status" -ne 0 ] && [[ $output == *"Could not complete"* ]]
  ! grep -q "_claude_resume" "$STUB_LOG"
}
