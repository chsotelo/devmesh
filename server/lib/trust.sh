# shellcheck shell=bash
# Trust: approvers (signers) and device approvals. The hub only stores and repeats
# signatures made on approvers' devices with "ssh-keygen -Y sign -n devmesh"; devices verify
# them against their local allowed_signers, so a compromised hub cannot add access.
#
# signers.tsv: name<TAB>pubkey<TAB>proof, proof = "owner" (first approver, trusted at
# install time) or the base64 signature of "devmesh-signer-v1 <name> <pubkey>" by an
# existing approver.
#
# Messages (one line + "\n"):
#   devmesh-client-v1 <name> <pubkey>   devmesh-host-v1 <name> <pubkey>
#   devmesh-signer-v1 <name> <pubkey>   devmesh-bundle-v1 <version> <sha256>

readonly TRUST_NS=devmesh
# Bounded in code: some regex engines (macOS) cap repetition counts at 255.
valid_sig() { [[ $1 =~ ^[A-Za-z0-9+/=]+$ ]] && ((${#1} >= 100 && ${#1} <= 1000)); }
readonly APPROVE_MAX_BYTES=4096

signers_rows() {
  [[ -r $DEVMESH_SIGNERS ]] || return 0
  awk -F'\t' 'NF == 3' "$DEVMESH_SIGNERS"
}
signers_exist() { [[ -n $(signers_rows) ]]; }
signer_is() { signers_rows | awk -F'\t' -v n="$1" '$1 == n {f = 1} END {exit !f}'; }

signer_add() {
  { signers_rows && printf '%s\t%s\t%s\n' "$1" "$2" "$3"; } | atomic_write "$DEVMESH_SIGNERS" 0644
}

# trust_verify SIG_B64 MESSAGE — true when an approver in signers.tsv signed MESSAGE.
# Hygiene only: the devices repeat this check themselves, the hub's word is worth nothing.
trust_verify() {
  local sig=$1 msg=$2 work principal name pub ok=1
  valid_sig "$sig" || return 1
  work=$(mktemp -d)
  while IFS=$'\t' read -r name pub _; do
    printf '%s namespaces="%s" %s\n' "$name" "$TRUST_NS" "$pub"
  done < <(signers_rows) >"$work/allowed"
  printf '%s' "$sig" | base64 -d >"$work/sig" 2>/dev/null || {
    rm -rf "$work"
    return 1
  }
  while read -r principal; do
    if printf '%s\n' "$msg" | ssh-keygen -Y verify -f "$work/allowed" -I "$principal" -n "$TRUST_NS" -s "$work/sig" >/dev/null 2>&1; then
      printf '%s\n' "$principal"
      ok=0
      break
    fi
  done < <(ssh-keygen -Y find-principals -s "$work/sig" -f "$work/allowed" 2>/dev/null)
  rm -rf "$work"
  return $ok
}

# Devices that still need a signature, for approvers: one TSV line each:
#   name kind client_pub host_pub enrolled_at origin need   (need: client | host | client+host)
cmd_pending() {
  local name kind client_pub host_pub at origin sig csig hsig need
  while IFS=$'\t' read -r name kind _ _ _ _ _ _ _ client_pub _ host_pub at origin _ sig; do
    csig=${sig%%:*}
    hsig=-
    [[ $sig == *:* ]] && hsig=${sig#*:}
    need=""
    [[ $csig == - || $csig == legacy ]] && need=client
    if [[ $kind == machine && $hsig == - ]]; then need=${need:+$need+}host; fi
    [[ -n $need ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$client_pub" "$host_pub" "$at" "$origin" "$need"
  done < <(reg_rows)
}

# owner <device>: root on the hub marks an EXISTING device as the first approver (migration from
# versions without signatures; new installs use "invite --owner"). Devices that were already
# enrolled keep working in open mode ("legacy") until an approver signs them (dm trust init).
cmd_owner() {
  local name=${1:-} row sig n
  valid_name "$name" || die "usage: devmesh owner <device>"
  lock_acquire
  signers_exist && die "this hub already has an approver"
  row=$(reg_get "$name") || die "no such device: $name"
  sig=$(reg_field "$row" sig)
  signer_add "$name" "$(reg_field "$row" client_pub)" owner
  if [[ $sig == *:* ]]; then reg_set_sig "$name" "owner:${sig#*:}"; else reg_set_sig "$name" owner; fi
  while read -r n; do
    [[ $n == "$name" ]] && continue
    sig=$(reg_field "$(reg_get "$n")" sig)
    [[ $sig == - ]] && reg_set_sig "$n" legacy
  done < <(reg_column name)
  render_all
  audit "owner set: $name"
  printf '%s is the first approver. Next: on it run "dm trust pin" then "dm trust init"\n' "$name"
}

revoked_rows() {
  [[ -r $DEVMESH_REVOKED ]] || return 0
  awk -F'\t' 'NF == 3' "$DEVMESH_REVOKED"
}

# sha256 of the sorted revoke messages ("devmesh-revoke-v1 <name> <pubkey>") of the stored
# revocations; devices compute the same value.
rev_hash() {
  local f n p
  f=$(mktemp)
  {
    revoked_rows | while IFS=$'\t' read -r n p _; do printf 'devmesh-revoke-v1 %s %s\n' "$n" "$p"; done
  } | LC_ALL=C sort -u >"$f"
  sha256_of "$f"
  rm -f "$f"
}

# The current epoch line as devices parse it (delivered to a joining device, like the approvers).
epoch_line() { [[ -r $DEVMESH_EPOCH ]] && awk -F'\t' 'NF == 4 {print "epoch " $1 " " $2 " " $3 " " $4; exit}' "$DEVMESH_EPOCH" || true; }

epoch_serial() { [[ -r $DEVMESH_EPOCH ]] && awk -F'\t' 'NF == 4 {print $1; exit}' "$DEVMESH_EPOCH" || printf '0\n'; }

# revoke <name>, stdin "revoke <sig>" and "epoch <sig>": an approver signed
# "devmesh-revoke-v1 <name> <pubkey>" and the new epoch "devmesh-epoch-v1 <serial+1> <hash of the
# revocation set including this one>". Devices keep both, so a later bundle that hides the
# revocation, or goes back to an older epoch, is rejected by them. Called before "remove".
cmd_revoke() {
  local caller=${ADMIN_CALLER:-} name=${1:-} input line sig="" esig="" row pub serial hash signer
  valid_name "$name" || die "usage: revoke <name> (signatures on stdin)"
  signer_is "$caller" || die "only an approver can revoke devices"
  input=$(timeout "${ENROLL_TIMEOUT:-10}" head -c "$APPROVE_MAX_BYTES") || true
  ((${#input} < APPROVE_MAX_BYTES)) || die "input too large"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == "revoke "* ]] && sig=${line#revoke }
    [[ $line == "epoch "* ]] && esig=${line#epoch }
  done <<<"$input"
  valid_sig "$sig" || die "invalid signature"
  valid_sig "$esig" || die "invalid epoch signature"
  lock_acquire
  row=$(reg_get "$name") || die "no such device: $name"
  pub=$(reg_field "$row" client_pub)
  trust_verify "$sig" "devmesh-revoke-v1 $name $pub" >/dev/null || die "revocation signature does not verify"
  if signer_is "$name" && [[ $(signers_rows | grep -c .) -le 1 ]]; then die "refusing: $name is the last approver"; fi
  if revoked_rows | awk -F'\t' -v k="$pub" '$2 == k {f = 1} END {exit !f}'; then die "that key is already revoked"; fi
  revoked_rows >"$DEVMESH_ETC/.revoked.tmp"
  printf '%s\t%s\t%s\n' "$name" "$pub" "$sig" >>"$DEVMESH_ETC/.revoked.tmp"
  serial=$(($(epoch_serial) + 1))
  hash=$(
    cp "$DEVMESH_REVOKED" "$DEVMESH_ETC/.revoked.old" 2>/dev/null || : >"$DEVMESH_ETC/.revoked.old"
    cp "$DEVMESH_ETC/.revoked.tmp" "$DEVMESH_REVOKED"
    rev_hash
  )
  signer=$(trust_verify "$esig" "devmesh-epoch-v1 $serial $hash") || {
    cp "$DEVMESH_ETC/.revoked.old" "$DEVMESH_REVOKED"
    rm -f "$DEVMESH_ETC/.revoked.tmp" "$DEVMESH_ETC/.revoked.old"
    die "epoch signature does not verify for serial $serial (stale? run dm refresh and retry)"
  }
  printf '%s\t%s\t%s\t%s\n' "$serial" "$hash" "$signer" "$esig" | atomic_write "$DEVMESH_EPOCH" 0644
  rm -f "$DEVMESH_ETC/.revoked.tmp" "$DEVMESH_ETC/.revoked.old"
  render_all
  audit "revocation of $name stored (by $caller), epoch $serial"
  printf 'revocation of %s stored (epoch %s)\n' "$name" "$serial"
}

cmd_signers() { signers_rows; }
cmd_bundle() { cat "$DEVMESH_BUNDLE"; }

# approve <name>, signatures on stdin ("client|host|signer <sig-b64>", one per line). The
# caller must be an approver. A signature that does not verify is refused, so garbage never
# marks a device as approved.
cmd_approve() {
  local caller=${ADMIN_CALLER:-} name=${1:-} input line field value row kind pub old csig hsig
  local got_client="" got_host="" got_signer=""
  valid_name "$name" || die "usage: approve <name> (signatures on stdin)"
  signer_is "$caller" || die "only an approver can approve devices"
  input=$(timeout "${ENROLL_TIMEOUT:-10}" head -c "$APPROVE_MAX_BYTES") || true
  ((${#input} < APPROVE_MAX_BYTES)) || die "input too large"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line ]] || continue
    field=${line%% *}
    value=${line#* }
    valid_sig "$value" || die "invalid signature"
    case $field in
      client) got_client=$value ;;
      host) got_host=$value ;;
      signer) got_signer=$value ;;
      *) die "unknown field: $field" ;;
    esac
  done <<<"$input"
  [[ -n $got_client$got_host$got_signer ]] || die "no signature given"

  lock_acquire
  row=$(reg_get "$name") || die "no such device: $name"
  kind=$(reg_field "$row" kind)
  old=$(reg_field "$row" sig)
  csig=${old%%:*}
  hsig=-
  [[ $old == *:* ]] && hsig=${old#*:}

  if [[ -n $got_client ]]; then
    [[ $csig != owner ]] || die "$name is the owner; its client key needs no signature"
    pub=$(reg_field "$row" client_pub)
    trust_verify "$got_client" "devmesh-client-v1 $name $pub" >/dev/null || die "client signature does not verify"
    csig=$got_client
  fi
  if [[ -n $got_host ]]; then
    [[ $kind == machine ]] || die "$name is not a machine"
    pub=$(reg_field "$row" host_pub)
    trust_verify "$got_host" "devmesh-host-v1 $name $pub" >/dev/null || die "host signature does not verify"
    hsig=$got_host
  fi
  if [[ -n $got_signer ]]; then
    pub=$(reg_field "$row" client_pub)
    trust_verify "$got_signer" "devmesh-signer-v1 $name $pub" >/dev/null || die "signer signature does not verify"
    signer_is "$name" || signer_add "$name" "$pub" "$got_signer"
  fi
  if [[ $hsig == - ]]; then reg_set_sig "$name" "$csig"; else reg_set_sig "$name" "$csig:$hsig"; fi
  render_all
  audit "approved $name by $caller (client=${got_client:+1} host=${got_host:+1} signer=${got_signer:+1})"
  printf 'approved %s\n' "$name"
}
