#!/usr/bin/env bats
# scripts/release.sh: tarball layout, exclusions, checksums and version checks.

setup() {
  REPO=$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)
  VER=$(tr -d '[:space:]' <"$REPO/VERSION")
  OUT="$BATS_TEST_TMPDIR/dist"
  TARBALL="$OUT/devmesh-$VER.tar.gz"
  export DM_RELEASE_TUI=0 # building five Go targets belongs to its own test
}

sha_check() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS
  else
    shasum -a 256 -c SHA256SUMS
  fi
}

@test "release tarball contains client/bin/dm and VERSION under devmesh-VERSION/" {
  run bash "$REPO/scripts/release.sh" "$VER" "$OUT"
  [ "$status" -eq 0 ]
  [ -f "$TARBALL" ]
  run tar -tzf "$TARBALL"
  [ "$status" -eq 0 ]
  [[ $output == *"devmesh-$VER/client/bin/dm"* ]]
  [[ $output == *"devmesh-$VER/VERSION"* ]]
}

@test "release tarball excludes tests, backups, PLAN-OSS.md and .git" {
  run bash "$REPO/scripts/release.sh" "$VER" "$OUT"
  [ "$status" -eq 0 ]
  run tar -tzf "$TARBALL"
  [ "$status" -eq 0 ]
  [[ $output != *"devmesh-$VER/tests/"* ]]
  [[ $output != *"devmesh-$VER/backups/"* ]]
  [[ $output != *"PLAN-OSS.md"* ]]
  [[ $output != *"/.git/"* ]]
  [[ $output != *"/._"* ]]
}

@test "SHA256SUMS verifies the tarball" {
  run bash "$REPO/scripts/release.sh" "$VER" "$OUT"
  [ "$status" -eq 0 ]
  cd "$OUT"
  run sha_check
  [ "$status" -eq 0 ]
}

@test "release.sh exits non-zero when the tag does not match the VERSION file" {
  run bash "$REPO/scripts/release.sh" "9.9.9" "$OUT"
  [ "$status" -ne 0 ]
  [ ! -f "$OUT/devmesh-9.9.9.tar.gz" ]
}

@test "release.sh exits non-zero for an invalid version string" {
  run bash "$REPO/scripts/release.sh" "v$VER" "$OUT"
  [ "$status" -ne 0 ]
  run bash "$REPO/scripts/release.sh" "$VER-beta" "$OUT"
  [ "$status" -ne 0 ]
}

@test "release builds the dm-tui binaries (make tui-all with the release version) into the tarball" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/make" <<'STUB'
#!/usr/bin/env bash
# Stub make: records its arguments and drops a fake binary where tui-all would.
printf '%s\n' "$*" >"$STUB_MAKE_LOG"
mkdir -p "$2/client/bin"
printf 'fake' >"$2/client/bin/dm-tui-linux-amd64"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/make"
  # release.sh checks that Go exists before it calls make; the runner may have none.
  printf '#!/bin/sh\nexit 0\n' >"$BATS_TEST_TMPDIR/bin/go"
  chmod +x "$BATS_TEST_TMPDIR/bin/go"
  export STUB_MAKE_LOG="$BATS_TEST_TMPDIR/make.log"
  DM_RELEASE_TUI=1 PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$REPO/scripts/release.sh" "$VER" "$OUT"
  rm -f "$REPO/client/bin/dm-tui-linux-amd64"
  [ "$status" -eq 0 ]
  grep -q "tui-all VERSION=$VER" "$STUB_MAKE_LOG"
  run tar -tzf "$TARBALL"
  [[ $output == *"devmesh-$VER/client/bin/dm-tui-linux-amd64"* ]]
}
