# shellcheck shell=bash
# dm trust / dm approve: devices vouch for each other with ssh-keygen -Y signatures, so the
# hub cannot add access, impersonate a machine or ship code. See trust_common.sh.

# shellcheck source=trust_common.sh
source "${BASH_SOURCE[0]%/*}/trust_common.sh"

dm_allowed_signers() {
  printf '%s\n' "${DM_ALLOWED_SIGNERS:-$(dirname "$(dm_conf_file)")/allowed_signers}"
}

# Verification is on when DM_TRUST=signed or an allowed_signers file exists (tr_mode). In signed
# mode a missing or empty allowed_signers is an error, never a silent downgrade.
dm_trust_active() {
  local f
  f=$(dm_allowed_signers)
  [[ $(tr_mode "$f" "${DM_TRUST:-}") == signed ]] || return 1
  [[ -s $f ]] || dm_die "signed mode but $f is missing or empty: refusing (fix: dm trust pin)"
}

dm_trust_key_file() { printf '%s\n' "${DM_ID_KEY:-$HOME/.ssh/id_devmesh}"; }

dm_trust_my_pub() {
  local f
  f=$(dm_trust_key_file).pub
  [[ -r $f ]] || return 1
  awk '{print $1 " " $2}' "$f"
}

# Is this device one of its own approvers?
dm_trust_is_approver() {
  local pub
  pub=$(dm_trust_my_pub) || return 1
  [[ -s $(dm_allowed_signers) ]] && awk '{print $3 " " $4}' "$(dm_allowed_signers)" | grep -qxF -- "$pub"
}

# Hub text is untrusted: keep printable ASCII only before showing it.
dm_trust_clean() { printf '%s' "$1" | tr -cd '[:print:]'; }

# dm_trust_known_hosts KNOWN HOSTS BUNDLE — the devmesh_known_hosts content: the hub's own
# pinned entry (the one already on this device; the hub cannot change it) plus the machine
# host keys that an approver signed. Warns about machines whose host key is not approved.
dm_trust_known_hosts() {
  local known=$1 hosts=$2 bundle=$3 verified rc=0 hub=${DM_HUB_HOST:-} line name seen=" "
  local pinned=$HOME/.ssh/devmesh_known_hosts
  if [[ -r $pinned ]]; then
    line=$(awk -v h="$hub" '{n = split($1, a, ","); for (i = 1; i <= n; i++) if (a[i] == h) {print; exit}}' "$pinned")
  fi
  [[ -n ${line:-} ]] ||
    line=$(awk -v h="$hub" '{n = split($1, a, ","); for (i = 1; i <= n; i++) if (a[i] == h) {print; exit}}' "$known")
  [[ -n $line ]] || return 1
  # Rebuilt from the key only: a hub-supplied host list (e.g. "hub,*") must not widen it.
  line=$(awk -v h="$hub" '$2 ~ /^ssh-ed25519$/ && $3 ~ /^[A-Za-z0-9+\/]+=*$/ {print h, $2, $3; exit}' <<<"$line")
  [[ -n $line ]] || return 1
  verified=$(tr_process_bundle "$(dm_allowed_signers)" "$bundle" 1) || rc=$?
  ((rc == 0)) || return "$rc"
  printf '%s\n' "$line"
  while read -r kind name key; do
    [[ $kind == host ]] || continue
    printf '%s %s\n' "$name" "$key"
    seen+="$name "
  done <<<"$verified"
  while IFS=$'\t' read -r name kind _; do
    [[ $kind == machine && $seen != *" $name "* ]] && dm_info "warning: host key of $name is not approved (not in known_hosts; ask an approver: dm approve $name)"
  done <"$hosts"
  return 0
}

