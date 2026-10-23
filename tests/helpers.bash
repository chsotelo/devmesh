# shellcheck shell=bash
# Shared bats setup: an isolated hub rooted in $BATS_TEST_TMPDIR, stubs first in PATH.

REPO=$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)
export REPO

setup_hub() {
  # Physical path: macOS /var is a symlink and bsdtar refuses to extract through it.
  BATS_TEST_TMPDIR=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  local t=$BATS_TEST_TMPDIR
  export PATH="$REPO/tests/stubs:$PATH"
  export STUB_LOG="$t/stub.log" STUB_IPT="$t/ipt.db"
  : >"$STUB_LOG"
  export DEVMESH_ALLOW_NONROOT=1
  export DEVMESH_ETC="$t/etc/devmesh" DEVMESH_WG_DIR="$t/etc/wireguard"
  export DEVMESH_WEBROOT="$t/www" DEVMESH_STATE="$t/state" DEVMESH_BACKUP_DIR="$t/backups"
  export DEVMESH_SHARE="$t/share" DEVMESH_LIB="$REPO/server/lib"
  export DEVMESH_HOST_KEY_PUB="$t/ssh/ssh_host_ed25519_key.pub" HUB_SSH_PORT=2222
  export HUB_HOST=hub.example.test
  unset DEVMESH_NOW SSH_ORIGINAL_COMMAND SSH_CONNECTION
  mkdir -p "$DEVMESH_ETC/invites" "$DEVMESH_ETC/ssh" "$DEVMESH_WG_DIR" "$t/ssh" \
    "$DEVMESH_SHARE/templates" "$DEVMESH_WEBROOT/j" "$DEVMESH_STATE"
  ssh-keygen -q -t ed25519 -N '' -f "$t/ssh/ssh_host_ed25519_key"
  wg genkey >"$DEVMESH_ETC/hub.key"
  : >"$DEVMESH_ETC/registry.tsv"
  cp "$REPO"/server/templates/*.tpl "$DEVMESH_SHARE/templates/"
  cp -R "$REPO/client" "$DEVMESH_SHARE/client"
  cp "$REPO/VERSION" "$DEVMESH_SHARE/VERSION"
}

devmesh() { bash "$REPO/server/sbin/devmesh" "$@"; }

# Load hub libraries into the current shell (unit tests).
load_hub_libs() {
  local l
  for l in common registry render trust invite enroll devices status admin backup; do
    # shellcheck source=/dev/null
    source "$REPO/server/lib/$l.sh"
  done
  load_hub_conf
  reg_init
}

# new_ssh_pub PATH — real ed25519 key, prints the bare public key.
new_ssh_pub() {
  ssh-keygen -q -t ed25519 -N '' -C test -f "$1"
  awk '{print $1 " " $2}' "$1.pub"
}

new_wg_pub() { wg genkey | wg pubkey; }

# invite_code: the code of the only pending invite.
invite_code() {
  local f
  f=$(ls "$DEVMESH_ETC/invites")
  printf '%s\n' "${f%.env}"
}

# enroll_machine NAME — full invite + enroll with fresh keys; prints the code used.
enroll_machine() {
  local name=$1 t=$BATS_TEST_TMPDIR/keys-$1 code
  mkdir -p "$t"
  devmesh invite "$name" >/dev/null
  code=$(invite_code)
  {
    printf 'kind machine\n'
    printf 'wg %s\n' "$(new_wg_pub)"
    printf 'client %s\n' "$(new_ssh_pub "$t/client")"
    printf 'tunnel %s\n' "$(new_ssh_pub "$t/tunnel")"
    printf 'host %s\n' "$(new_ssh_pub "$t/host")"
    printf 'user dev\n'
    printf 'mac AA:BB:CC:DD:EE:01\n'
  } | devmesh _enroll "$code" >/dev/null
}

enroll_phone() {
  local name=$1 t=$BATS_TEST_TMPDIR/keys-$1 code
  mkdir -p "$t"
  devmesh invite "$name" --phone >/dev/null
  code=$(invite_code)
  {
    printf 'kind phone\n'
    printf 'wg %s\n' "$(new_wg_pub)"
    printf 'client %s\n' "$(new_ssh_pub "$t/client")"
  } | devmesh _enroll "$code" >/dev/null
}

# Client side: dm libraries with a fake enrolled node.
setup_client() {
  BATS_TEST_TMPDIR=$(cd "$BATS_TEST_TMPDIR" && pwd -P)
  local t=$BATS_TEST_TMPDIR
  export PATH="$REPO/tests/stubs:$PATH"
  export STUB_LOG="$t/stub.log" STUB_SSH_DIR="$t/ssh-replies"
  : >"$STUB_LOG"
  export HOME="$t/home" DM_CACHE="$t/cache" DM_CONF="$t/node.conf" DM_SHARE="$REPO/client"
  mkdir -p "$HOME/.ssh" "$DM_CACHE" "$STUB_SSH_DIR"
  printf 'DM_NAME=tablet\nDM_KIND=phone\nDM_HUB_HOST=hub.example.test\n' >"$DM_CONF"
  printf 'lap\tmachine\t10.73.0.2\t2202\t22\tdev\thome\taa:bb:cc:dd:ee:01\n' >"$DM_CACHE/hosts.tsv"
  printf 'pc2\tmachine\t10.73.0.3\t2203\t24\tdev\thome\t-\n' >>"$DM_CACHE/hosts.tsv"
  printf 'tablet\tphone\t10.73.0.4\t-\t-\t-\t-\t-\n' >>"$DM_CACHE/hosts.tsv"
  local l
  for l in dm_core dm_remote dm_terms dm_files dm_admin dm_repoint dm_trust dm_ui dm_app dm_workspace dm_layout dm_watch dm_vscode tui_target dm_feed; do
    # shellcheck source=/dev/null
    source "$REPO/client/lib/$l.sh"
  done
  dm_load_conf
}

# ssh_reply ALIAS "CMD WORDS" CONTENT — canned output of a remote command.
ssh_reply() {
  mkdir -p "$STUB_SSH_DIR/$1"
  printf '%s' "$3" >"$STUB_SSH_DIR/$1/$(tr ' ' '_' <<<"$2")"
}

# min_cfg [HOSTNAME] — smallest ssh_config "dm refresh" accepts: hub-admin with the trust options.
min_cfg() {
  printf 'Host hub-admin\n  HostName %s\n  HostKeyAlias %s\n  IdentityFile ~/.ssh/id_devmesh\n  IdentitiesOnly yes\n' \
    "${1:-h}" "${DM_HUB_HOST:-hub.example.test}"
  printf '  UserKnownHostsFile ~/.ssh/devmesh_known_hosts\n  StrictHostKeyChecking yes\n'
}
