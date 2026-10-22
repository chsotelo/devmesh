#!/usr/bin/env bats
# Termux extra-keys row: added only when ~/.termux/termux.properties has no extra-keys line.

load helpers

LINE="extra-keys = [['ESC','/','-','|','HOME','UP','END','PGUP'],['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN','ENTER']]"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home" DM_DIST_DIR="$REPO/client" TX_PREFIX="$BATS_TEST_TMPDIR/prefix"
  mkdir -p "$HOME"
  PROPS="$HOME/.termux/termux.properties"
  # shellcheck source=/dev/null
  source "$REPO/client/lib/bootstrap_termux.sh"
}

# stub_reload [EXIT] — termux-reload-settings on PATH that logs each call.
stub_reload() {
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  printf '#!/bin/sh\necho called >>"%s"\nexit %s\n' "$BATS_TEST_TMPDIR/reload.log" "${1:-0}" \
    >"$BATS_TEST_TMPDIR/stubs/termux-reload-settings"
  chmod +x "$BATS_TEST_TMPDIR/stubs/termux-reload-settings"
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
}

@test "extra-keys: no file creates ~/.termux with the row" {
  run termux_extra_keys
  [ "$status" -eq 0 ]
  [ -f "$PROPS" ]
  [ "$(cat "$PROPS")" = "$LINE" ]
}

@test "extra-keys: file without extra-keys keeps other settings and appends the row" {
  mkdir -p "$HOME/.termux"
  printf 'font-size = 14\nbell-character = ignore\n' >"$PROPS"
  run termux_extra_keys
  [ "$status" -eq 0 ]
  [ "$(head -n 2 "$PROPS")" = "$(printf 'font-size = 14\nbell-character = ignore')" ]
  [ "$(tail -n 1 "$PROPS")" = "$LINE" ]
  [ "$(wc -l <"$PROPS")" -eq 3 ]
}

@test "extra-keys: file without final newline still gets the row on its own line" {
  mkdir -p "$HOME/.termux"
  printf 'font-size = 14' >"$PROPS"
  termux_extra_keys
  [ "$(cat "$PROPS")" = "$(printf 'font-size = 14\n%s' "$LINE")" ]
}

@test "extra-keys: own extra-keys line is left byte-for-byte and reported on stderr" {
  mkdir -p "$HOME/.termux"
  printf "# mine\n  extra-keys = [['ESC','TAB']]\n" >"$PROPS"
  cp "$PROPS" "$BATS_TEST_TMPDIR/expected"
  run termux_extra_keys
  [ "$status" -eq 0 ]
  cmp "$PROPS" "$BATS_TEST_TMPDIR/expected"
  [[ $output == *"already sets extra-keys"* ]]
  [[ $output == *"$LINE"* ]]
}

@test "extra-keys: second run does not duplicate the row" {
  termux_extra_keys
  termux_extra_keys
  [ "$(grep -c '^extra-keys' "$PROPS")" -eq 1 ]
}

@test "extra-keys: termux-reload-settings runs only when present and its failure is ignored" {
  command -v termux-reload-settings >/dev/null && skip "termux-reload-settings exists on this machine"
  run termux_extra_keys
  [ "$status" -eq 0 ]
  rm -f "$PROPS"
  stub_reload 0
  termux_extra_keys
  [ "$(wc -l <"$BATS_TEST_TMPDIR/reload.log")" -eq 1 ]
  rm -f "$PROPS"
  stub_reload 1
  run termux_extra_keys
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/reload.log")" -eq 2 ]
}

@test "extra-keys: existing line does not call termux-reload-settings" {
  mkdir -p "$HOME/.termux"
  printf 'extra-keys = []\n' >"$PROPS"
  stub_reload 0
  termux_extra_keys
  [ ! -e "$BATS_TEST_TMPDIR/reload.log" ]
}
