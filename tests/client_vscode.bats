#!/usr/bin/env bats
# dm vscode: settings.json profile on/off/status (temp HOME), _vscode-shell session naming.

load helpers

setup() {
  export DM_LANG=en
  setup_client
  export DM_SELF="$REPO/client/bin/dm"
  export STUB_TMUX_HAS=""
  plat macos
  mkdir -p "$HOME/.config/devmesh"
  printf 'DM_KIND=machine\n' >"$HOME/.config/devmesh/node.conf"
  APP="$HOME/Library/Application Support/Code/User"
  mkdir -p "$APP"
  SETTINGS="$APP/settings.json"
}

# plat NAME — pretend to run on that platform (keeps the test independent of the host).
plat() {
  eval "dm_platform() { printf '%s\\n' $1; }"
}

# pyjson FILE — the parsed settings as canonical JSON, for comparisons.
pyjson() {
  python3 -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), sort_keys=True))' "$1"
}

# jget FILE KEY — one top-level value (None = JSON null, <absent> = no such key).
jget() {
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(d.get(sys.argv[2], "<absent>"))' "$1" "$2"
}

# state_of FILE — the status word printed for FILE in $output.
state_of() { awk -v p="$1" 'index($0, p) { print $1; exit }' <<<"$output"; }

write_settings() { printf '%s' "$1" >"$SETTINGS"; }

@test "on, then off, restores the original file byte for byte (no previous default)" {
  write_settings $'{\n  "editor.fontSize": 14\n}\n'
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/orig.json"
  run dm_vscode on
  [ "$status" -eq 0 ]
  [ "$(jget "$SETTINGS" terminal.integrated.defaultProfile.osx)" = devmesh ]
  [ "$(jget "$SETTINGS" devmesh.previousDefaultProfile)" = None ]
  cmp "$SETTINGS.devmesh-bak" "$BATS_TEST_TMPDIR/orig.json"
  run dm_vscode off
  [ "$status" -eq 0 ]
  cmp "$SETTINGS" "$BATS_TEST_TMPDIR/orig.json"
}

@test "off keeps the user's own profiles and settings" {
  write_settings $'{\n  "editor.fontSize": 14,\n  "terminal.integrated.profiles.osx": {\n    "bash": {\n      "path": "bash"\n    }\n  }\n}\n'
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/orig.json"
  dm_vscode on >/dev/null
  run dm_vscode off
  [ "$status" -eq 0 ]
  [ "$(pyjson "$SETTINGS")" = "$(pyjson "$BATS_TEST_TMPDIR/orig.json")" ]
}

@test "a previous default is preserved on on and restored on off" {
  write_settings $'{\n  "terminal.integrated.defaultProfile.osx": "zsh"\n}\n'
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/orig.json"
  run dm_vscode on
  [ "$status" -eq 0 ]
  [ "$(jget "$SETTINGS" terminal.integrated.defaultProfile.osx)" = devmesh ]
  [ "$(jget "$SETTINGS" devmesh.previousDefaultProfile)" = zsh ]
  run dm_vscode off
  [ "$status" -eq 0 ]
  [ "$(pyjson "$SETTINGS")" = "$(pyjson "$BATS_TEST_TMPDIR/orig.json")" ]
  [ "$(jget "$SETTINGS" terminal.integrated.defaultProfile.osx)" = zsh ]
}

@test "a settings file with comments is not modified: snippet printed, non-zero" {
  write_settings $'{\n  // my editor\n  "editor.fontSize": 14,\n}\n'
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/before.json"
  run dm_vscode on
  [ "$status" -ne 0 ]
  cmp "$SETTINGS" "$BATS_TEST_TMPDIR/before.json"
  [[ $output == *'"terminal.integrated.defaultProfile.osx": "devmesh"'* ]]
  [[ $output == *'"args": ["_vscode-shell"]'* ]]
  [ ! -e "$SETTINGS.devmesh-bak" ]
}

