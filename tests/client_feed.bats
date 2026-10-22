#!/usr/bin/env bats
# dm feed: the machine-readable commands behind the Go panel (_feed, _shot, _proj, _i18n, _new)
# and the launcher that decides between dm-tui and the fzf panel.

load helpers

setup() {
  export DM_LANG=en
  setup_client
  dm_share_dir() { printf '%s\n' "$DM_SHARE"; }
  t=$'\t'
}

@test "_feed: version line, one M line per machine and a 12-field T line per terminal" {
  ssh_reply lap "dm _who" "redi${t}1${t}redi:claude${t}1${t}claude${t}waiting${t}tablet${t}1700000000${t}1700000100${t}tablet"$'\n'
  STUB_SSH_DOWN="pc2 pc2-b" run dm_feed
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "V${t}dev${t}tablet" ]
  [ "${lines[1]}" = "M${t}lap${t}OK${t}22${t}10.73.0.2${t}home${t}mac" ]
  [ "${lines[2]}" = "T${t}lap${t}redi${t}1${t}redi:claude${t}1${t}claude${t}waiting${t}tablet${t}1700000000${t}1700000100${t}tablet" ]
  [ "${lines[3]}" = "M${t}pc2${t}OFFLINE${t}24${t}10.73.0.3${t}home${t}-" ]
  [ "${#lines[@]}" -eq 4 ]
  [ "$(awk -F'\t' '$1 == "T" {print NF}' <<<"$output")" = 12 ]
}

@test "_feed: a machine without terminals is EMPTY and the MAC address is not sent" {
  run dm_feed
  [ "$status" -eq 0 ]
  [[ $output == *"M${t}lap${t}EMPTY${t}22${t}10.73.0.2${t}home${t}mac"* ]]
  [[ $output != *aa:bb:cc* ]]
}

@test "_feed: with no machines it prints only the version line" {
  : >"$DM_CACHE/hosts.tsv"
  printf 'tablet\tphone\t10.73.0.4\t-\t-\t-\t-\t-\n' >"$DM_CACHE/hosts.tsv"
  run dm_feed
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ ${lines[0]} == V* ]]
}

@test "_feed is wired in the dm command" {
  ssh_reply lap "dm _who" "redi${t}1${t}redi:claude${t}1${t}claude${t}-${t}tablet${t}1${t}2${t}-"$'\n'
  run "$REPO/client/bin/dm" _feed
  [ "$status" -eq 0 ]
  [[ $output == *"T${t}lap${t}redi"* ]]
}

@test "_i18n: dumps the active catalog as KEY=VALUE, including the panel's own keys" {
  run dm_feed_i18n
  [ "$status" -eq 0 ]
  [[ $output == *"M_ACT_NEW=New terminal"* ]]
  [[ $output == *"M_TUI_WORD_OPEN=open"* ]]
  [[ $output != *M_I18N_LOADED* ]]
  [ -z "$(grep -vE '^M_[A-Z0-9_]+=' <<<"$output")" ]
}

@test "_i18n follows DM_LANG" {
  run env DM_LANG=es DM_SHARE="$REPO/client" bash -c 'source "$1/client/lib/dm_core.sh"; source "$1/client/lib/dm_feed.sh"; dm_feed_i18n' _ "$REPO"
  [ "$status" -eq 0 ]
  [[ $output == *"M_TUI_WORD_OPEN=abrir"* ]]
  [[ $output == *"M_ACT_NEW=Nueva terminal"* ]]
}

@test "_shot: asks the machine for the screen and rejects anything that is not a terminal" {
  ssh_reply lap "dm _capture redi 1" $'$ claude\n'
  run dm_feed_shot lap redi 1
  [ "$status" -eq 0 ]
  [ "$output" = '$ claude' ]
  run dm_feed_shot 'lap;x' redi 1
  [ "$status" -ne 0 ]
  run dm_feed_shot lap 'a b' 1
  [ "$status" -ne 0 ]
  run dm_feed_shot lap redi x
  [ "$status" -ne 0 ]
}

