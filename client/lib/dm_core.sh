# shellcheck shell=bash
# dm core: config, hub exports cache, path A/B selection, pickers, formatting.

dm_die() {
  printf '\033[31merror:\033[0m %s\n' "$*" >&2
  exit 1
}
dm_info() { printf '%s\n' "$*" >&2; }

# --- i18n -------------------------------------------------------------------------------
# dm_lang: DM_LANG, else the prefix of LC_ALL / LC_MESSAGES / LANG (es* -> es), else en.
dm_lang() {
  local l=${DM_LANG:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}
  case $l in
    es*) printf 'es\n' ;;
    *) printf 'en\n' ;;
  esac
}

# dm_i18n_load: en.sh is the full reference; es.sh is loaded on top, so a key missing in es
# stays in English. The M_* variables become read-only once both are in.
dm_i18n_load() {
  local dir=${BASH_SOURCE[0]%/*}/i18n m
  [[ -n ${M_I18N_LOADED:-} ]] && return 0
  # shellcheck source=/dev/null
  source "$dir/en.sh"
  if [[ $(dm_lang) == es ]]; then
    # shellcheck source=/dev/null
    source "$dir/es.sh"
  fi
  for m in $(compgen -v M_); do readonly "$m"; done
  readonly M_I18N_LOADED=1
}

# dm_t FORMAT [ARG...] — printf with a catalog format (the catalog never interpolates).
dm_t() {
  local fmt=$1
  shift
  # shellcheck disable=SC2059 # the format comes from the catalog
  printf "$fmt" "$@"
}

# dm_count N ONE_FORMAT MANY_FORMAT — "1 terminal" / "3 terminals".
dm_count() {
  if [[ $1 == 1 ]]; then dm_t "$2" "$1"; else dm_t "$3" "$1"; fi
}

dm_i18n_load

dm_platform() {
  if [[ -n ${TERMUX_VERSION:-} || ${PREFIX:-} == */com.termux/* ]]; then
    printf 'termux\n'
  elif [[ $(uname -s) == Darwin ]]; then
    printf 'macos\n'
  else
    printf 'linux\n'
  fi
}

dm_conf_file() {
  if [[ -n ${DM_CONF:-} ]]; then
    printf '%s\n' "$DM_CONF"
  elif [[ $(dm_platform) == termux || $(dm_platform) == macos ]]; then
    printf '%s/.config/devmesh/node.conf\n' "$HOME"
  else
    printf '/etc/devmesh/node.conf\n'
  fi
}

dm_load_conf() {
  local conf
  conf=$(dm_conf_file)
  [[ -r $conf ]] || dm_die "this device is not enrolled ($conf missing)"
  # shellcheck source=/dev/null
  source "$conf"
  DM_PROJECTS_DIR=${DM_PROJECTS_DIR:-$HOME/PROJECTS}
  DM_CACHE=${DM_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/devmesh}
  mkdir -p "$DM_CACHE"
}

DM_SSH_PROBE=(-o BatchMode=yes -o ConnectTimeout="${DM_CONNECT_TIMEOUT:-4}")

# --- Hub exports -----------------------------------------------------------------

# The hub's ssh_config is not signed, and ssh_config can run commands (ProxyCommand,
# LocalCommand, Match exec, KnownHostsCommand…) or redirect trust (HostKeyAlias). Accept
# only the exact grammar devmesh renders: known keys with fixed or strictly shaped values,
# devmesh aliases only, and every machine pinned to its own name as HostKeyAlias.
# dm_valid_ssh_config FILE HUB_HOST ALLOWED_MACHINE_NAMES   (names: the machines of the hosts list)
# No {m,n} intervals in these awk regexes: mawk (Debian/Ubuntu's awk) ignores them.
dm_valid_ssh_config() {
  local names=" hub-admin hub-jump " n
  # shellcheck disable=SC2086 # $3 is a list of names, split on purpose
  for n in $3; do names+="$n $n-b "; done
  awk -v hub="$2" -v names="$names" '
    function fail(why) { printf "ssh-config from hub rejected (line %d: %s)\n", NR, why > "/dev/stderr"; bad = 1; exit 1 }
    /\t/ { fail("tab") }
    /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
    /^Host / {
      n = split(substr($0, 6), aliases, " ")
      if (n < 1) fail("empty Host")
      for (i = 1; i <= n; i++) if (aliases[i] !~ /^[a-z][a-z0-9-]*$/ || index(names, " " aliases[i] " ") == 0) fail("alias " aliases[i])
      block = (n == 1) ? aliases[1] : ""
      if (n == 1 && single[block]++) fail("duplicate Host " block)
      cn = n
      for (i = 1; i <= n; i++) { cur[i] = aliases[i]; seen[aliases[i]] = 1 }
      hosts++
      next
    }
    /^  [A-Za-z]+ [^ ]+$/ {
      if (!hosts) fail("option outside a Host block")
      k = $1; v = $2
      if (k == "HostName") ok = v ~ /^[A-Za-z0-9.:][A-Za-z0-9.:-]*$/
      else if (k == "Port") ok = v ~ /^[0-9]+$/ && length(v) <= 5 && v + 0 >= 1 && v + 0 <= 65535
      else if (k == "ServerAliveInterval" || k == "ServerAliveCountMax" || k == "ControlPersist") ok = v ~ /^[0-9]+$/ && length(v) <= 5
      else if (k == "User") ok = v ~ /^[a-z_][a-z0-9_.-]*$/ && length(v) <= 32
      else if (k == "ProxyJump") ok = v == "hub-jump" && block != "" && block != "hub-admin" && block != "hub-jump"
      else if (k == "HostKeyAlias") {
        if (block == "hub-admin" || block == "hub-jump") ok = v == hub
        else if (block != "") { m = block; sub(/-b$/, "", m); ok = v == m }
        else ok = 0
      }
      else if (k == "IgnoreUnknown") ok = v == "WarnWeakCrypto"
      else if (k == "WarnWeakCrypto") ok = v == "no-pq-kex"
      else if (k == "IdentityFile") ok = v == "~/.ssh/id_devmesh"
      else if (k == "IdentitiesOnly" || k == "StrictHostKeyChecking") ok = v == "yes"
      else if (k == "UserKnownHostsFile") ok = v == "~/.ssh/devmesh_known_hosts"
      else if (k == "ControlMaster") ok = v == "auto"
      # dm-%n since 0.8.1; devmesh-%n-%C (0.8.0) is still accepted so no device gets stuck.
      else if (k == "ControlPath") ok = v == "~/.ssh/dm-%n" || v == "~/.ssh/devmesh-%n-%C"
      else ok = 0
      if (!ok) fail(k " " v)
      # Trust options must reach every alias: otherwise ssh falls back to ~/.ssh/known_hosts,
      # "ask" and the default keys (trust on first use for a machine the hub invents).
      if (k == "IdentityFile" || k == "IdentitiesOnly" || k == "UserKnownHostsFile" || k == "StrictHostKeyChecking")
        for (i = 1; i <= cn; i++) cov[cur[i], k] = 1
      # And every alias must name the key it is checked against (its own name, or the hub):
      # without HostKeyAlias ssh looks up the HostName, so a machine aimed at the hub
      # address would be accepted with the pinned hub key.
      if (k == "HostKeyAlias") cov[block, k] = 1
      next
    }
    { fail("unexpected line") }
    END {
      if (bad) exit 1
      if (!hosts) { print "ssh-config from hub rejected (no Host)" > "/dev/stderr"; exit 1 }
      nk = split("IdentityFile IdentitiesOnly UserKnownHostsFile StrictHostKeyChecking HostKeyAlias", keys, " ")
      for (a in seen) for (j = 1; j <= nk; j++) if (!cov[a, keys[j]]) {
        printf "ssh-config from hub rejected (%s does not set %s)\n", a, keys[j] > "/dev/stderr"; exit 1
      }
    }
  ' "$1"
}

# Every field of the hub's device list is checked before it is cached (it feeds ssh commands).
dm_valid_hosts() {
  local name kind ip port color user lan mac
  while IFS=$'\t' read -r name kind ip port color user lan mac extra; do
    [[ -z ${extra:-} && $name =~ ^[a-z][a-z0-9-]{0,15}$ && $kind =~ ^(machine|phone|client)$ &&
      $ip =~ ^[0-9.]+$ && $port =~ ^([0-9]+|-)$ && $color =~ ^([0-9]+|-)$ &&
      $user =~ ^([a-z_][a-z0-9_.-]{0,31}|-)$ && $lan =~ ^(-|[a-z0-9][a-z0-9-]{0,15})$ &&
      $mac =~ ^(-|([0-9a-f]{2}:){5}[0-9a-f]{2})$ ]] || {
      dm_info "device list from hub rejected (bad entry: ${name:0:20})"
      return 1
    }
  done <"$1"
}

# dm_refresh: pull ssh_config, pinned host keys and the device list from the hub.
# Runs in a subshell so its EXIT trap cleans the temp dir without touching the caller.
dm_refresh() (
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  ssh "${DM_SSH_PROBE[@]}" hub-admin ssh-config >"$tmp/config" || dm_die "cannot reach hub-admin"
  ssh "${DM_SSH_PROBE[@]}" hub-admin known-hosts >"$tmp/known"
  ssh "${DM_SSH_PROBE[@]}" hub-admin hosts >"$tmp/hosts"
  grep -q '^Host hub-admin$' "$tmp/config" || dm_die "invalid ssh-config from hub"
  grep -q ' ssh-ed25519 ' "$tmp/known" || dm_die "invalid known-hosts from hub"
  awk -F'\t' 'NF != 8 {bad=1} END {exit bad}' "$tmp/hosts" || dm_die "invalid hosts from hub"
  dm_valid_hosts "$tmp/hosts" || dm_die "invalid hosts from hub"
  dm_valid_ssh_config "$tmp/config" "${DM_HUB_HOST:-}" "$(awk -F'\t' '$2 == "machine" {print $1}' "$tmp/hosts")" ||
    dm_die "the hub's ssh config is not what devmesh renders: keeping the current one"
  if dm_trust_active; then
    # Host keys are only trusted when an approver signed them (the hub cannot vouch).
    ssh "${DM_SSH_PROBE[@]}" hub-admin bundle >"$tmp/bundle" || dm_die "cannot fetch the signed bundle"
    dm_trust_known_hosts "$tmp/known" "$tmp/hosts" "$tmp/bundle" >"$tmp/known.ok" ||
      dm_die "invalid signed bundle or hub entry; known_hosts not changed"
    mv -f "$tmp/known.ok" "$tmp/known"
  fi
  mkdir -p "$HOME/.ssh/config.d"
  install -m 0600 "$tmp/config" "$HOME/.ssh/config.d/devmesh"
  install -m 0600 "$tmp/known" "$HOME/.ssh/devmesh_known_hosts"
  install -m 0600 "$tmp/hosts" "$DM_CACHE/hosts.tsv"
  dm_info "refreshed: $(grep -c . "$DM_CACHE/hosts.tsv") devices"
)

# dm_hosts [kind] — cached device list; refreshed when older than 10 min (best effort).
dm_hosts() {
  local kind=${1:-} cache="$DM_CACHE/hosts.tsv"
  if [[ ! -s $cache ]] || [[ -n $(find "$cache" -mmin +10 2>/dev/null) ]]; then
    dm_refresh >/dev/null 2>&1 || [[ -s $cache ]] || dm_die "no device list (run: dm refresh)"
  fi
  awk -F'\t' -v k="$kind" 'k == "" || $2 == k' "$cache"
}

# dm_host_field NAME COLUMN(name kind ip port color user lan mac)
dm_host_field() {
  local col
  case $2 in
    name) col=1 ;; kind) col=2 ;; ip) col=3 ;; port) col=4 ;;
    color) col=5 ;; user) col=6 ;; lan) col=7 ;; mac) col=8 ;;
    *) dm_die "unknown host field $2" ;;
  esac
  awk -F'\t' -v n="$1" -v c="$col" '$1 == n {print $c; exit}' "$DM_CACHE/hosts.tsv"
}

dm_machines() { dm_hosts machine | cut -f1; }

# dm_is_workspace_host NAME — no "| grep -q": under pipefail an early match makes the
# writer die of SIGPIPE and the whole test fail.
dm_is_workspace_host() {
  local hosts
  hosts=$'\n'$(dm_workspace_hosts)$'\n'
  [[ -n ${1:-} && $hosts == *$'\n'"$1"$'\n'* ]]
}

# The tabs of the workspace: this device first (its own terminals, when it has tmux), then
# every other machine.
dm_workspace_hosts() {
  local self=${DM_NAME:-} m
  if [[ $self =~ ^[a-z][a-z0-9-]{0,15}$ ]] && command -v tmux >/dev/null; then
    printf '%s\n' "$self"
  fi
  for m in $(dm_machines); do
    [[ $m == "$self" ]] || printf '%s\n' "$m"
  done
}

# Terminals live on Linux machines; say so (and how to add one) instead of an empty list.
dm_require_machines() {
  [[ -n $(dm_machines) ]] && return 0
  dm_die "no machines yet. Terminals live on your Linux machines (laptop, PCs).
  Add one: dm add lap   → then paste the printed line on that machine.
  Your Mac and phones are controls: they open terminals on machines."
}

# --- Paths A/B -----------------------------------------------------------------
# The device dm runs on: its own terminals are reached locally, never through the hub.
dm_is_self() { [[ -n ${DM_NAME:-} && ${1:-} == "$DM_NAME" ]]; }

# dm_local CMD-WORDS… — run a "dm …" command line on this device (the words were validated
# by the caller, like the remote side would). Outside the workspace's tmux, so a local
# attach is not refused as nested.
dm_local() {
  [[ ${1:-} == dm ]] || return 2
  shift
  env -u TMUX "$BASH" "$DM_SELF" "$@"
}

# dm_path HOST -> "HOST" (path A, WireGuard) | "HOST-b" (path B, reverse tunnel) | fails.
dm_path() {
  local host=$1
  if dm_is_self "$host"; then
    printf '%s\n' "$host"
    return 0
  fi
  if ssh "${DM_SSH_PROBE[@]}" "$host" true 2>/dev/null; then
    printf '%s\n' "$host"
  elif ssh "${DM_SSH_PROBE[@]}" "$host-b" true 2>/dev/null; then
    printf '%s-b\n' "$host"
  else
    return 1
  fi
}

# dm_run HOST CMD... — non-interactive remote command over the first working path.
dm_run() {
  local host=$1 alias
  shift
  if dm_is_self "$host"; then
    dm_local "$@"
    return
  fi
  alias=$(dm_path "$host") || return 255
  # shellcheck disable=SC2029 # arguments are meant to run on the remote side
  ssh "${DM_SSH_PROBE[@]}" "$alias" "$@"
}

# dm_tty HOST REMOTE_CMD — interactive session: mosh on path A when available, else ssh -t.
dm_tty() {
  local host=$1 cmd=$2 alias words
  if dm_is_self "$host"; then
    read -ra words <<<"$cmd"
    dm_local "${words[@]}"
    return
  fi
  alias=$(dm_path "$host") || dm_die "$host is unreachable (WireGuard and tunnel both down)"
  # mosh needs a direct UDP path: never through the hub (ProxyJump: macOS machines, path B).
  if [[ $alias == "$host" && ${DM_USE_MOSH:-1} == 1 ]] && command -v mosh >/dev/null &&
    ! ssh -G "$alias" 2>/dev/null | grep -q '^proxyjump '; then
    mosh "$alias" -- sh -c "$cmd"
  else
    ssh -t -o ConnectTimeout=6 "$alias" "$cmd"
  fi
}

# --- Formatting ------------------------------------------------------------------
dm_dot() { printf '\033[38;5;%sm●\033[0m' "${1/#-/244}"; }
dm_grey() { printf '\033[38;5;244m%s\033[0m' "$*"; }

dm_ago() {
  local then=$1 now delta
  [[ $then =~ ^[0-9]+$ && $then -gt 0 ]] || {
    printf -- '-'
    return
  }
  now=$(date +%s)
  delta=$((now - then))
  ((delta < 0)) && delta=0
  if ((delta < 60)); then
    printf '%ss' "$delta"
  elif ((delta < 3600)); then
    printf '%sm' $((delta / 60))
  elif ((delta < 86400)); then
    printf '%sh' $((delta / 3600))
  else
    printf '%sd' $((delta / 86400))
  fi
}

dm_narrow() { (("${FZF_COLUMNS:-${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}}" < 60)); }

# Session names: tmux forbids "." and ":"; keep them short and shell-safe.
dm_sanitize() {
  local s=${1,,}
  s=${s//[^a-z0-9_-]/-}
  while [[ $s == *--* ]]; do s=${s//--/-}; done
  s=${s#-}
  s=${s%-}
  printf '%s\n' "${s:0:30}"
}

# New names are sanitized to lowercase; existing local sessions may use uppercase.
dm_valid_session() { [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,29}$ ]]; }

# --- Pickers ---------------------------------------------------------------------
# dm_pick PROMPT [fzf args...] < lines — touch-friendly: tap = select, double tap/Enter = open.
dm_pick() {
  local prompt=$1 extra=()
  shift
  [[ ${DM_TAP_ACCEPT:-0} == 1 ]] && extra+=(--bind 'left-click:accept')
  fzf --ansi --reverse --height=100% --no-sort --prompt="$prompt> " --info=hidden "${extra[@]}" "$@"
}

dm_confirm() {
  local expect=$1 answer
  printf 'Type "%s" to confirm: ' "$expect" >&2
  read -r answer
  [[ $answer == "$expect" ]]
}
