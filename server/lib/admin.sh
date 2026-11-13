# shellcheck shell=bash
# _ssh <caller>: forced command of the "dmadmin" user (via sudo). Enrolled devices can
# manage the mesh through this allowlist but never get a shell on the hub.

readonly ADMIN_ARG_RE='^[A-Za-z0-9._:-]{1,64}$'

cmd_admin_ssh() {
  local caller=${1:-} raw=${SSH_ORIGINAL_COMMAND:-help} words=() w
  if ! valid_name "$caller" || ! reg_exists "$caller"; then
    die "unknown caller"
  fi
  ((${#raw} <= 256)) || die "command too long"
  # No eval, no globbing: split on whitespace and validate every word.
  set -f
  read -ra words <<<"$raw"
  set +f
  ((${#words[@]})) || words=(help)
  for w in "${words[@]}"; do
    [[ $w =~ $ADMIN_ARG_RE ]] || die "invalid argument"
  done
  # shellcheck disable=SC2034 # read by cmd_approve
  ADMIN_CALLER=$caller
  audit "admin by $caller: ${words[*]}"
  # Once the hub has approvers, a device still waiting for approval may only read and
  # cancel itself: it must not remove others, invite, or push alerts to the owner.
  if admin_caller_pending; then
    case ${words[0]} in
      ls | hosts | ssh-config | known-hosts | dist | version | pending | signers | bundle | help) ;;
      remove) [[ ${words[1]:-} == "$caller" ]] || die "pending approval: only an approved device can do that" ;;
      *) die "pending approval: only an approved device can do that" ;;
    esac
  fi
  admin_dispatch "${words[@]}"
}

# admin_caller_pending: the hub has approvers and the caller has not been approved yet.
admin_caller_pending() {
  signers_exist || return 1
  [[ $(reg_field "$(reg_get "$ADMIN_CALLER")" sig) == -* ]]
}

admin_dispatch() {
  local cmd=$1
  shift
  case $cmd in
    invite) cmd_invite "$@" ;;
    remove) cmd_remove "$@" ;;
    ls) cmd_ls ;;
    hosts) cmd_hosts ;;
    ssh-config) cmd_ssh_config ;;
    known-hosts) cmd_known_hosts ;;
    dist) cmd_dist "$@" ;;
    version) devmesh_version ;;
    approve) cmd_approve "$@" ;;
    revoke) cmd_revoke "$@" ;;
    pending) cmd_pending ;;
    signers) cmd_signers ;;
    bundle) cmd_bundle ;;
    backup-latest) cmd_backup_latest ;;
    notify) cmd_admin_notify "$@" ;;
    help)
      printf 'commands: invite <name> [--lan L] [--watch-hub] [--machine|--phone|--client] [--owner] | remove <name> --confirm <name> |\n'
      printf '          ls | hosts | ssh-config | known-hosts | dist [version|sig] | version | backup-latest\n'
      printf '          approve <name> | revoke <name> (signatures on stdin) | pending | signers | bundle\n'
      printf '          notify claude <project> perm|wait\n'
      ;;
    *) die "command not allowed: $cmd" ;;
  esac
}

# notify claude <project> perm|wait: a Claude Code session on the caller needs the user.
# The text is fixed here: a device only picks which message is sent and a plain project name.
# The same message is sent at most once per NOTIFY_EVERY (Claude repeats its idle prompt), and
# a device sends at most NOTIFY_BURST messages per NOTIFY_EVERY whatever project names it uses.
cmd_admin_notify() {
  local text tags stamp last now budget recent
  (($# == 3)) && [[ $1 == claude && $2 =~ ^[a-z0-9_-]{1,30}$ ]] || die "usage: notify claude <project> perm|wait"
  case $3 in
    perm) text="Claude needs your permission" tags=warning ;;
    wait) text="Claude is waiting for your answer" tags=hourglass ;;
    *) die "usage: notify claude <project> perm|wait" ;;
  esac
  stamp="$DEVMESH_STATE/notify/$ADMIN_CALLER-$2-$3"
  now=$(now_epoch)
  read -r last 2>/dev/null <"$stamp" || last=0
  ((now - last >= NOTIFY_EVERY)) || return 0
  mkdir -p "${stamp%/*}"
  budget="$DEVMESH_STATE/notify/$ADMIN_CALLER.sent"
  recent=$(awk -v t="$((now - NOTIFY_EVERY))" '$1 ~ /^[0-9]+$/ && $1 > t' "$budget" 2>/dev/null || true)
  (($(grep -c . <<<"$recent") < ${NOTIFY_BURST:-5})) || return 0
  printf '%s\n%s\n' "$recent" "$now" | grep . >"$budget"
  printf '%s\n' "$now" >"$stamp"
  notify "Claude on $ADMIN_CALLER: $2" "$text" "$tags"
}
