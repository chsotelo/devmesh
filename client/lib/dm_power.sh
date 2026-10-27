# shellcheck shell=bash
# Suspend, power off and wake machines. A machine that is suspended or off only wakes with a
# magic packet from a machine on its own LAN, so the controller refuses to suspend or power off
# one that nobody on its LAN could wake again.

readonly DM_LOGIND=(org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager)

# --- machine side: dm _power_do caps|suspend|off [--self] -------------------------------

# dm_power_can Suspend|PowerOff — what logind answers: "yes" only when no password is needed
# (the devmesh polkit rule); "challenge" and "no" mean the action must not be offered.
dm_power_can() {
  local out
  command -v busctl >/dev/null || {
    printf 'no\n'
    return 0
  }
  out=$(busctl call "${DM_LOGIND[@]}" "Can$1" 2>/dev/null) || {
    printf 'no\n'
    return 0
  }
  out=${out#*\"}
  printf '%s\n' "${out%%\"*}"
}

# dm_power_wol — ok: a magic packet wakes this machine from suspend; off: it is on WiFi
# without Wake-on-WLAN, so nothing could wake it; na: no WiFi (wired Wake-on-LAN).
dm_power_wol() {
  local sys=${DM_SYS_NET:-/sys/class/net} phy
  compgen -G "$sys/*/wireless" >/dev/null || {
    printf 'na\n'
    return 0
  }
  command -v iw >/dev/null || {
    printf 'off\n'
    return 0
  }
  for phy in $(iw phy 2>/dev/null | awk '/^Wiphy /{print $2}'); do
    if [[ $(iw phy "$phy" wowlan show 2>/dev/null) == *"wake up on magic packet"* ]]; then
      printf 'ok\n'
      return 0
    fi
  done
  printf 'off\n'
}

dm_power_caps() {
  case $(dm_platform) in
    macos) printf 'suspend=yes off=no wol=ok\n' ;;
    linux) printf 'suspend=%s off=%s wol=%s\n' "$(dm_power_can Suspend)" "$(dm_power_can PowerOff)" "$(dm_power_wol)" ;;
    *) printf 'suspend=no off=no wol=na\n' ;;
  esac
}

# The command runs a moment later, detached: the ssh session that asked for it ends cleanly
# instead of hanging on a machine that is going to sleep.
dm_power_detached() {
  local delay=${DM_POWER_DELAY:-2}
  (
    sleep "$delay"
    "$@"
  ) </dev/null >/dev/null 2>&1 3>&- &
  disown
}

dm_power_run() {
  local action=$1 self=$2 method
  case $(dm_platform) in
    macos)
      [[ $action == suspend ]] || dm_die "$M_PW_E_UNSUPPORTED"
      dm_power_detached pmset sleepnow
      ;;
    linux)
      method=Suspend
      [[ $action == off ]] && method=PowerOff
      [[ $(dm_power_can "$method") == yes ]] || dm_die "$M_PW_E_NOT_ALLOWED"
      if [[ $action == suspend && $self != --self && $(dm_power_wol) == off ]]; then
        dm_die "$M_PW_WHY_NO_WOL"
      fi
      dm_power_detached busctl call "${DM_LOGIND[@]}" "$method" b false
      ;;
    *) dm_die "$M_PW_E_UNSUPPORTED" ;;
  esac
  printf 'ok\n'
}

dm_power_do() {
  case ${1:-} in
    caps) dm_power_caps ;;
    suspend | off) dm_power_run "$1" "${2:-}" ;;
    *) dm_die "usage: dm _power_do caps|suspend|off" ;;
  esac
}

# --- controller side: dm _power HOST check|suspend|off|wake ---------------------------------

# dm_power_cidr HOST — the trusted LAN the machine is on right now ("<cidr>"), else nothing.
dm_power_cidr() {
  local out cidr=""
  if dm_is_self "$1"; then
    out=$(cat /run/devmesh/lan 2>/dev/null) || out=""
  else
    # shellcheck disable=SC2086 # DM_LAN_ASK is a fixed command line
    out=$(dm_run "$1" $DM_LAN_ASK 2>/dev/null) || out=""
  fi
  read -r _ cidr _ <<<"$out" || true
  [[ $cidr =~ ^[0-9.]+/[0-9]+$ ]] && printf '%s\n' "$cidr"
  return 0
}

# dm_power_relay_live HOST ALIAS CIDR — a machine that is online on the same trusted LAN as
# HOST (this device itself counts when it reaches HOST straight over the LAN). Prints its name.
dm_power_relay_live() {
  local host=$1 alias=$2 cidr=$3 m
  if [[ $alias == "$host-l" ]]; then
    printf '%s\n' "${DM_NAME:-this device}"
    return 0
  fi
  for m in $(dm_machines); do
    [[ $m == "$host" ]] && continue
    if [[ $(dm_power_cidr "$m") == "$cidr" ]]; then
      printf '%s\n' "$m"
      return 0
    fi
  done
  return 1
}