# dm_trust_fetch_dist TMPDIR — download the client bundle and unpack it into TMPDIR. With
# trust active the hub's signature over "devmesh-bundle-v1 <version> <sha256>" must verify.
dm_trust_fetch_dist() {
  local tmp=$1 sig version sha installed
  ssh -o ConnectTimeout=6 hub-admin dist >"$tmp/dist.tgz" || dm_die "cannot download from hub"
  if dm_trust_active; then
    sig=$(ssh -o ConnectTimeout=6 hub-admin dist sig 2>/dev/null) ||
      dm_die "the hub has no signed client bundle; nothing installed (DM_TRUST=open skips this check)"
    version=$(tar -xzOf "$tmp/dist.tgz" VERSION 2>/dev/null | head -n1)
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || dm_die "invalid bundle version"
    sha=$(tr_sha256 "$tmp/dist.tgz")
    # shellcheck disable=SC2034 # read by dm_update to re-check the copy it installs as root
    DM_DIST_SHA=$sha
    tr_verify "$(dm_allowed_signers)" "$sig" "$(tr_msg bundle "$version" "$sha")" >/dev/null ||
      dm_die "the signature of the client bundle does not verify; nothing installed"
    installed=$(dm_version)
    if [[ $installed =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $(printf '%s\n%s\n' "$installed" "$version" | sort -V | head -n1) != "$installed" ]]; then
      dm_die "the signed bundle ($version) is older than the installed client ($installed); nothing installed"
    fi
  fi
  tar -xzf "$tmp/dist.tgz" -C "$tmp"
}

# --- confirmations -----------------------------------------------------------------------
# The expected answer is NEVER shown: it is derived from a key the hub supplied, so printing it
# would let anyone just copy it. The user reads the fingerprint on the device itself (printed at
# the end of its join, or "dm trust status" there) and types its last 16 characters (96 bits).
dm_fp_tail() {
  local fp
  fp=$(tr_fingerprint "$1")
  printf '%s\n' "${fp: -16}"
}

