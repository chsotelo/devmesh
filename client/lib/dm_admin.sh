# shellcheck shell=bash
# Devices (via the hub's restricted dmadmin account), Wake-on-LAN, self-update, menu.

dm_devices() { ssh -o ConnectTimeout=6 hub-admin ls; }

# dm_copy TEXT — put TEXT on the clipboard when the platform has one.
dm_copy() {
  local c
  for c in pbcopy termux-clipboard-set wl-copy "xclip -selection clipboard" "xsel -b"; do
    command -v "${c%% *}" >/dev/null || continue
    # shellcheck disable=SC2086 # the command may carry its own flags
    printf '%s' "$1" | $c 2>/dev/null && return 0
  done
  return 1
}

# dm add <name> [--lan <label>] [--watch-hub] — one universal join line for any device
# (Linux, Mac, Android/Termux), copied to the clipboard and shown as a QR code. No questions:
# the device detects its own type. --lan (Wake-on-LAN group) and --watch-hub (Linux
# machine that alerts if the hub dies) are optional and validated here, before the hub.
dm_add() {
  local name="" lan="" watch=0 out join args
  while (($#)); do
    case $1 in
      --lan)
        lan=${2:-}
        shift
        ;;
      --watch-hub) watch=1 ;;
      -*) dm_die "unknown option $1 (usage: dm add <name> [--lan <label>] [--watch-hub])" ;;
      *)
        [[ -z $name ]] || dm_die "one name only (usage: dm add <name> [--lan <label>] [--watch-hub])"
        name=$1
        ;;
    esac
    shift
  done
  if [[ -z $name ]]; then
    printf 'Name for the new device (e.g. tablet, lap, pc2): ' >&2
    read -r name
  fi
  [[ $name =~ ^[a-z][a-z0-9-]{0,15}$ && $name != hub* && $name != *-b ]] ||
    dm_die "invalid name '$name': lowercase letters, digits and '-', starting with a letter, max 16 (e.g. tablet, pc-2)"
  [[ -z $lan || $lan =~ ^[a-z0-9][a-z0-9-]{0,15}$ ]] ||
    dm_die "invalid --lan '$lan': one word, lowercase letters, digits and '-' (e.g. home, office)"
  args=(invite "$name")
  [[ -n $lan ]] && args+=(--lan "$lan")
  ((watch)) && args+=(--watch-hub)
  out=$(ssh -o ConnectTimeout=6 hub-admin "${args[@]}") || dm_die "the hub refused the invite (see the message above)"
  join=$(sed -n 's/^JOIN: //p' <<<"$out")
  [[ -n $join ]] || dm_die "unexpected answer from the hub"
  printf '\n%s\n\n' "$(grep -v '^JOIN: ' <<<"$out" | sed '/^$/d')" >&2
  printf '  \033[1m%s\033[0m\n\n' "$join"
  if dm_copy "$join"; then
    dm_info "Copied to the clipboard. Paste it on the new device."
  fi
  if command -v qrencode >/dev/null; then
    dm_info "Or scan it with the phone camera, then paste it in Termux:"
    qrencode -t ANSIUTF8 -m 2 "$join" >&2
  fi
}

dm_rm() {
  local name
  name=$(dm_hosts | awk -F'\t' '{print $1 "\t" $2}' | dm_pick "remove device" --delimiter=$'\t') || return 0
  name=${name%%$'\t'*}
  dm_confirm "$name" || dm_die "not confirmed"
  dm_trust_revoke "$name"
  ssh -o ConnectTimeout=6 hub-admin remove "$name" --confirm "$name"
  dm_refresh >/dev/null 2>&1 || true
}

# dm_wake MACHINE — magic packet sent by another online machine on the same LAN.
dm_wake() {
  local target=${1:-} mac lan relay
  dm_require_machines
  [[ -n $target ]] || target=$(dm_machines | dm_pick "wake machine") || return 0
  mac=$(dm_host_field "$target" mac)
  lan=$(dm_host_field "$target" lan)
  [[ $mac != - && -n $mac ]] || dm_die "$target has no MAC registered"
  [[ $lan != - && -n $lan ]] || dm_die "$target has no LAN label; Wake-on-LAN needs a relay on its LAN"
  for relay in $(dm_hosts machine | awk -F'\t' -v l="$lan" -v t="$target" '$7 == l && $1 != t {print $1}'); do
    if dm_run "$relay" dm _wol "$mac" 2>/dev/null; then
      dm_info "magic packet sent to $target via $relay"
      return 0
    fi
  done
  dm_die "no online machine on LAN '$lan' to relay the wake-up"
}