# dm_power_relay_label HOST — an online machine with the same LAN label (what "dm wake" uses).
dm_power_relay_label() {
  local host=$1 lan m
  lan=$(dm_host_field "$host" lan)
  [[ $lan != - && -n $lan ]] || return 2
  for m in $(dm_hosts machine | awk -F'\t' -v l="$lan" -v t="$host" '$7 == l && $1 != t {print $1}'); do
    if dm_path "$m" >/dev/null 2>&1; then
      printf '%s\n' "$m"
      return 0
    fi
  done
  return 1
}

dm_power_line() { printf 'suspend=%s off=%s wake=%s why=%s\n' "$1" "$2" "$3" "$4"; }

dm_power_check_offline() {
  local host=$1 mac lan_rc=0
  mac=$(dm_host_field "$host" mac)
  if [[ $mac == - || -z $mac ]]; then
    dm_power_line 0 0 0 no-mac
    return 0
  fi
  dm_power_relay_label "$host" >/dev/null || lan_rc=$?
  case $lan_rc in
    0) dm_power_line 0 0 1 ok ;;
    2) dm_power_line 0 0 0 other-lan ;;
    *) dm_power_line 0 0 0 no-relay ;;
  esac
}

# dm_power_check HOST — "suspend=0|1 off=0|1 wake=0|1 why=<key>".
dm_power_check() {
  local host=$1 alias caps mac cidr cs co wol s=0 o=0
  if dm_is_self "$host"; then
    if [[ $(dm_platform) == termux ]]; then
      dm_power_line 0 0 0 unsupported
    else
      dm_power_line 1 0 0 self
    fi
    return 0
  fi
  if [[ $(dm_host_field "$host" kind) != machine ]]; then
    dm_power_line 0 0 0 unsupported
    return 0
  fi
  if ! alias=$(dm_path "$host" 2>/dev/null); then
    dm_power_check_offline "$host"
    return 0
  fi
  if ! caps=$(dm_run "$host" dm _power_do caps 2>/dev/null) ||
    ! [[ $caps =~ suspend=([a-z]+)\ off=([a-z]+)\ wol=([a-z]+) ]]; then
    dm_power_line 0 0 0 outdated
    return 0
  fi
  cs=${BASH_REMATCH[1]} co=${BASH_REMATCH[2]} wol=${BASH_REMATCH[3]}
  mac=$(dm_host_field "$host" mac)
  if [[ $mac == - || -z $mac ]]; then
    dm_power_line 0 0 0 no-mac
    return 0
  fi
  cidr=$(dm_power_cidr "$host")
  if [[ -z $cidr ]]; then
    dm_power_line 0 0 0 other-lan
    return 0
  fi
  if ! dm_power_relay_live "$host" "$alias" "$cidr" >/dev/null; then
    dm_power_line 0 0 0 no-relay
    return 0
  fi
  if [[ $wol == off ]]; then
    dm_power_line 0 0 0 no-wol
    return 0
  fi
  [[ $cs == yes ]] && s=1
  [[ $co == yes ]] && o=1
  if ((s + o == 0)); then
    dm_power_line 0 0 0 no-power
    return 0
  fi
  dm_power_line "$s" "$o" 0 ok
}

# dm_power_why KEY — the catalog sentence for a why key.
dm_power_why() {
  local key=${1//-/_}
  key=M_PW_WHY_${key^^}
  printf '%s\n' "${!key:-$1}"
}

# dm_power HOST check|suspend|off|wake
dm_power() {
  local host=${1:-} action=${2:-} line s o w why ok out
  [[ $host =~ ^[a-z][a-z0-9-]{0,15}$ ]] || dm_die "usage: dm _power HOST check|suspend|off|wake"
  case $action in
    check | suspend | off | wake) ;;
    *) dm_die "usage: dm _power HOST check|suspend|off|wake" ;;
  esac
  line=$(dm_power_check "$host")
  if [[ $action == check ]]; then
    printf '%s\n' "$line"
    return 0
  fi
  [[ $line =~ suspend=([01])\ off=([01])\ wake=([01])\ why=([a-z-]+) ]] || dm_die "$M_PW_E_FAILED"
  s=${BASH_REMATCH[1]} o=${BASH_REMATCH[2]} w=${BASH_REMATCH[3]} why=${BASH_REMATCH[4]}
  case $action in
    suspend) ok=$s ;;
    off) ok=$o ;;
    wake) ok=$w ;;
  esac
  [[ $ok == 1 ]] || dm_die "$(dm_power_why "$why")"
  case $action in
    wake) dm_wake "$host" ;;
    *)
      if dm_is_self "$host"; then
        dm_power_do "$action" --self >/dev/null
      else
        out=$(dm_run "$host" dm _power_do "$action" 2>&1) || dm_die "$M_PW_E_FAILED"
        [[ $out == *ok* ]] || dm_die "$M_PW_E_FAILED"
      fi
      ;;
  esac
  printf 'ok\n'
}
