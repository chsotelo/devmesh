#!/usr/bin/env bats
# scripts/release.sh: tarball layout, exclusions, checksums and version checks.

setup() {
  REPO=$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)
  VER=$(tr -d '[:space:]' <"$REPO/VERSION")
  OUT="$BATS_TEST_TMPDIR/dist"
  TARBALL="$OUT/devmesh-$VER.tar.gz"
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
