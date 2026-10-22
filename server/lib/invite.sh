# shellcheck shell=bash
# invite: reserve a slot, mint a one-use throwaway SSH key, publish the bootstrap script.
# The bootstrap carries only public data + the throwaway key; devices generate their own keys.

usage_invite() {
  cat >&2 <<'EOF'
usage: devmesh invite <name> [--lan <lan>] [--watch-hub] [--machine | --phone | --client] [--owner]
  The device type is detected on the device itself (Linux = machine, Android/Termux = phone,
  macOS = client). Pass a type only to restrict the code to that kind of device.
  --owner marks the device as the first approver (only while the hub has none).
EOF
  exit 2
}

# Bundle the client files the bootstrap installs (base64 tar.gz).
client_dist_b64() {
  [[ -d $DEVMESH_SHARE/client ]] || die "missing client dist in $DEVMESH_SHARE/client"
  # The dm-tui binaries (several MB each) stay out of the enrollment script: "dm update" installs them.
  tar -C "$DEVMESH_SHARE" --exclude='client/bin/dm-tui-*' -czf - client | base64 | tr -d '\n' | fold -w 76
  printf '\n'
}

devmesh_version() { cat "$DEVMESH_SHARE/VERSION" 2>/dev/null || printf '0.0.0\n'; }

# render_template FILE KEY=VALUE... : replaces @@KEY@@ with VALUE (no sed escaping issues).
render_template() {
  local file=$1 content pair key value
  shift
  # bash >= 5.2 would expand "&" in the replacement to the matched text.
  shopt -u patsub_replacement 2>/dev/null || true
  content=$(<"$file")
  for pair in "$@"; do
    key=${pair%%=*}
    value=${pair#*=}
    content=${content//@@${key}@@/$value}
  done
  [[ $content != *@@*@@* ]] || die "unrendered placeholder in $file"
  printf '%s\n' "$content"
}

cmd_invite() {
  local name="" kind=auto lan=- watch=0 owner=0
  while (($#)); do
    case $1 in
      --machine) kind=machine ;;
      --phone) kind=phone ;;
      --client) kind=client ;;
      --lan)
        lan=${2:-}
        shift
        ;;
      --watch-hub) watch=1 ;;
      --owner) owner=1 ;;
      -*) usage_invite ;;
      *)
        [[ -z $name ]] || usage_invite
        name=$1
        ;;
    esac
    shift
  done
  valid_name "$name" || die "invalid name '$name' (a-z, 0-9, '-', max 16, must start with a letter, not 'hub*' or '*-b')"
  valid_lan "$lan" || die "invalid lan '$lan'"
  [[ $kind == auto || $kind == machine || $watch == 0 ]] || die "--watch-hub is only for machines"

  lock_acquire
  invite_gc || true
  reg_exists "$name" && die "device '$name' already exists"
  invite_name_taken "$name" && die "an invite for '$name' is already pending"
  if ((owner)); then
    signers_exist && die "this hub already has an approver; an existing approver adds more (dm approve --signer)"
    invite_values INV_OWNER | grep -qx 1 && die "an owner invite is already pending"
  fi

  # Only the IP is reserved now; tunnel port and color are assigned at enrollment, once
  # the device has said what it is.
  local ip code pass expires tmpdir topic=-
  ip=$(alloc_ip)
  ((watch)) && topic="devmesh-$(random_code | tr '[:upper:]' '[:lower:]')$(random_code | tr '[:upper:]' '[:lower:]')"
  code=$(random_code)
  # Second secret, printed only to the inviter and never sent to the web server.
  pass=$(random_code)
  expires=$(($(now_epoch) + INVITE_TTL))

  tmpdir=$(mktemp -d)
  cleanup_add "$tmpdir"
  ssh-keygen -q -t ed25519 -N "$pass" -C "devmesh-enroll:$name" -f "$tmpdir/k" || die "ssh-keygen failed"

  {
    printf 'INV_NAME=%q\nINV_KIND=%q\nINV_IP=%q\nINV_PORT=-\nINV_COLOR=-\n' "$name" "$kind" "$ip"
    printf 'INV_LAN=%q\nINV_WATCH=%q\nINV_EXPIRES=%q\n' "$lan" "$topic" "$expires"
    printf 'INV_PUB=%q\nINV_OWNER=%q\n' "$(ssh_key_bare "$(cat "$tmpdir/k.pub")")" "$owner"
  } | atomic_write "$(invite_path "$code")" 0600

  local pin=""
  hub_ip_mode && pin=$(hub_pin)
  mkdir -p "$DEVMESH_WEBROOT/j"
  render_template "$DEVMESH_SHARE/templates/enroll.sh.tpl" \
    "NAME=$name" "IP=$ip" "LAN=$lan" "WATCH_TOPIC=$topic" "CODE=$code" \
    "HUB_HOST=$HUB_HOST" "HUB_PIN=$pin" "HUB_IP=$HUB_IP" "WG_PORT=$WG_PORT" "HUB_SSH_PORT=$HUB_SSH_PORT" \
    "WG_IFACE=$WG_IFACE" "SUBNET_PREFIX=$SUBNET_PREFIX" "HUB_WG_PUB=$(hub_wg_pub)" \
    "HUB_HOST_KEY=$(hub_host_key)" "VERSION=$(devmesh_version)" \
    "OWNER=$owner" "EPOCH=$(epoch_line)" "SIGNERS=$(signers_rows | awk -F'\t' '{print $1 " " $2 " " $3}')" \
    "ENROLL_KEY=$(cat "$tmpdir/k")" "CLIENT_DIST=$(client_dist_b64)" |
    atomic_write "$DEVMESH_WEBROOT/j/$code" 0644

  apply_all
  audit "invite $name kind=$kind ip=$ip expires=$(fmt_iso "$expires")"
  print_invite "$name" "$code" "$pass" "$topic"
}

