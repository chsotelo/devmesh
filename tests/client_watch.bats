#!/usr/bin/env bats
# dm watch: machine-side _watch/_key, the phone's notification and the on/off lifecycle.

load helpers

setup() {
  export DM_LANG=en
  setup_client
  export STUB_TMUX_DISPLAY="$BATS_TEST_TMPDIR/display" STUB_TMUX_PANES="$BATS_TEST_TMPDIR/panes"
  export DM_WATCH_INTERVAL=0
  plat linux
}

# plat NAME — pretend to run on that platform (never touch the real notification centre).
plat() {
  eval "dm_platform() { printf '%s\\n' $1; }"
}

set_pane_state() { printf 'waiting\t%s\n' "$1" | sed 's/\t/|~|/' >"$STUB_TMUX_DISPLAY"; }

@test "_key sends an allowed key to the pane that is still waiting" {
  set_pane_state 1700000000
  run dm_remote_key %7 1700000000 1
  [ "$status" -eq 0 ]
  [ "$output" = sent ]
  grep -qx 'tmux send-keys -t %7 1' "$STUB_LOG"
}

@test "_key accepts Escape and Enter" {
  set_pane_state 5
  run dm_remote_key %7 5 Escape
  [ "$output" = sent ]
  run dm_remote_key %7 5 Enter
  [ "$output" = sent ]
}

@test "_key rejects keys outside the allowlist" {
  set_pane_state 5
  for k in 4 y 'C-c' 'rm -rf' '' '1;2'; do
    run dm_remote_key %7 5 "$k"
    [ "$status" -eq 2 ]
  done
  ! grep -q send-keys "$STUB_LOG"
}

@test "_key rejects malformed pane ids and since values" {
  set_pane_state 5
  for p in 7 '%' '%a' '%7;x' '$(id)' ''; do
    run dm_remote_key "$p" 5 1
    [ "$status" -eq 2 ]
  done
  for s in x '' '5;1' -1; do
    run dm_remote_key %7 "$s" 1
    [ "$status" -eq 2 ]
  done
  ! grep -q send-keys "$STUB_LOG"
}

@test "_key answers stale when the pane is not waiting" {
  printf 'working|~|5\n' >"$STUB_TMUX_DISPLAY"
  run dm_remote_key %7 5 1
  [ "$status" -eq 3 ]
  [ "$output" = stale ]
  ! grep -q send-keys "$STUB_LOG"
}

@test "_key answers stale when since differs (an old notification)" {
  set_pane_state 6
  run dm_remote_key %7 5 1
  [ "$status" -eq 3 ]
  [ "$output" = stale ]
  ! grep -q send-keys "$STUB_LOG"
}

@test "agent records @agent_since and clears it" {
  TMUX_PANE=%3 dm_agent waiting
  grep -qE '^tmux set-option -p -t %3 @agent waiting$' "$STUB_LOG"
  grep -qE '^tmux set-option -p -t %3 @agent_since [0-9]+$' "$STUB_LOG"
  TMUX_PANE=%3 dm_agent clear
  grep -qx 'tmux set-option -p -u -t %3 @agent_since' "$STUB_LOG"
}

@test "_watch prints one line per change and nothing when unchanged" {
  printf 'main|~|0|~|%%1|~|working|~|100|~|t1\nmain|~|1|~|%%2|~||~||~|shell\n' >"$STUB_TMUX_PANES.1"
  printf 'main|~|0|~|%%1|~|working|~|100|~|t1\n' >"$STUB_TMUX_PANES.2"
  printf 'main|~|0|~|%%1|~|waiting|~|105|~|ask\\there\n' >"$STUB_TMUX_PANES.3"
  DM_WATCH_ITERATIONS=3 run dm_remote_watch
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "$(printf 'main\t0\t%%1\tworking\t100\tt1')" ]
  [ "${lines[1]}" = "$(printf 'main\t0\t%%1\twaiting\t105\task\\there')" ]
}

@test "_watch sanitizes titles: no control characters, 80 chars max" {
  long=$(printf 'x%.0s' {1..120})
  printf 'main|~|0|~|%%1|~|waiting|~|9|~|a\x01b\x1b[31m%s\n' "$long" >"$STUB_TMUX_PANES"
  DM_WATCH_ITERATIONS=1 run dm_remote_watch
  title=$(printf '%s' "$output" | cut -f6)
  [ "${#title}" -eq 80 ]
  [[ $title != *$'\x01'* && $title != *$'\x1b'* ]]
  [ "$(printf '%s' "$output" | awk -F'\t' '{print NF}')" -eq 6 ]
}

