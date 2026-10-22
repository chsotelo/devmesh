#!/usr/bin/env bash
# Build the devmesh release tarball and its SHA256SUMS.
# Usage: scripts/release.sh VERSION OUTDIR
set -euo pipefail

readonly VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$'
readonly FIXED_MTIME='2026-01-01'

die() {
  echo "release: $*" >&2
  exit 1
}

[[ $# -eq 2 ]] || {
  echo "usage: $0 VERSION OUTDIR" >&2
  exit 2
}
version=$1
outdir=$2

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ ! $version =~ $VERSION_RE ]]; then
  die "invalid version '$version' (expected X.Y.Z or X.Y.Z-rcN)"
fi

# A -rcN tag is allowed for the VERSION file's base release (0.7.0 -> 0.7.0-rc1).
base=${version%-rc*}
file_version=$(tr -d '[:space:]' <"$root/VERSION")
if [[ $base != "$file_version" ]]; then
  die "version '$version' does not match VERSION file ('$file_version')"
fi

# The Go panel ships in the tarball (client/bin/dm-tui-<os>-<arch>): build it with the release
# version unless told not to (DM_RELEASE_TUI=0, for builds without Go).
if [[ ${DM_RELEASE_TUI:-1} == 1 ]]; then
  command -v go >/dev/null 2>&1 || die "Go is needed to build dm-tui (DM_RELEASE_TUI=0 skips it)"
  make -C "$root" tui-all VERSION="$version" >&2 || die "building dm-tui failed"
fi

name="devmesh-$version"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$name" "$outdir"

for item in client server VERSION LICENSE docker install.sh; do
  if [[ -e $root/$item ]]; then
    cp -R "$root/$item" "$stage/$name/"
  fi
done
find "$stage/$name" -name .git -prune -exec rm -rf {} +

# COPYFILE_DISABLE stops bsdtar from adding AppleDouble ._ files on macOS.
export COPYFILE_DISABLE=1
export GZIP=-n
tarball="$outdir/$name.tar.gz"
rm -f "$tarball"
if tar --version 2>/dev/null | grep -q GNU; then
  tar -C "$stage" --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="$FIXED_MTIME" -czf "$tarball" "$name"
else
  tar -C "$stage" -czf "$tarball" "$name"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sum_cmd=(sha256sum)
else
  sum_cmd=(shasum -a 256)
fi
(cd "$outdir" && "${sum_cmd[@]}" "$name.tar.gz" >SHA256SUMS)

echo "$tarball"
