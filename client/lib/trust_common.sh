# shellcheck shell=bash
# Trust primitives shared by dm, the bootstrap and devmesh-node. Everything is "ssh-keygen -Y"
# (OpenSSH >= 8.1) in the namespace "devmesh"; a signature is carried as base64 of the armored
# text on ONE line. Verification happens on the device against its local allowed_signers:
#   <approver-name> namespaces="devmesh" <ssh-ed25519 key>
# The hub (and anyone with root on it) can store and repeat signatures but cannot make one.
#
# Messages signed (one line + "\n"):
#   devmesh-client-v1 <name> <pubkey>   devmesh-host-v1 <name> <pubkey>
#   devmesh-signer-v1 <name> <pubkey>   devmesh-bundle-v1 <version> <sha256>
#
# Bundle served by the hub (one entry per line):
#   signer <name> <pubkey> <sig-b64|owner>     client <name> <pubkey> <sig-b64>
#   host <name> <pubkey> <sig-b64>

TR_NS=devmesh
TR_EMPTY_HASH=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
TR_NAME_RE='^[a-z][a-z0-9-]{0,15}$'
TR_KEY_RE='^ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}$'
# Bounded in code: some regex engines (macOS) cap repetition counts at 255.
tr_valid_sig() { [[ $1 =~ ^[A-Za-z0-9+/=]+$ ]] && ((${#1} >= 100 && ${#1} <= 1000)); }

tr_msg() { printf 'devmesh-%s-v1 %s %s\n' "$1" "$2" "$3"; }

# tr_allowed_line NAME KEY
tr_allowed_line() { printf '%s namespaces="%s" %s\n' "$1" "$TR_NS" "$2"; }

# tr_sign KEYFILE MESSAGE -> base64 signature on one line (empty + failure on error)
tr_sign() {
  printf '%s\n' "$2" | ssh-keygen -Y sign -f "$1" -n "$TR_NS" 2>/dev/null | base64 | tr -d '\n'
}

# tr_verify ALLOWED SIG_B64 MESSAGE — prints the approver that signed and succeeds, or fails.
tr_verify() {
  local allowed=$1 sig=$2 msg=$3 work principal rc=1
  tr_valid_sig "$sig" && [[ -s $allowed ]] || return 1
  work=$(mktemp -d) || return 1
  if printf '%s' "$sig" | base64 -d >"$work/sig" 2>/dev/null; then
    while read -r principal; do
      if printf '%s\n' "$msg" | ssh-keygen -Y verify -f "$allowed" -I "$principal" -n "$TR_NS" -s "$work/sig" >/dev/null 2>&1; then
        printf '%s\n' "$principal"
        rc=0
        break
      fi
    done < <(ssh-keygen -Y find-principals -s "$work/sig" -f "$allowed" 2>/dev/null)
  fi
  rm -rf "$work"
  return $rc
}

# tr_fingerprint "ssh-ed25519 AAAA..." -> SHA256:...
tr_fingerprint() {
  local f
  f=$(mktemp) || return 1
  printf '%s\n' "$1" >"$f"
  ssh-keygen -lf "$f" 2>/dev/null | awk '{print $2}'
  rm -f "$f"
}

tr_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# tr_mode ALLOWED DM_TRUST_VALUE — the one rule for every verifier: "signed" when the config says
# so OR an allowed_signers file exists; otherwise "open". Callers fail closed on "signed" without
# a usable allowed_signers (deleting the file never silently downgrades a device).
tr_mode() {
  if [[ $2 == signed || -s $1 ]]; then printf 'signed\n'; else printf 'open\n'; fi
}

# Local state next to allowed_signers:
#   ALLOWED.revoked  revoked keys, one "<name> <type> <key>" per line (verified revocations)
#   ALLOWED.epoch    "<serial> <sha256>" of the highest revocation epoch seen
tr_revoked_file() { printf '%s.revoked\n' "$1"; }
tr_epoch_file() { printf '%s.epoch\n' "$1"; }

# tr_rev_hash FILE — sha256 of the sorted revoke messages of a "<name> <type> <key>" list.
tr_rev_hash() {
  local f n t k
  f=$(mktemp) || return 1
  while read -r n t k; do
    [[ -n $n ]] && tr_msg revoke "$n" "$t $k"
  done <"$1" | LC_ALL=C sort -u >"$f"
  tr_sha256 "$f"
  rm -f "$f"
}

# tr_epoch_state ALLOWED -> "<serial> <hash>" stored locally (0 + hash of the empty set when none)
tr_epoch_state() {
  local f serial hash
  f=$(tr_epoch_file "$1")
  if [[ -r $f ]] && read -r serial hash <"$f" && [[ $serial =~ ^[0-9]+$ && $hash =~ ^[0-9a-f]+$ ]]; then
    printf '%s %s\n' "$serial" "$hash"
  else
    printf '0 %s\n' "$TR_EMPTY_HASH"
  fi
}

# tr_process_bundle ALLOWED BUNDLE [WRITE] — verify a hub bundle against the local
# allowed_signers. Prints one "<kind> <name> <pubkey>" line per VERIFIED entry (kind: signer |
# client | host); what fails is dropped and logged on stderr, malformed lines are skipped and
# logged. New approvers are accepted only when an approver already in ALLOWED signed them (an
# "owner" entry is never taken from the hub); with WRITE=1 they are appended to ALLOWED. A signer's
# own key counts as an approved client key.
# Revocations: "revoke" lines signed by an approver go on the LOCAL revoked list: the key leaves
# allowed_signers and no replayed old signature is accepted again. The "epoch" line (an approver's
# signature over serial + hash of the whole revocation set) makes withholding visible: the bundle
# is REJECTED (status 4, nothing written) when its serial is lower than the highest seen, or its
# revocation set does not hash to the signed value. WRITE=1 stores approvers, revocations and the
# epoch; an empty allowed_signers is never written.
# Status: 0 ok, 2 no valid line at all, 3 no allowed_signers, 4 rejected by the epoch check.
tr_process_bundle() {
  local allowed=$1 bundle=$2 write=${3:-0} work line kind name type k2 sig extra key changed signer_keys
  local revfile valid=0 total=0 serial hash esigner esig es eh ss sh who out=""
  [[ -s $allowed ]] || return 3
  work=$(mktemp -d) || return 2
  cp "$allowed" "$work/cur"
  : >"$work/parsed"
  : >"$work/epochs"
  revfile=$(tr_revoked_file "$allowed")
  if [[ -r $revfile ]]; then cp "$revfile" "$work/revoked"; else : >"$work/revoked"; fi
  cp "$work/revoked" "$work/revoked.orig"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line ]] || continue
    total=$((total + 1))
    if [[ $line == "epoch "* ]]; then
      read -r kind serial hash esigner esig extra <<<"$line"
      if [[ -z $extra && $serial =~ ^[0-9]{1,9}$ && $hash =~ ^[0-9a-f]+$ && ${#hash} -eq 64 && $esigner =~ $TR_NAME_RE ]] && tr_valid_sig "$esig"; then
        valid=$((valid + 1))
        printf '%s\t%s\t%s\t%s\n' "$serial" "$hash" "$esigner" "$esig" >>"$work/epochs"
      else
        printf 'devmesh: skipped a malformed bundle line\n' >&2
      fi
      continue
    fi
    kind="" name="" type="" k2="" sig="" extra=""
    read -r kind name type k2 sig extra <<<"$line"
    key="$type $k2"
    if [[ -n $extra || ! $kind =~ ^(signer|client|host|revoke)$ || ! $name =~ $TR_NAME_RE || ! $key =~ $TR_KEY_RE ]] ||
      ! { tr_valid_sig "$sig" || [[ $kind == signer && $sig == owner ]]; }; then
      printf 'devmesh: skipped a malformed bundle line\n' >&2
      continue
    fi
    valid=$((valid + 1))
    printf '%s\t%s\t%s\t%s\n' "$kind" "$name" "$key" "$sig" >>"$work/parsed"
  done <"$bundle"
  if ((total > 0 && valid == 0)); then
    rm -rf "$work"
    return 2
  fi

  # Approvers and revocations converge together: a revocation may be signed by an approver that
  # only this bundle introduces (a device that was offline), and a revoked key may not be
  # (re)admitted. Repeat until nothing changes.
  read -r ss sh <<<"$(tr_epoch_state "$allowed")"
  for _ in 1 2 3 4 5 6 7 8; do
    changed=0
    while IFS=$'\t' read -r kind name key sig; do
      [[ $kind == revoke ]] || continue
      awk -v k="$key" '$2 " " $3 == k {f = 1} END {exit !f}' "$work/revoked" && continue
      if tr_verify "$work/cur" "$sig" "$(tr_msg revoke "$name" "$key")" >/dev/null; then
        printf '%s %s\n' "$name" "$key" >>"$work/revoked"
        printf 'devmesh: revoked key of %s\n' "$name" >&2
        changed=1
      fi
    done <"$work/parsed"
    while read -r _ type k2; do
      [[ -n $type ]] || continue
      grep -qF -- "$type $k2" "$work/cur" || continue
      grep -vF -- "$type $k2" "$work/cur" >"$work/cur.new" || true
      mv -f "$work/cur.new" "$work/cur"
      changed=1
    done <"$work/revoked"
    while IFS=$'\t' read -r kind name key sig; do
      [[ $kind == signer && $sig != owner ]] || continue
      awk -v k="$key" '$2 " " $3 == k {f = 1} END {exit !f}' "$work/revoked" && continue
      grep -qxF -- "$(tr_allowed_line "$name" "$key")" "$work/cur" && continue
      if tr_verify "$work/cur" "$sig" "$(tr_msg signer "$name" "$key")" >/dev/null; then
        tr_allowed_line "$name" "$key" >>"$work/cur"
        changed=1
      fi
    done <"$work/parsed"
    ((changed)) || break
  done
  while IFS=$'\t' read -r kind name key sig; do
    [[ $kind == revoke ]] || continue
    awk -v k="$key" '$2 " " $3 == k {f = 1} END {exit !f}' "$work/revoked" ||
      printf 'devmesh: dropped revocation of %s: no valid approver signature\n' "$name" >&2
  done <"$work/parsed"

  # Revocation epoch: highest validly signed serial in the bundle against the highest seen.
  es=0
  eh=$TR_EMPTY_HASH
  while IFS=$'\t' read -r serial hash esigner esig; do
    ((10#$serial > es)) || continue
    # A hub cannot burn the serial space: at most 1000 ahead of the highest one seen.
    ((10#$serial <= ss + 1000)) || continue
    who=$(tr_verify "$work/cur" "$esig" "$(tr_msg epoch "$serial" "$hash")") || continue
    [[ $who == "$esigner" ]] || continue
    es=$((10#$serial))
    eh=$hash
  done <"$work/epochs"
  if ((es < ss)) || { ((es == ss && ss > 0)) && [[ $eh != "$sh" ]]; } || [[ $(tr_rev_hash "$work/revoked") != "$eh" ]]; then
    printf 'devmesh: bundle rejected: revocation epoch %s (seen %s) or revocation set does not match the signed one\n' "$es" "$ss" >&2
    rm -rf "$work"
    return 4
  fi

  signer_keys=$(awk '{print $3 " " $4}' "$work/cur")

  while IFS=$'\t' read -r kind name key sig; do
    if [[ $kind != revoke ]] && awk -v k="$key" '$2 " " $3 == k {f = 1} END {exit !f}' "$work/revoked"; then
      printf 'devmesh: dropped %s %s: key is revoked\n' "$kind" "$name" >&2
      continue
    fi
    case $kind in
      signer)
        if grep -qxF -- "$(tr_allowed_line "$name" "$key")" "$work/cur"; then
          out+="signer $name $key"$'\n'
        else
          printf 'devmesh: dropped approver %s: not signed by a known approver\n' "$name" >&2
        fi
        ;;
      client)
        if grep -qxF -- "$key" <<<"$signer_keys" || tr_verify "$work/cur" "$sig" "$(tr_msg client "$name" "$key")" >/dev/null; then
          out+="client $name $key"$'\n'
        else
          printf 'devmesh: dropped client key of %s: no valid approver signature\n' "$name" >&2
        fi
        ;;
      host)
        if tr_verify "$work/cur" "$sig" "$(tr_msg host "$name" "$key")" >/dev/null; then
          out+="host $name $key"$'\n'
        else
          printf 'devmesh: dropped host key of %s: no valid approver signature\n' "$name" >&2
        fi
        ;;
    esac
  done <"$work/parsed"

  if ((write)); then
    if ! cmp -s "$work/cur" "$allowed"; then
      if [[ -s $work/cur ]]; then
        { cp "$work/cur" "$allowed.new" && mv -f "$allowed.new" "$allowed"; } 2>/dev/null ||
          printf 'devmesh: cannot update %s (approver changes not saved)\n' "$allowed" >&2
      else
        printf 'devmesh: refusing to write an empty %s (keeping the old one)\n' "$allowed" >&2
      fi
    fi
    if ! cmp -s "$work/revoked" "$work/revoked.orig"; then
      { cp "$work/revoked" "$revfile.new" && mv -f "$revfile.new" "$revfile"; } 2>/dev/null ||
        printf 'devmesh: cannot update %s (revocations not saved)\n' "$revfile" >&2
    fi
    if ((es != ss)) || [[ $eh != "$sh" ]]; then
      { printf '%s %s\n' "$es" "$eh" >"$(tr_epoch_file "$allowed").new" && mv -f "$(tr_epoch_file "$allowed").new" "$(tr_epoch_file "$allowed")"; } 2>/dev/null ||
        printf 'devmesh: cannot store the revocation epoch\n' >&2
    fi
  fi
  printf '%s' "$out"
  rm -rf "$work"
  return 0
}

# tr_import_signers FILE ALLOWED [ROOT_KEY] — lines "<name> <pubkey> <owner|sig>" delivered at
# enrollment (or fetched by "dm trust pin"). The root of trust is exactly ONE key: ROOT_KEY (the
# one the user confirmed) or, at enrollment, the single "owner" row (more than one is refused).
# Every other row is accepted only through a valid signature chain from that root (same rule as
# bundles); a second "owner" row is never trusted. Writes ALLOWED.
tr_import_signers() {
  local file=$1 allowed=$2 root=${3:-} work name type k2 proof owners=0 rootline=""
  work=$(mktemp -d) || return 1
  : >"$work/bundle"
  while read -r name type k2 proof; do
    [[ $name =~ $TR_NAME_RE && "$type $k2" =~ $TR_KEY_RE && -n $proof ]] || continue
    printf 'signer %s %s %s %s\n' "$name" "$type" "$k2" "$proof" >>"$work/bundle"
    if [[ $proof == owner ]]; then
      owners=$((owners + 1))
      if [[ -z $rootline && (-z $root || "$type $k2" == "$root") ]]; then
        rootline=$(tr_allowed_line "$name" "$type $k2")
      fi
    fi
  done <"$file"
  if [[ -z $root ]] && ((owners > 1)); then
    printf 'devmesh: more than one owner delivered: refusing all of them\n' >&2
    rootline=""
  fi
  if [[ -n $rootline ]]; then
    printf '%s\n' "$rootline" >"$work/start"
    tr_process_bundle "$work/start" "$work/bundle" 1 >/dev/null 2>&1 && cp "$work/start" "$allowed"
  fi
  rm -rf "$work"
  [[ -s $allowed ]]
}