# dm_update: fetch the client bundle over the authenticated SSH channel and reinstall.
dm_update() (
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  local version share
  dm_trust_fetch_dist "$tmp"
  version=$(cat "$tmp/VERSION")
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || dm_die "invalid bundle version"
  if [[ $(dm_platform) == termux ]]; then
    DM_DIST_DIR="$tmp/client" DM_VERSION=$version bash -c \
      'source "$DM_DIST_DIR/lib/bootstrap_termux.sh" && termux_install_client'
  elif [[ $(dm_platform) == macos ]]; then
    # shellcheck disable=SC2016 # expanded by the child shell
    DM_DIST_DIR="$tmp/client" DM_VERSION=$version "$BASH" -c \
      'source "$DM_DIST_DIR/lib/bootstrap_macos.sh" && macos_install_client'
  else
    # The installer runs as root: it must not read scripts from a directory the user can change.
    local rt
    rt=$(sudo mktemp -d)
    cat "$tmp/dist.tgz" | sudo tee "$rt/dist.tgz" >/dev/null
    if [[ -n ${DM_DIST_SHA:-} && $(sudo sha256sum "$rt/dist.tgz" | cut -d' ' -f1) != "$DM_DIST_SHA" ]]; then
      sudo rm -rf "$rt"
      dm_die "the bundle changed after verification; nothing installed"
    fi
    sudo tar -xzf "$rt/dist.tgz" -C "$rt"
    sudo env DM_DIST_DIR="$rt/client" DM_VERSION="$version" bash -c \
      'source "$DM_DIST_DIR/lib/bootstrap_linux.sh" && linux_install_client && systemctl daemon-reload'
    sudo rm -rf "$rt"
  fi
  share=$(dm_share_dir)
  dm_info "devmesh client $(cat "$share/VERSION")"
)

# dm mesh: what other devices can reach on this machine through the mesh. Changing it needs
# root, so the exact sudo command is printed instead of asking for a password here.
dm_mesh() {
  [[ $(dm_platform) == linux ]] || dm_die "the mesh firewall exists on Linux machines only (macOS and Termux have none)"
  local entry
  printf 'Open on the mesh (every other port is blocked):\n'
  printf '  ssh      tcp/22\n  mosh     udp/60000-61000\n  ping\n'
  # shellcheck disable=SC2086 # the list is space-separated
  for entry in ${DM_MESH_OPEN:-}; do
    printf '  extra    %s\n' "$entry"
  done
  printf '\nChange it (root):\n'
  printf '  sudo devmesh-node mesh open <tcp|udp>/<port>     e.g. tcp/8000 or tcp/8000-8010\n'
  printf '  sudo devmesh-node mesh close <tcp|udp>/<port>\n'
  printf 'For web servers and databases prefer "dm port": it goes inside SSH and opens nothing.\n'
}

dm_version() { cat "$(dm_share_dir)/VERSION" 2>/dev/null || printf 'dev\n'; }

dm_help() {
  cat <<'EOF'
dm                      workspace: the panel + one tab per open terminal, in one screen
                        (tap a tab to switch · tabs reconnect by themselves · Ctrl+a d: leave)
dm new [machine]        new terminal, guided: machine → project
dm list                 plain list of every terminal on every machine; pick to enter
dm go [machine] [name]  enter a machine's terminal (default "main"); path A, falls back to B
dm close                close a terminal (asks to type its name)
dm who                  terminals as a table: id, command, agent state, origin, clients
dm send [file]          send a file to a machine (~/devmesh-inbox or a project)
dm fetch                bring a file from a machine's inbox/outbox
dm port [stop]          preview a machine's dev server here (http://localhost:<port>)
dm mesh                 what this machine exposes on the mesh (Linux) + how to open a port
dm add <name>           one join line for any device (copied + QR); [--lan home] [--watch-hub]
dm devices | rm         list / revoke devices (via the hub)
dm wake [machine]       Wake-on-LAN through another machine on the same LAN
dm refresh | update     pull device list and ssh config | update this client
dm repoint <ip|host>    follow the hub to a new address (after "make restore"); checks its host key
dm approve [name]       list / approve devices waiting for approval (approver devices only)
dm trust init|pin|status  signed keys: sign existing devices (owner) | trust the approvers | show
dm agent <state>        for tool hooks: working | waiting | idle | clear
dm watch [on|off]       phone/desktop alerts when a terminal waits for you (Approve/Reject)
dm vscode on|off|status VS Code terminals inside tmux on this machine (opt-in; status shows which)
dm _key / _watch        machine-side helpers for dm watch (not for direct use)
Networks that block UDP: dm falls back to the reverse tunnel (path B) automatically.
EOF
}
