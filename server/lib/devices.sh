# shellcheck shell=bash
# Device lifecycle (remove) and read-only exports consumed by clients.

cmd_remove() {
  local name=${1:-} confirm=""
  [[ ${2:-} == --confirm ]] && confirm=${3:-}
  valid_name "$name" || die "usage: devmesh remove <name> --confirm <name>"
  [[ $confirm == "$name" ]] || die "refusing: pass --confirm $name"
  # Over the admin channel only an approver may remove another device (dm rm signs the
  # revocation first); any device may remove itself. Root on the hub is not limited.
  if [[ -n ${ADMIN_CALLER:-} && $ADMIN_CALLER != "$name" ]] && signers_exist; then
    signer_is "$ADMIN_CALLER" || die "only an approver can remove another device"
  fi

  lock_acquire
  local code
  while read -r code; do
    [[ -n $code ]] || continue
    invite_load "$code" || continue
    if [[ $INV_NAME == "$name" ]]; then
      invite_drop "$code"
      apply_all
      audit "invite for $name cancelled"
      printf 'cancelled pending invite for %s\n' "$name"
      return 0
    fi
  done < <(invite_codes)

  if signer_is "$name"; then
    [[ $(signers_rows | grep -c .) -gt 1 ]] || die "refusing: $name is the last approver"
    signers_rows | awk -F'\t' -v n="$name" '$1 != n' | atomic_write "$DEVMESH_SIGNERS" 0644
  fi
  ip_retire "$(reg_field "$(reg_get "$name")" ip)"
  reg_remove "$name"
  render_all
  # Keys are gone from the files; now kill live tunnels and jumps (legitimate machines
  # reconnect within seconds), and only then touch WireGuard, which may fail loudly.
  pkill -KILL -u tunnel 2>/dev/null || true
  wg_apply
  audit "removed $name"
  printf 'removed %s: WireGuard peer and tunnel access revoked now; machines drop its key within 1 min\n' "$name"
}

cmd_hosts() { render_hosts; }
cmd_known_hosts() { render_known_hosts; }
cmd_ssh_config() { render_ssh_config; }
cmd_keys() { cat "$DEVMESH_CLIENTS_PUB"; }

# Client bundle for "dm update", streamed over the authenticated SSH channel. When
# "make hub" uploaded a signed bundle (dist/dist.tgz + dist.sig), exactly that file and its
# signature are served; otherwise the bundle is built on the fly (unsigned).
cmd_dist() {
  local dir=$DEVMESH_SHARE/dist
  case ${1:-} in
    version) devmesh_version ;;
    sig)
      [[ -r $dir/dist.sig ]] || die "no signed bundle on this hub"
      cat "$dir/dist.sig"
      ;;
    "")
      if [[ -r $dir/dist.tgz && -r $dir/dist.sig ]]; then cat "$dir/dist.tgz"; else tar -C "$DEVMESH_SHARE" -czf - client VERSION; fi
      ;;
    *) die "usage: devmesh dist [version|sig]" ;;
  esac
}