@test "_proj: plain folder names only" {
  ssh_reply lap "dm _projects" $'redi\nmy app\nx);touch /tmp/pwn\napi.v2\n'
  run dm_feed_projects lap
  [ "$status" -eq 0 ]
  [ "$output" = $'redi\napi.v2' ]
  run dm_feed_projects 'lap;x'
  [ "$status" -ne 0 ]
}

@test "_new --check: sanitizes the name like the fzf panel and prints the session" {
  run dm_feed_new --check lap "My API"
  [ "$status" -eq 0 ]
  [ "$output" = my-api ]
  run dm_feed_new --check lap redi proj:redi
  [ "$output" = redi ]
}

@test "_new: refuses an unknown machine, an empty or unusable name and a bad project" {
  run dm_feed_new --check nope web
  [ "$status" -ne 0 ]
  [[ $output == *"not available"* ]]
  run dm_feed_new --check 'lap;x' web
  [ "$status" -ne 0 ]
  run dm_feed_new --check lap ""
  [ "$status" -ne 0 ]
  [[ $output == *"type the terminal name"* ]]
  run dm_feed_new --check lap "---"
  [ "$status" -ne 0 ]
  [[ $output == *"Invalid name"* || $output == *"invalid name"* ]]
  run dm_feed_new --check lap web 'proj:../etc'
  [ "$status" -ne 0 ]
  run dm_feed_new --check lap web 'other:x'
  [ "$status" -ne 0 ]
}

@test "_new opens the terminal after validating (full screen outside the workspace)" {
  unset TMUX
  run dm_feed_new lap "My API" proj:redi
  [ "$status" -eq 0 ]
  grep -q 'dm _attach my-api proj:redi tablet' "$STUB_LOG"
}

@test "_new inside the workspace opens a tab" {
  TMUX=fake
  tmux() { printf 'tmux %s\n' "$*" >>"$STUB_LOG"; case $1 in new-window) echo @9 ;; esac; }
  dm_feed_new lap web
  grep -q '^tmux new-window -P -F #{window_id} -n lap:web ' "$STUB_LOG"
}

# --- launcher ---------------------------------------------------------------------------

fake_uname() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\ncase "$1" in -s) echo "%s" ;; -m) echo "%s" ;; esac\n' "$1" "$2" >"$BATS_TEST_TMPDIR/bin/uname"
  chmod +x "$BATS_TEST_TMPDIR/bin/uname"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "tui_target maps uname to Go's GOOS-GOARCH, Termux is android" {
  fake_uname Darwin arm64
  [ "$(tui_target)" = darwin-arm64 ]
  fake_uname Darwin x86_64
  [ "$(tui_target)" = darwin-amd64 ]
  fake_uname Linux x86_64
  [ "$(tui_target)" = linux-amd64 ]
  fake_uname Linux aarch64
  [ "$(tui_target)" = linux-arm64 ]
  TERMUX_VERSION=0.118 run tui_target
  [ "$output" = android-arm64 ]
  fake_uname Linux armv7l
  run tui_target
  [ "$status" -ne 0 ]
  fake_uname FreeBSD amd64
  run tui_target
  [ "$status" -ne 0 ]
}

make_tui() {
  mkdir -p "$DM_SHARE_TEST/bin"
  printf '#!/bin/sh\necho "tui $*" >>"%s"\nexit "${TUI_EXIT:-0}"\n' "$BATS_TEST_TMPDIR/tui.log" >"$DM_SHARE_TEST/bin/dm-tui-$1"
  chmod +x "$DM_SHARE_TEST/bin/dm-tui-$1"
}

@test "launcher: uses dm-tui-<os>-<arch> from the share dir" {
  fake_uname Linux x86_64
  DM_SHARE_TEST=$BATS_TEST_TMPDIR/share
  DM_SHARE=$DM_SHARE_TEST
  make_tui linux-amd64
  run dm_tui_bin
  [ "$status" -eq 0 ]
  [ "$output" = "$DM_SHARE_TEST/bin/dm-tui-linux-amd64" ]
}

