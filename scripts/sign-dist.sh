#!/usr/bin/env bash
# Build the client bundle the hub will serve to "dm update" and sign it with this machine's
# devmesh key: dist/dist.tgz + dist/dist.sig (signature of "devmesh-bundle-v1 <version> <sha256>").
# Devices verify it against their allowed_signers, so a compromised hub cannot ship code.
# Without an approver key here the directory is left empty and the hub serves an unsigned bundle.
# Usage: scripts/sign-dist.sh OUTDIR
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:?usage: sign-dist.sh OUTDIR}
key=${DM_ID_KEY:-$HOME/.ssh/id_devmesh}
# shellcheck source=../client/lib/trust_common.sh
source "$root/client/lib/trust_common.sh"

rm -rf "$out"
mkdir -p "$out"
allowed=""
for f in "${DM_ALLOWED_SIGNERS:-/nonexistent}" "$HOME/.config/devmesh/allowed_signers" /etc/devmesh/allowed_signers; do
  [[ -s $f ]] && allowed=$f && break
done
if [[ ! -r $key || -z $allowed ]] ||
  ! awk '{print $3 " " $4}' "$allowed" | grep -qxF -- "$(awk '{print $1 " " $2}' "$key.pub")"; then
  echo "sign-dist: this machine is not an approver; the client bundle will be served unsigned" >&2
  exit 0
fi
version=$(tr -d '[:space:]' <"$root/VERSION")
COPYFILE_DISABLE=1 tar -C "$root" -czf "$out/dist.tgz" client VERSION
sig=$(tr_sign "$key" "$(tr_msg bundle "$version" "$(tr_sha256 "$out/dist.tgz")")")
[[ -n $sig ]] || {
  echo "sign-dist: signing failed" >&2
  exit 1
}
printf '%s\n' "$sig" >"$out/dist.sig"
echo "sign-dist: signed client bundle $version"
