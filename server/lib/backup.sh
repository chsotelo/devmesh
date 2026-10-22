# shellcheck shell=bash
# Backup = hub state only (code lives in git). Encrypted with age to the owner's key;
# the hub never holds the private identity, so a stolen backup is useless.

# Paths relative to / included in a backup (missing ones are skipped). DEVMESH_ETC covers
# hub.conf, the registry, keys and (IP mode) the self-signed certificate in tls/, so a
# restored hub keeps the key its devices pinned.
backup_paths() {
  local p
  printf '%s\n' "${DEVMESH_ETC#/}"
  for p in "${DEVMESH_HOST_KEY_PUB%.pub}" "$DEVMESH_HOST_KEY_PUB" /var/lib/ntfy/user.db; do
    # Never list a file twice (it is already inside DEVMESH_ETC): tar would store the
    # second copy as a hardlink, which restore rightly refuses.
    [[ $p == "$DEVMESH_ETC"/* ]] && continue
    [[ -e ${DEVMESH_ROOT:-}$p ]] && printf '%s\n' "${p#/}"
  done
  return 0
}

cmd_backup() {
  local recipients="$DEVMESH_ETC/backup.recipients" out ts paths=()
  [[ -s $recipients ]] || die "no age recipients in $recipients"
  command -v age >/dev/null 2>&1 || die "age is not installed"
  mkdir -p "$DEVMESH_BACKUP_DIR"
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  out="$DEVMESH_BACKUP_DIR/devmesh-$ts.tar.gz.age"
  mapfile -t paths < <(backup_paths)
  tar -C "${DEVMESH_ROOT:-/}" -czf - "${paths[@]}" | age -R "$recipients" -o "$out.tmp"
  mv -f "$out.tmp" "$out"
  chmod 0600 "$out"
  backup_prune
  audit "backup written: $out"
  printf '%s\n' "$out"
}

backup_prune() {
  local files=() i
  mapfile -t files < <(find "$DEVMESH_BACKUP_DIR" -maxdepth 1 -name 'devmesh-*.tar.gz.age' | sort -r)
  for ((i = BACKUP_KEEP; i < ${#files[@]}; i++)); do
    rm -f -- "${files[$i]}"
  done
}

cmd_backup_latest() {
  local latest
  latest=$(find "$DEVMESH_BACKUP_DIR" -maxdepth 1 -name 'devmesh-*.tar.gz.age' 2>/dev/null | sort -r | head -n1)
  [[ -n $latest ]] || die "no backup yet"
  cat "$latest"
}

regex_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }

# restore <tar.gz>: already decrypted on the owner's machine. Only known paths are extracted.
cmd_restore() {
  local tarball=${1:-} entry allowed
  [[ -r $tarball ]] || die "usage: devmesh restore <state.tar.gz>"
  local etc_re key_re
  etc_re=$(regex_escape "${DEVMESH_ETC#/}")
  key_re=$(regex_escape "${DEVMESH_HOST_KEY_PUB#/}")
  key_re=${key_re%\\.pub}
  allowed="^($etc_re|$key_re(\\.pub)?|var/lib/ntfy/user\\.db)(/|$)"
  while read -r entry; do
    entry=${entry#./}
    [[ $entry =~ $allowed && $entry != *..* ]] || die "unexpected path in backup: $entry"
  done < <(tar -tzf "$tarball")
  # Only plain files and directories, no setuid/setgid: a symlink entry could redirect
  # later entries anywhere on the hub (extraction runs as root).
  local mode
  while read -r mode _; do
    [[ $mode =~ ^[-d][rwx-]{9}$ ]] || die "unsupported entry type or mode in backup: $mode"
  done < <(tar -tvzf "$tarball")
  lock_acquire
  tar -C "${DEVMESH_ROOT:-/}" --no-same-owner -xzpf "$tarball"
  load_hub_conf
  apply_all
  audit "state restored from $tarball"
  printf 'restored; run "devmesh ls" after DNS points %s here\n' "$HUB_HOST"
}