# The whole join is one line, identical for Linux, macOS and Termux. "JOIN:" makes it
# easy for "dm add" to pick up (clipboard, QR code).
print_invite() {
  local name=$1 code=$2 pass=$3 topic=$4
  printf 'Add "%s": paste this on the device (Linux, Mac or Android/Termux).\n' "$name"
  printf 'Single use, valid %s min. It contains a secret: do not share it.\n\n' $((INVITE_TTL / 60))
  if hub_ip_mode; then
    # No CA vouches for the hub: -k skips CA validation, --pinnedpubkey ties the
    # connection to the hub's own certificate (curl still enforces the pin with -k).
    printf "JOIN: curl -fsSL --pinnedpubkey 'sha256//%s' -k https://%s/j/%s | sh -s %s\n\n" \
      "$(hub_pin)" "$(hub_url_authority)" "$code" "$pass"
  else
    printf 'JOIN: curl -fsSL https://%s/j/%s | sh -s %s\n\n' "$HUB_HOST" "$code" "$pass"
  fi
  [[ $topic == - ]] || printf 'Hub watcher (Linux machines): subscribe the ntfy app to https://ntfy.sh/%s\n' "$topic"
  return 0
}

# Drop expired invites: record, published script and (via apply) its throwaway key.
invite_gc() {
  local code now changed=0
  now=$(now_epoch)
  while read -r code; do
    [[ -n $code ]] || continue
    invite_load "$code" || continue
    ((INV_EXPIRES <= now)) || continue
    invite_drop "$code"
    changed=1
  done < <(invite_codes)
  return $((1 - changed))
}

invite_drop() {
  rm -f "$(invite_path "$1")" "$DEVMESH_WEBROOT/j/$1"
}

cmd_gc() {
  lock_acquire
  if invite_gc; then
    apply_all
    audit "gc: expired invites removed"
  fi
  return 0
}