# dm_ask_code PROMPT EXPECTED — succeed only when the typed answer equals EXPECTED.
dm_ask_code() {
  local answer
  [[ ${#2} -eq 16 ]] || return 1
  printf '%s: ' "$1" >&2
  read -r answer || return 1
  [[ $answer == "$2" ]]
}

# --yes skips every check: UNSAFE, only for tests (DM_TEST=1).
dm_yes_allowed() { [[ ${DM_TEST:-0} == 1 ]] || dm_die "--yes only works in tests (DM_TEST=1); type the fingerprint instead"; }

# --- dm approve ------------------------------------------------------------------------
# dm_approve_rows -> hub list of devices waiting for a signature (validated, TSV)
dm_approve_rows() {
  local rows name kind cpub hpub at origin need
  rows=$(ssh -o ConnectTimeout=6 hub-admin pending) || dm_die "cannot reach the hub"
  while IFS=$'\t' read -r name kind cpub hpub at origin need; do
    [[ $name =~ $TR_NAME_RE && $kind =~ ^(machine|phone|client)$ && $cpub =~ $TR_KEY_RE &&
      $need =~ ^(client|host|client\+host)$ ]] || continue
    [[ $kind == machine && $hpub =~ $TR_KEY_RE ]] || hpub=-
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$cpub" "$hpub" \
      "$(dm_trust_clean "$at")" "$(dm_trust_clean "$origin")" "$need"
  done <<<"$rows"
}

# What the hub says about a device; fingerprints are deliberately not shown.
dm_approve_show() {
  local name kind cpub hpub at origin need
  IFS=$'\t' read -r name kind cpub hpub at origin need <<<"$1"
  printf '  \033[1m%s\033[0m  %s  (needs: %s)  enrolled %s from %s\n' "$name" "$kind" "$need" "$at" "$origin" >&2
}

# dm_approve_confirm ROW SIGNER — one prompt per key that is about to be signed: the client key
# (client or signer signature) and, for machines, the host key. The expected tails are derived from
# the keys the hub supplied and are never shown; the user reads them on the new device.
dm_approve_confirm() {
  local row=$1 as_signer=$2 name kind cpub hpub need
  IFS=$'\t' read -r name kind cpub hpub _ _ need <<<"$row"
  if [[ $need == client* || $as_signer == 1 ]]; then
    dm_ask_code "$name: last 16 characters of its CLIENT key fingerprint" "$(dm_fp_tail "$cpub")" ||
      dm_die "client fingerprint does not match: nothing signed"
  fi
  if [[ $need == *host && $hpub != - ]]; then
    dm_ask_code "$name: last 16 characters of its HOST key fingerprint" "$(dm_fp_tail "$hpub")" ||
      dm_die "host fingerprint does not match: nothing signed"
  fi
}

# Approvals this device made (name<TAB>key): the local source for later revocations.
dm_approved_log() {
  local allowed
  allowed=$(dm_allowed_signers)
  if [[ -w ${allowed%/*} ]]; then printf '%s.approved\n' "$allowed"; else printf '%s/approved.tsv\n' "$DM_CACHE"; fi
}

# dm_approve_send ROW SIGNER — sign what ROW needs with this device's key and upload it.
dm_approve_send() {
  local row=$1 as_signer=$2 name kind cpub hpub at origin need key payload="" s
  IFS=$'\t' read -r name kind cpub hpub at origin need <<<"$row"
  key=$(dm_trust_key_file)
  if [[ $need == client* ]]; then
    s=$(tr_sign "$key" "$(tr_msg client "$name" "$cpub")") || s=""
    [[ -n $s ]] || dm_die "could not sign (is $key readable?)"
    payload+="client $s"$'\n'
  fi
  if [[ $need == *host && $hpub != - ]]; then
    s=$(tr_sign "$key" "$(tr_msg host "$name" "$hpub")") || s=""
    [[ -n $s ]] || dm_die "could not sign the host key"
    payload+="host $s"$'\n'
  fi
  if ((as_signer)); then
    s=$(tr_sign "$key" "$(tr_msg signer "$name" "$cpub")") || s=""
    [[ -n $s ]] || dm_die "could not sign"
    payload+="signer $s"$'\n'
  fi
  printf '%s' "$payload" | ssh -o ConnectTimeout=6 hub-admin approve "$name" >/dev/null || dm_die "the hub refused the approval of $name"
  printf '%s\t%s\n' "$name" "$cpub" >>"$(dm_approved_log)" 2>/dev/null || true
  dm_info "approved $name"
}

# dm approve [name] [--signer] [--yes] — no name: list what waits for approval.
dm_approve() {
  local name="" signer=0 yes=0 rows row
  while (($#)); do
    case $1 in
      --signer) signer=1 ;;
      --yes) yes=1 ;;
      -*) dm_die "usage: dm approve [name] [--signer]" ;;
      *) name=$1 ;;
    esac
    shift
  done
  ((! yes)) || dm_yes_allowed
  dm_trust_is_approver || dm_die "this device is not an approver (see: dm trust status)"
  rows=$(dm_approve_rows)
  if [[ -z $name ]]; then
    [[ -n $rows ]] || {
      dm_info "nothing waiting for approval"
      return 0
    }
    while read -r row; do dm_approve_show "$row"; done <<<"$rows"
    dm_info "Approve with: dm approve <name>"
    return 0
  fi
  row=$(awk -F'\t' -v n="$name" '$1 == n' <<<"$rows")
  [[ -n $row ]] || dm_die "nothing to approve for $name"
  dm_approve_show "$row"
  ((yes)) || dm_approve_confirm "$row" "$signer"
  dm_approve_send "$row" "$signer"
  dm_refresh >/dev/null 2>&1 || true
}

# --- dm trust ---------------------------------------------------------------------------
# dm_trust_set_mode — DM_TRUST=signed in node.conf (or the command to run as root).
dm_trust_set_mode() {
  local conf tmp
  conf=$(dm_conf_file)
  if [[ -w $conf ]]; then
    tmp=$(mktemp)
    { grep -v '^DM_TRUST=' "$conf" || true; } >"$tmp"
    printf 'DM_TRUST=signed\n' >>"$tmp"
    cat "$tmp" >"$conf"
    rm -f "$tmp"
  else
    printf "sudo sh -c \"sed -i.bak '/^DM_TRUST=/d' '%s' && echo DM_TRUST=signed >> '%s'\"\n" "$conf" "$conf"
  fi
}

# dm trust pin [--reset] [--yes] — take the hub's approver list and switch this device to signed
# mode. The owner's fingerprint is never displayed: type the last 16 characters of it as printed
# by "dm trust status" ON THE OWNER DEVICE. First use and --reset ask the same; --yes is test-only.
dm_trust_pin() {
  local yes=0 reset=0 rows work name type k2 key proof allowed root_cmds=() line ownerkey="" owners=0 suffix bundle
  while (($#)); do
    case $1 in
      --yes) yes=1 ;;
      --reset) reset=1 ;;
      *) dm_die "usage: dm trust pin [--reset]" ;;
    esac
    shift
  done
  ((! yes)) || dm_yes_allowed
  allowed=$(dm_allowed_signers)
  # A pinned device never re-reads its roots of trust from the hub by accident.
  if [[ -s $allowed ]] && ((! reset)); then
    dm_die "this device already trusts approvers ($allowed). To replace them on purpose: dm trust pin --reset"
  fi
  rows=$(ssh -o ConnectTimeout=6 hub-admin signers) || dm_die "cannot reach the hub"
  [[ -n $rows ]] || dm_die "the hub has no approvers yet (devmesh invite <name> --owner)"
  work=$(mktemp -d)
  while IFS=$'\t' read -r name key proof; do
    [[ $name =~ $TR_NAME_RE && $key =~ $TR_KEY_RE ]] || continue
    [[ $proof == owner ]] || tr_valid_sig "$proof" || continue
    printf '%s %s %s\n' "$name" "$key" "$proof" >>"$work/signers"
    if [[ $proof == owner ]]; then
      owners=$((owners + 1))
      ownerkey=$key
    fi
  done <<<"$rows"
  [[ -s $work/signers ]] || dm_die "the hub returned an invalid approver list"
  ((owners <= 1)) || {
    rm -rf "$work"
    dm_die "the hub lists more than one owner: refusing"
  }
  dm_info "The hub lists these approvers: $(awk '{printf "%s ", $1}' "$work/signers")"
  if ((! yes)); then
    [[ -n $ownerkey ]] || {
      rm -rf "$work"
      dm_die "the hub names no owner"
    }
    dm_ask_code "Type the last 16 characters of the OWNER device fingerprint (dm trust status, on the owner)" \
      "$(dm_fp_tail "$ownerkey")" || {
      rm -rf "$work"
      dm_die "does not match: nothing pinned"
    }
  fi
  : >"$work/allowed"
  # A reset keeps what this device already knows was revoked, and the highest epoch it saw:
  # the hub must not be able to forget a revocation by asking for a re-pin.
  local suffix
  for suffix in .revoked .epoch; do
    [[ -s $allowed$suffix ]] && cp "$allowed$suffix" "$work/allowed$suffix"
  done
  # The root is the single owner key that was confirmed; the rest only through signatures.
  tr_import_signers "$work/signers" "$work/allowed" "${ownerkey:-}" || {
    rm -rf "$work"
    dm_die "no trustworthy approver in the hub's list (the owner entry is missing)"
  }
  # Learn the revocations and the epoch now, so they are kept next to allowed_signers.
  if bundle=$(ssh -o ConnectTimeout=6 hub-admin bundle 2>/dev/null) && [[ -n $bundle ]]; then
    printf '%s\n' "$bundle" >"$work/bundle"
    tr_process_bundle "$work/allowed" "$work/bundle" 1 >/dev/null 2>&1 || dm_info "note: the hub's revocation data was not accepted yet"
  fi
  for suffix in "" .revoked .epoch; do
    if [[ ! -e $work/allowed$suffix ]]; then
      [[ -w ${allowed%/*} ]] && rm -f "$allowed$suffix"
      continue
    fi
    if [[ -w ${allowed%/*} ]]; then
      install -m 0644 "$work/allowed$suffix" "$allowed$suffix"
    else
      cp "$work/allowed$suffix" "$DM_CACHE/allowed_signers$suffix.new"
      root_cmds+=("sudo install -m 0644 '$DM_CACHE/allowed_signers$suffix.new' '$allowed$suffix'")
    fi
  done
  line=$(dm_trust_set_mode)
  [[ -z $line ]] || root_cmds+=("$line")
  rm -rf "$work"
  if ((${#root_cmds[@]})); then
    dm_info "root-owned files remain. Run:"
    printf '  %s\n' "${root_cmds[@]}" >&2
  else
    dm_info "pinned: this device now verifies keys, host keys and updates"
  fi
}

# dm trust init [--i-checked-all] — on the owner device: sign every existing device key and host
# key (migration from versions without signatures). Per device you type the last 16 characters
# of the fingerprint shown ON THAT DEVICE (dm trust status there). --i-checked-all skips that:
# DANGEROUS, it signs whatever the hub lists. --yes is test-only.
dm_trust_init() {
  local yes=0 all=0 rows row n name
  while (($#)); do
    case $1 in
      --yes) yes=1 ;;
      --i-checked-all) all=1 ;;
      *) dm_die "usage: dm trust init [--i-checked-all]" ;;
    esac
    shift
  done
  ((! yes)) || dm_yes_allowed
  dm_trust_is_approver || dm_die "run this on the owner device after: dm trust pin"
  rows=$(dm_approve_rows)
  [[ -n $rows ]] || {
    dm_info "everything is already approved"
    return 0
  }
  dm_info "Devices to approve:"
  while read -r row; do dm_approve_show "$row"; done <<<"$rows"
  n=$(grep -c . <<<"$rows")
  if ((all)); then
    dm_info "WARNING: --i-checked-all signs the keys the hub lists without checking them."
  elif ((! yes)); then
    # The rows come on fd 3: the answers are read from the terminal (stdin).
    while read -r row <&3; do
      dm_approve_confirm "$row" 0
    done 3<<<"$rows"
  fi
  while read -r row; do
    dm_approve_send "$row" 0
  done <<<"$rows"
  dm_refresh >/dev/null 2>&1 || true
  dm_info "$n device(s) approved. Next: on each machine run: dm trust pin"
}

dm_trust_status() {
  local allowed name key pending f
  allowed=$(dm_allowed_signers)
  printf 'mode      %s\n' "$(tr_mode "$allowed" "${DM_TRUST:-}")"
  # What the owner types when pinning or approving this device (read it HERE, never from the hub).
  if f=$(dm_trust_key_file) && [[ -r $f.pub ]]; then
    printf 'this device, client key  %s\n' "$(tr_fingerprint "$(dm_trust_my_pub)")"
  fi
  for f in /etc/ssh/ssh_host_ed25519_key.pub "$(dirname "$(dm_conf_file)")/ssh_host_ed25519_key.pub"; do
    [[ -r $f ]] && printf 'this device, host key    %s\n' "$(tr_fingerprint "$(awk '{print $1 " " $2}' "$f")")" && break
  done
  if [[ -s $allowed ]]; then
    printf 'approvers %s\n' "$allowed"
    while IFS=$'\t' read -r name key; do
      printf '  %s  %s\n' "$name" "$(tr_fingerprint "$key")"
    done < <(awk '{print $1 "\t" $3 " " $4}' "$allowed")
    if dm_trust_is_approver; then printf 'this device is an approver\n'; fi
  else
    printf 'approvers none on this device (dm trust pin)\n'
  fi
  pending=$(ssh -o ConnectTimeout=6 hub-admin pending 2>/dev/null | grep -c . || true)
  [[ $pending == 0 ]] || printf 'waiting for approval: %s\n' "$pending"
  return 0
}

# dm_trust_revoke NAME — an approver signs the revocation of NAME's client key (before "dm rm") and
# the new revocation epoch, so no device accepts an old approval of that key again or a bundle that
# hides the revocation. The key never comes from the hub alone: an approver's key is read from the
# LOCAL allowed_signers, a client's from the local approval log; without a local record the user
# types the last 16 characters of the device's fingerprint. Not an approver: no-op.
dm_trust_revoke() {
  local name=$1 allowed key hubkey mine sig esig log serial hash tmp
  dm_trust_is_approver || return 0
  allowed=$(dm_allowed_signers)
  mine=$(dm_trust_my_pub)
  log=$(dm_approved_log)
  hubkey=$(ssh -o ConnectTimeout=6 hub-admin bundle 2>/dev/null |
    awk -v n="$name" '($1 == "client" || $1 == "signer") && $2 == n {print $3 " " $4; exit}')
  key=$(awk -v n="$name" '$1 == n {print $3 " " $4; exit}' "$allowed")
  [[ -n $key ]] || key=$(awk -F'\t' -v n="$name" '$1 == n {k = $2} END {print k}' "$log" 2>/dev/null)
  if [[ -z $key && -z $hubkey ]]; then
    if ssh -o ConnectTimeout=6 hub-admin pending 2>/dev/null | cut -f1 | grep -qx "$name"; then
      dm_info "$name was never approved: no revocation needed"
      return 0
    fi
    dm_die "the hub has no approved key for $name: not revoking (nothing removed)"
  fi
  if [[ -n $key && -n $hubkey && $key != "$hubkey" ]]; then
    dm_die "the hub's key for $name differs from the one this device approved: nothing revoked"
  fi
  if [[ -z $key ]]; then
    dm_ask_code "No local record of $name: type the last 16 characters of its client fingerprint (dm trust status there)" \
      "$(dm_fp_tail "$hubkey")" || dm_die "does not match: nothing revoked"
    key=$hubkey
  fi
  [[ $key =~ $TR_KEY_RE ]] || dm_die "invalid key for $name"
  [[ $key != "$mine" ]] || dm_die "refusing to revoke this device's own key"
  if awk -v k="$key" -v n="$name" '$3 " " $4 == k && $1 != n {f = 1} END {exit !f}' "$allowed"; then
    dm_die "that key is an approver under another name: refusing to revoke it as $name"
  fi
  if awk -v k="$key" '$3 " " $4 == k {f = 1} END {exit !f}' "$allowed" && [[ $(grep -c . "$allowed") -le 1 ]]; then
    dm_die "refusing to revoke the last approver"
  fi
  # New revocation set = locally verified revocations + this one; serial = highest seen + 1.
  tmp=$(mktemp)
  { cat "$(tr_revoked_file "$allowed")" 2>/dev/null || true; } | awk -v k="$key" '$2 " " $3 != k' >"$tmp"
  printf '%s %s\n' "$name" "$key" >>"$tmp"
  hash=$(tr_rev_hash "$tmp")
  rm -f "$tmp"
  read -r serial _ <<<"$(tr_epoch_state "$allowed")"
  serial=$((serial + 1))
  sig=$(tr_sign "$(dm_trust_key_file)" "$(tr_msg revoke "$name" "$key")") || sig=""
  [[ -n $sig ]] || dm_die "could not sign the revocation"
  esig=$(tr_sign "$(dm_trust_key_file)" "$(tr_msg epoch "$serial" "$hash")") || esig=""
  [[ -n $esig ]] || dm_die "could not sign the epoch"
  printf 'revoke %s\nepoch %s\n' "$sig" "$esig" | ssh -o ConnectTimeout=6 hub-admin revoke "$name" >/dev/null ||
    dm_die "the hub refused the revocation of $name (out of date? run: dm refresh)"
  dm_info "revocation of $name signed (epoch $serial)"
}

dm_trust() {
  local sub=${1:-status}
  shift || true
  case $sub in
    init) dm_trust_init "$@" ;;
    pin) dm_trust_pin "$@" ;;
    status) dm_trust_status ;;
    *) dm_die "usage: dm trust init | pin | status" ;;
  esac
}
