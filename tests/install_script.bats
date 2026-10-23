#!/usr/bin/env bats
# install.sh: guided installer. Uses file:// URLs and test-only overrides
# (INSTALL_TEST_EUID, DEVMESH_OS_RELEASE, DEVMESH_TTY, DEVMESH_DETECT_IP).

setup() {
  REPO=$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)
  VER=$(tr -d '[:space:]' <"$REPO/VERSION")
  T=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  OUT="$T/dist"
  DM_RELEASE_TUI=0 bash "$REPO/scripts/release.sh" "$VER" "$OUT" >/dev/null
  export DEVMESH_VERSION="$VER"
  export DEVMESH_TARBALL_URL="file://$OUT/devmesh-$VER.tar.gz"
  export DEVMESH_SUMS_URL="file://$OUT/SHA256SUMS"
  export DEVMESH_SKIP_INSTALL=1 DEVMESH_DETECT_IP=0 INSTALL_TEST_EUID=0
  printf 'ID=ubuntu\nVERSION_ID="22.04"\n' >"$T/os-release"
  export DEVMESH_OS_RELEASE="$T/os-release"
  AGE="age1$(printf 'q%.0s' {1..58})"
  unset HUB_HOST ACME_EMAIL BACKUP_RECIPIENT
}

@test "non-interactive happy path passes HUB_HOST and BACKUP_RECIPIENT" {
  export HUB_HOST=hub.example.com ACME_EMAIL=me@example.com BACKUP_RECIPIENT="$AGE"
  export DEVMESH_TTY=/nonexistent
  run bash "$REPO/install.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"extracted: "*"devmesh-$VER"* ]]
  [[ $output == *"HUB_HOST=hub.example.com"* ]]
  [[ $output == *"ACME_EMAIL=me@example.com"* ]]
  [[ $output == *"BACKUP_RECIPIENT=$AGE"* ]]
  dir=${output#*extracted: }
  dir=${dir%%$'\n'*}
  [ -f "$dir/server/install-hub.sh" ]
}

@test "checksum mismatch aborts and does not extract" {
  printf '%064d  devmesh-%s.tar.gz\n' 0 "$VER" >"$T/BAD_SUMS"
  export DEVMESH_SUMS_URL="file://$T/BAD_SUMS"
  export HUB_HOST=1.2.3.4
  run bash "$REPO/install.sh"
  [ "$status" -ne 0 ]
  [[ $output == *"checksum verification failed"* ]]
  [[ $output != *"extracted:"* ]]
}

@test "invalid BACKUP_RECIPIENT aborts" {
  export HUB_HOST=1.2.3.4 BACKUP_RECIPIENT=age1short
  run bash "$REPO/install.sh"
  [ "$status" -ne 0 ]
  [[ $output == *"BACKUP_RECIPIENT"* ]]
}

@test "non-root aborts with the sudo hint" {
  export INSTALL_TEST_EUID=1000 HUB_HOST=1.2.3.4
  run bash "$REPO/install.sh"
  [ "$status" -ne 0 ]
  [[ $output == *"| sudo bash"* ]]
  [[ $output != *"extracted:"* ]]
}

@test "unsupported OS prints docker instructions and exits 2" {
  printf 'ID=fedora\nVERSION_ID=40\n' >"$T/os-release"
  export HUB_HOST=1.2.3.4
  run bash "$REPO/install.sh"
  [ "$status" -eq 2 ]
  [[ $output == *"docker compose -f docker/hub/compose.yml up -d"* ]]
}

@test "old Ubuntu and old Debian are rejected" {
  export HUB_HOST=1.2.3.4
  printf 'ID=ubuntu\nVERSION_ID="18.04"\n' >"$T/os-release"
  run bash "$REPO/install.sh"
  [ "$status" -eq 2 ]
  printf 'ID=debian\nVERSION_ID="10"\n' >"$T/os-release"
  run bash "$REPO/install.sh"
  [ "$status" -eq 2 ]
  printf 'ID=debian\nVERSION_ID="12"\n' >"$T/os-release"
  run bash "$REPO/install.sh"
  [ "$status" -eq 0 ]
}

@test "interactive: an IP answer skips the email question" {
  printf '203.0.113.7\n\n' >"$T/answers"
  export DEVMESH_TTY="$T/answers"
  run bash "$REPO/install.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"Domain or IP of this server: "* ]]
  [[ $output != *"Let's Encrypt"* ]]
  [[ $output == *"Backup public key (age1…, empty = no off-site backup): "* ]]
  [[ $output == *"HUB_HOST=203.0.113.7"* ]]
  [[ $output == *"BACKUP_RECIPIENT="$'\n'* || $output == *"BACKUP_RECIPIENT=" ]]
}

@test "interactive: a domain answer requires an email and passes the key" {
  printf 'hub.example.com\nme@example.com\n%s\n' "$AGE" >"$T/answers"
  export DEVMESH_TTY="$T/answers"
  run bash "$REPO/install.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"Email for Let's Encrypt: "* ]]
  [[ $output == *"HUB_HOST=hub.example.com"* ]]
  [[ $output == *"ACME_EMAIL=me@example.com"* ]]
  [[ $output == *"BACKUP_RECIPIENT=$AGE"* ]]
}

@test "interactive: re-asks on invalid input then exits 1 after 3 tries" {
  printf 'hub.example.com\nnope\nnope\nnope\n' >"$T/answers"
  export DEVMESH_TTY="$T/answers"
  run bash "$REPO/install.sh"
  [ "$status" -eq 1 ]
  [[ $output == *"too many invalid answers"* ]]
}

@test "interactive: invalid answer followed by a valid one succeeds" {
  printf 'bad host\n198.51.100.2\nage1bad\n\n' >"$T/answers"
  export DEVMESH_TTY="$T/answers"
  run bash "$REPO/install.sh"
  [ "$status" -eq 0 ]
  [[ $output == *"HUB_HOST=198.51.100.2"* ]]
}

@test "no HUB_HOST and no terminal fails with guidance" {
  export DEVMESH_TTY=/nonexistent
  run bash "$REPO/install.sh"
  [ "$status" -ne 0 ]
  [[ $output == *"set HUB_HOST"* ]]
}

@test "without any version source it takes the latest release from GitHub's redirect" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho https://github.com/chsotelo/devmesh/releases/tag/v9.8.7\n' >"$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'source <(sed "\$d" "$1"); latest_version' _ "$REPO/install.sh"
  [ "$status" -eq 0 ]
  [ "$output" = 9.8.7 ]
}