@test "launcher: DM_TUI=0 forces the fzf panel" {
  fake_uname Linux x86_64
  DM_SHARE_TEST=$BATS_TEST_TMPDIR/share
  DM_SHARE=$DM_SHARE_TEST
  make_tui linux-amd64
  DM_TUI=0 run dm_tui_bin
  [ "$status" -ne 0 ]
}

@test "launcher: a binary for another OS/arch is ignored" {
  fake_uname Linux x86_64
  DM_SHARE_TEST=$BATS_TEST_TMPDIR/share
  DM_SHARE=$DM_SHARE_TEST
  make_tui darwin-arm64
  run dm_tui_bin
  [ "$status" -ne 0 ]
}

@test "launcher: falls back to dm-tui in PATH" {
  fake_uname Linux x86_64
  DM_SHARE=$BATS_TEST_TMPDIR/empty-share
  mkdir -p "$BATS_TEST_TMPDIR/pathbin"
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/pathbin/dm-tui"
  chmod +x "$BATS_TEST_TMPDIR/pathbin/dm-tui"
  PATH="$BATS_TEST_TMPDIR/pathbin:$PATH" run dm_tui_bin
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TEST_TMPDIR/pathbin/dm-tui" ]
}

@test "launcher: without a binary the panel falls back to fzf" {
  fake_uname Linux x86_64
  DM_SHARE=$BATS_TEST_TMPDIR/empty-share
  run env PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" bash -c 'type -P dm-tui'
  [ "$status" -ne 0 ]
  run dm_tui_bin
  [ "$status" -ne 0 ]
}

@test "launcher: dm_tui_launch needs a terminal, so a pipe always gets the fzf panel" {
  fake_uname Linux x86_64
  DM_SHARE_TEST=$BATS_TEST_TMPDIR/share
  DM_SHARE=$DM_SHARE_TEST
  make_tui linux-amd64
  run dm_tui_launch </dev/null
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/tui.log" ]
}

@test "dm_app_main starts dm-tui when the launcher succeeds and does not touch fzf" {
  dm_tui_launch() { return 0; }
  dm_ui_detect_cols() { echo fzf-path >>"$BATS_TEST_TMPDIR/fzf.log"; }
  run dm_app_main
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/fzf.log" ]
}

@test "dm_app_main keeps the fzf panel when dm-tui is not usable" {
  dm_tui_launch() { return 1; }
  dm_ui_detect_cols() { echo fzf-path >>"$BATS_TEST_TMPDIR/fzf.log"; }
  dm_app_supported() { return 1; }
  dm_ui_main() { echo classic >>"$BATS_TEST_TMPDIR/fzf.log"; }
  run dm_app_main
  [ "$status" -eq 0 ]
  grep -q fzf-path "$BATS_TEST_TMPDIR/fzf.log"
  grep -q classic "$BATS_TEST_TMPDIR/fzf.log"
}

@test "installer copies only the binary of the device's OS/arch" {
  fake_uname Linux aarch64
  mkdir -p "$BATS_TEST_TMPDIR/dist/bin"
  for target in linux-arm64 linux-amd64 darwin-arm64; do printf 'bin-%s' "$target" >"$BATS_TEST_TMPDIR/dist/bin/dm-tui-$target"; done
  run bash -c 'source "$1/client/lib/bootstrap_common.sh"; bs_install_tui "$2/dist/bin" "$2/share/bin"' _ "$REPO" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ -x "$BATS_TEST_TMPDIR/share/bin/dm-tui-linux-arm64" ]
  [ ! -e "$BATS_TEST_TMPDIR/share/bin/dm-tui-linux-amd64" ]
  [ ! -e "$BATS_TEST_TMPDIR/share/bin/dm-tui-darwin-arm64" ]
}

@test "installer is a no-op when the bundle carries no binary (enrollment bundles)" {
  fake_uname Linux aarch64
  mkdir -p "$BATS_TEST_TMPDIR/dist/bin"
  run bash -c 'source "$1/client/lib/bootstrap_common.sh"; bs_install_tui "$2/dist/bin" "$2/share/bin"' _ "$REPO" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/share/bin" ]
}