@test "notification buttons carry only validated fields, never the title" {
  plat termux
  evil='$(touch pwned) "q" '"'"'s'"'"'; `id`'
  dm_watch_handle lap "$(printf 'main\t0\t%%4\twaiting\t1700000000\t%s' "$evil")"
  grep -qx 'arg:lap: main needs you' "$STUB_LOG"
  grep -qx 'arg:--button1-action' "$STUB_LOG"
  grep -qE '^arg:.* _notify-act lap %4 1700000000 1$' "$STUB_LOG"
  grep -qE '^arg:.* _notify-act lap %4 1700000000 Escape$' "$STUB_LOG"
  grep -qE '^arg:.* go lap main$' "$STUB_LOG"
  # The title is a plain --content argument and appears in no *-action argument.
  grep -qxF "arg:$evil" "$STUB_LOG"
  ! grep -E '^arg:.*(touch|pwned|`|\$\()' "$STUB_LOG" | grep -vxF "arg:$evil"
  [ ! -e pwned ]
}

@test "events with invalid fields or other states raise no notification" {
  plat termux
  dm_watch_handle lap "$(printf 'main\t0\t%%4\tworking\t5\tx')"
  dm_watch_handle lap "$(printf 'ma;in\t0\t%%4\twaiting\t5\tx')"
  dm_watch_handle lap "$(printf 'main\t0\t4;id\twaiting\t5\tx')"
  dm_watch_handle lap "$(printf 'main\t0\t%%4\twaiting\t5x\tx')"
  ! grep -q termux-notification "$STUB_LOG"
}

@test "without Termux the notification goes to stderr" {
  run dm_watch_notify lap main 0 %4 5 "needs a yes"
  [ "$status" -eq 0 ]
  [[ $output == *"lap: main needs you"*"needs a yes"* ]]
}

@test "_notify-act runs _key on the machine and toasts the result" {
  plat termux
  ssh_reply lap "dm _key %4 5 1" $'sent\n'
  dm_watch_act lap %4 5 1
  grep -qx 'ssh -o BatchMode=yes -o ConnectTimeout=4 lap dm _key %4 5 1' "$STUB_LOG"
  grep -qx 'termux-toast sent' "$STUB_LOG"
  ssh_reply lap "dm _key %4 5 Escape" $'stale\n'
  dm_watch_act lap %4 5 Escape
  grep -q 'termux-toast too late' "$STUB_LOG"
}

@test "_notify-act refuses bad machine names, panes and keys" {
  for args in "La;p %4 5 1" "lap 4 5 1" "lap %4 x 1" "lap %4 5 y"; do
    run dm_watch_act $args
    [ "$status" -ne 0 ]
  done
  ! grep -q '_key' "$STUB_LOG"
}

@test "a reader turns machine output into notifications" {
  plat termux
  ssh_reply lap "dm _watch" "$(printf 'main\t0\t%%4\twaiting\t77\tok?')"$'\n'
  DM_WATCH_MAX_CONNECTS=1 dm_watch_reader lap
  grep -qE '^arg:.* _notify-act lap %4 77 1$' "$STUB_LOG"
}

@test "watch status, off and on follow the pidfile" {
  run dm_watch status
  [ "$output" = stopped ]
  sleep 30 &
  pid=$!
  printf '%s\n' "$pid" >"$(dm_watch_pidfile)"
  run dm_watch status
  [ "$output" = running ]
  run dm_watch off
  [ "$status" -eq 0 ]
  [ ! -e "$(dm_watch_pidfile)" ]
  ! kill -0 "$pid" 2>/dev/null
  run dm_watch status
  [ "$output" = stopped ]
}

@test "watch on starts the runner detached and records its pid" {
  printf '#!/usr/bin/env bash\nsleep 30\n' >"$BATS_TEST_TMPDIR/fakedm"
  chmod +x "$BATS_TEST_TMPDIR/fakedm"
  export DM_SELF="$BATS_TEST_TMPDIR/fakedm"
  dm_watch on 2>/dev/null
  dm_watch_running
  [ "$(dm_watch status)" = running ]
  dm_watch off 2>/dev/null
  [ "$(dm_watch status)" = stopped ]
}

@test "watch rejects unknown subcommands" {
  run dm_watch bogus
  [ "$status" -ne 0 ]
}
