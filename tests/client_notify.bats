#!/usr/bin/env bats
# dm notify: Claude Code's Notification hook pushes "Claude needs you" through the hub.

load helpers

setup() {
  setup_client
  export DM_SELF=/opt/devmesh/bin/dm
  SETTINGS="$HOME/.claude/settings.json"
}

@test "hook: a permission prompt is sent as perm for the session's project" {
  printf '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}' |
    CLAUDE_PROJECT_DIR="/home/me/PROJECTS/My Shop" dm_notify_hook
  grep -q '^ssh .*hub-admin notify claude my-shop perm$' "$STUB_LOG"
}

@test "hook: an idle prompt is sent as wait, from the current folder without CLAUDE_PROJECT_DIR" {
  mkdir -p "$BATS_TEST_TMPDIR/redi"
  cd "$BATS_TEST_TMPDIR/redi"
  printf '{"hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}' |
    CLAUDE_PROJECT_DIR='' dm_notify_hook
  grep -q '^ssh .*hub-admin notify claude redi wait$' "$STUB_LOG"
}

@test "hook: never fails Claude, even when the hub is unreachable" {
  printf '{}' | STUB_SSH_DOWN=hub-admin CLAUDE_PROJECT_DIR=/x/redi dm_notify_hook
}

@test "on: adds the hook next to the user's own hooks, once; off removes only it" {
  mkdir -p "$HOME/.claude"
  cat >"$SETTINGS" <<'EOF'
{"theme": "dark", "hooks": {"Notification": [{"hooks": [{"type": "command", "command": "say hi"}]}], "Stop": [{"hooks": [{"type": "command", "command": "x"}]}]}}
EOF
  run dm_notify on
  [ "$status" -eq 0 ]
  run dm_notify on
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["hooks"]["Notification"]))' "$SETTINGS"
  [ "$output" = '[{"hooks": [{"type": "command", "command": "say hi"}]}, {"hooks": [{"type": "command", "command": "/opt/devmesh/bin/dm _notify", "timeout": 10}]}]' ]
  run dm_notify status
  [[ $output == on* ]]
  run dm_notify off
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["theme"], json.dumps(d["hooks"]))' "$SETTINGS"
  [ "$output" = 'dark {"Notification": [{"hooks": [{"type": "command", "command": "say hi"}]}], "Stop": [{"hooks": [{"type": "command", "command": "x"}]}]}' ]
  run dm_notify status
  [[ $output == off* ]]
}

@test "on: creates the settings file when Claude has none yet" {
  run dm_notify on
  [ "$status" -eq 0 ]
  grep -q '"command": "/opt/devmesh/bin/dm _notify"' "$SETTINGS"
}

@test "on: a settings file that is not plain JSON is left untouched" {
  mkdir -p "$HOME/.claude"
  printf '{ // comment\n}\n' >"$SETTINGS"
  run dm_notify on
  [ "$status" -ne 0 ]
  [ "$(cat "$SETTINGS")" = "$(printf '{ // comment\n}')" ]
}