@test "on is idempotent and the backup keeps the first original" {
  write_settings $'{\n  "terminal.integrated.defaultProfile.osx": "zsh"\n}\n'
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/orig.json"
  dm_vscode on >/dev/null
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/once.json"
  run dm_vscode on
  [ "$status" -eq 0 ]
  [[ $output == *"already on"* ]]
  cmp "$SETTINGS" "$BATS_TEST_TMPDIR/once.json"
  cmp "$SETTINGS.devmesh-bak" "$BATS_TEST_TMPDIR/orig.json"
}

@test "status reports on, off, not-json and missing per settings file" {
  mkdir -p "$HOME/Library/Application Support/Cursor"
  write_settings '{}'
  run dm_vscode status
  [ "$(state_of "$SETTINGS")" = off ]
  [ "$(state_of "$HOME/Library/Application Support/Cursor/User/settings.json")" = missing ]
  dm_vscode on >/dev/null
  run dm_vscode status
  [ "$(state_of "$SETTINGS")" = on ]
  write_settings '// broken'
  run dm_vscode status
  [ "$(state_of "$SETTINGS")" = not-json ]
}

@test "on writes a new settings file when the app folder exists without one" {
  rm -f "$SETTINGS"
  run dm_vscode on
  [ "$status" -eq 0 ]
  [ "$(jget "$SETTINGS" terminal.integrated.defaultProfile.osx)" = devmesh ]
  [ ! -e "$SETTINGS.devmesh-bak" ]
}

@test "linux uses the Linux app folders and the linux profile keys" {
  plat linux
  mkdir -p "$HOME/.config/Code/User"
  printf '{}\n' >"$HOME/.config/Code/User/settings.json"
  run dm_vscode on
  [ "$status" -eq 0 ]
  [ "$(jget "$HOME/.config/Code/User/settings.json" terminal.integrated.defaultProfile.linux)" = devmesh ]
}

@test "machines only: a phone is refused and its settings are not touched" {
  [ ! -r /etc/devmesh/node.conf ] || skip "this host has /etc/devmesh/node.conf"
  printf 'DM_KIND=phone\n' >"$HOME/.config/devmesh/node.conf"
  write_settings '{}'
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/before.json"
  run dm_vscode status
  [ "$status" -ne 0 ]
  [[ $output == *"machines only"* ]]
  run dm_vscode on
  [ "$status" -ne 0 ]
  cmp "$SETTINGS" "$BATS_TEST_TMPDIR/before.json"
}

@test "_vscode-shell names the session after the folder" {
  local dir=$BATS_TEST_TMPDIR/PROJECTS/My.App
  mkdir -p "$dir"
  cd "$dir"
  unset TMUX
  run dm_vscode_shell
  [ "$status" -eq 0 ]
  grep -qF "tmux new-session -d -s my-app -c $dir" "$STUB_LOG"
  grep -qF "tmux -u attach-session -t my-app" "$STUB_LOG"
  grep -qF 'set-option -t my-app @origin vscode' "$STUB_LOG"
}

@test "_vscode-shell picks <proj>-2 when <proj> exists" {
  local dir=$BATS_TEST_TMPDIR/work/shop
  mkdir -p "$dir"
  cd "$dir"
  unset TMUX
  export STUB_TMUX_HAS="shop"
  run dm_vscode_shell
  [ "$status" -eq 0 ]
  grep -qF "tmux new-session -d -s shop-2 -c $dir" "$STUB_LOG"
  grep -qF "tmux -u attach-session -t shop-2" "$STUB_LOG"
  run grep -qx "tmux -u attach-session -t shop" "$STUB_LOG"
  [ "$status" -ne 0 ]
  export STUB_TMUX_HAS="shop shop-2"
  run dm_vscode_shell
  grep -qF "tmux new-session -d -s shop-3 -c $dir" "$STUB_LOG"
}

@test "_vscode-shell falls back to the login shell inside tmux" {
  printf '#!/bin/sh\necho "login:$*"\n' >"$BATS_TEST_TMPDIR/fakeshell"
  chmod +x "$BATS_TEST_TMPDIR/fakeshell"
  export SHELL="$BATS_TEST_TMPDIR/fakeshell" TMUX=/tmp/tmux-1/default,1,0
  run dm_vscode_shell
  [ "$output" = "login:-l" ]
  run grep -q new-session "$STUB_LOG"
  [ "$status" -ne 0 ]
}
