#!/usr/bin/env bats
# Shell integration (client/shell/devmesh.sh): interactive shells get the "m" shortcut, and
# nothing else happens (no tmux autostart: Herdr owns shared terminals).

bats_require_minimum_version 1.5.0
load helpers

@test "shell: interactive shells get m = dm go and start no tmux" {
  run bash --norc --noprofile -i -c ". \"$REPO/client/shell/devmesh.sh\"; alias m" 2>/dev/null
  [[ $output == *"dm go"* ]]
  run env -u TMUX bash --norc --noprofile -i -c ". \"$REPO/client/shell/devmesh.sh\"; echo \${TMUX:-none}" 2>/dev/null
  [[ $output == *none* ]]
}

@test "shell: a non-interactive shell sourcing it gets nothing" {
  run bash --norc --noprofile -c ". \"$REPO/client/shell/devmesh.sh\"; alias m"
  [ "$status" -ne 0 ]
}
