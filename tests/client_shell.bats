#!/usr/bin/env bats
# Shell integration (client/shell/devmesh.sh): after Claude ends, its resume line is offered.

bats_require_minimum_version 1.5.0
load helpers

SID=3e59d040-ff2b-4c82-84c7-d990f19890f2

setup() {
  setup_client
  export TMUX=/tmp/stub,1,0 TMUX_PANE=%5 STUB_TMUX_SCREEN="$BATS_TEST_TMPDIR/screen"
}

# offer LAST_CMD: run devmesh_resume_line in an interactive bash; prints the offered line.
offer() {
  bash --norc --noprofile -i -c ". \"$REPO/client/shell/devmesh.sh\"; DEVMESH_LAST_CMD='$1'
    devmesh_resume_line && printf '%s\n' \"\$DEVMESH_RESUME\"" 2>/dev/null
}

@test "shell: the newest resume line Claude printed is offered after a claude command" {
  printf 'Resume this session with:\nclaude --resume 11111111-1111-4111-8111-111111111111\n...\nResume this session with:\nclaude --resume %s\n' "$SID" >"$STUB_TMUX_SCREEN"
  run offer claude
  [ "$output" = "claude --resume $SID" ]
}

@test "shell: Claude's cd line is kept; anything else on the screen never reaches the prompt" {
  printf ' cd /Users/me/PROJECTS/EBBINER && claude --resume %s\n' "$SID" >"$STUB_TMUX_SCREEN"
  run offer claude
  [ "$output" = "cd /Users/me/PROJECTS/EBBINER && claude --resume $SID" ]
  printf 'x; rm -rf ~ && claude --resume %s; reboot\n' "$SID" >"$STUB_TMUX_SCREEN"
  run offer claude
  [ "$output" = "claude --resume $SID" ]
}

@test "shell: nothing is offered after other commands or without a resume line" {
  printf 'claude --resume %s\n' "$SID" >"$STUB_TMUX_SCREEN"
  run offer 'ls -la'
  [ -z "$output" ]
  printf 'just text\n' >"$STUB_TMUX_SCREEN"
  run offer claude
  [ -z "$output" ]
}
