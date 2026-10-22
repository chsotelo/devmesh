# shellcheck shell=bash
# Enrollment of an Android tablet/phone in Termux. No root: everything lives in $HOME/$PREFIX.
# The WireGuard tunnel itself runs in the official WireGuard app (imported from a file).

# shellcheck source=bootstrap_common.sh
source "$DM_DIST_DIR/lib/bootstrap_common.sh"

TX_PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
TX_CONF_DIR=${TX_CONF_DIR:-$HOME/.config/devmesh}
TX_DOWNLOADS=${TX_DOWNLOADS:-$HOME/storage/downloads}
readonly TX_MTU=1280

termux_pkg_install() {
  bs_log "installing packages"
  pkg install -y openssh mosh fzf tmux wireguard-tools tar coreutils >/dev/null
}

termux_keys() {
  install -d -m 0700 "$HOME/.ssh" "$TX_CONF_DIR"
  bs_wg_key "$TX_CONF_DIR/wg.key"
  bs_ssh_keygen "$HOME/.ssh/id_devmesh" "devmesh:$DM_NAME"
  bs_hub_known_hosts >"$HOME/.ssh/devmesh_known_hosts"
}

termux_enroll_fields() {
  printf 'wg %s\n' "$(wg pubkey <"$TX_CONF_DIR/wg.key")"
  printf 'client %s\n' "$(bs_pub_bare "$HOME/.ssh/id_devmesh.pub")"
  printf 'os android\n'
}

termux_install_client() {
  local share="$TX_PREFIX/share/devmesh"
  rm -rf "${share:?}/lib" "${share:?}/shell" "${share:?}/hooks" "${share:?}/tmux"
  install -d "$share" "$TX_PREFIX/bin"
  cp -R "$DM_DIST_DIR/lib" "$DM_DIST_DIR/shell" "$DM_DIST_DIR/hooks" "$DM_DIST_DIR/tmux" "$share/"
  install -m 0755 "$DM_DIST_DIR/bin/dm" "$TX_PREFIX/bin/dm"
  printf '%s\n' "$DM_VERSION" >"$share/VERSION"
  bs_install_tui "$DM_DIST_DIR/bin" "$share/bin"
  bs_ensure_line "$HOME/.bashrc" "[ -r $share/shell/devmesh.sh ] && . $share/shell/devmesh.sh"
  termux_extra_keys
}

# Touch-friendly keys row for Claude/Codex TUIs (Esc, Ctrl, Tab, arrows, paging). Only added
# when the user has no extra-keys line of their own; an existing one is never modified.
termux_extra_keys() {
  local props="$HOME/.termux/termux.properties"
  local row="extra-keys = [['ESC','/','-','|','HOME','UP','END','PGUP'],['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN','ENTER']]"
  if [[ -f $props ]] && grep -Eq '^[[:space:]]*extra-keys[[:space:]]*=' "$props"; then
    bs_log "$props already sets extra-keys; to add devmesh's row, replace that line with: $row"
    return 0
  fi
  install -d "$HOME/.termux"
  # Keep the appended line on its own line when the existing file lacks a final newline.
  if [[ -s $props && -n $(tail -c 1 "$props") ]]; then
    printf '\n' >>"$props"
  fi
  printf '%s\n' "$row" >>"$props"
  if command -v termux-reload-settings >/dev/null; then
    termux-reload-settings || true
  fi
}

# The WireGuard app imports a .conf from shared storage; the file holds this device's
# private key, so it is deleted right after the user confirms the import.
termux_wireguard_import() {
  local file="$TX_DOWNLOADS/devmesh-$DM_NAME.conf"
  if [[ ! -d $TX_DOWNLOADS ]]; then
    bs_log "allow storage access in the Android prompt"
    termux-setup-storage || true
    local _
    for _ in $(seq 1 30); do
      [[ -d $TX_DOWNLOADS ]] && break
      sleep 1
    done
    [[ -d $TX_DOWNLOADS ]] || bs_die "no access to shared storage (run termux-setup-storage)"
  fi
  # Holds this device's private key: removed on any exit, including Ctrl-C / EOF. Keeps
  # the bootstrap's own cleanup of its work dir (throwaway key) in the same trap.
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$file'; rm -rf '${dm_work:-/nonexistent}'" EXIT
  (umask 077 && bs_wg_conf "$(cat "$TX_CONF_DIR/wg.key")" "$TX_MTU" >"$file")
  printf '\nOpen the WireGuard app → + → "Import from file or archive" → Download/%s\n' "${file##*/}"
  printf 'Turn the tunnel on, then press Enter here to delete the file... '
  # From the terminal: stdin may be the pipe that delivered this script.
  read -r _ </dev/tty || true
  rm -f "$file"
  # shellcheck disable=SC2064
  trap "rm -rf '${dm_work:-/nonexistent}'" EXIT
  bs_log "removed $file"
}

bootstrap_main() {
  bs_require_env
  # Installed files must be world-readable; secrets are created with explicit modes.
  umask 022
  [[ -n ${TERMUX_VERSION:-} || -d /data/data/com.termux ]] || bs_die "this bootstrap is for Termux"
  termux_pkg_install
  termux_keys
  bs_trust_setup "$TX_CONF_DIR/allowed_signers" "$HOME/.ssh/id_devmesh.pub"
  if bs_already_enrolled "$TX_CONF_DIR/node.conf"; then
    bs_log "already enrolled as $DM_NAME; re-applying local config"
  else
    bs_enroll "$HOME/.ssh/devmesh_known_hosts" < <(termux_enroll_fields)
    bs_node_conf >"$TX_CONF_DIR/node.conf"
  fi
  bs_node_conf >"$TX_CONF_DIR/node.conf"
  termux_install_client
  bs_ensure_include "$HOME/.ssh/config"
  bs_ssh_bootstrap_config >"$HOME/.ssh/config.d/devmesh"
  termux_wireguard_import
  dm refresh || bs_log "dm refresh failed; run it again once WireGuard is on"
  printf '\n\033[32m%s ✓\033[0m  wg %s · run "dm" to see every machine\n' "$DM_NAME" "$DM_IP"
  bs_approve_hint "$HOME/.ssh/id_devmesh.pub"
}
