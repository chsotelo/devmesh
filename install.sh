#!/usr/bin/env bash
# devmesh guided hub installer (Ubuntu 20.04+ / Debian 11+).
#
#   curl -fsSL https://raw.githubusercontent.com/chsotelo/devmesh/v<ver>/install.sh | sudo bash
#
# Non-interactive: set HUB_HOST (and ACME_EMAIL for a domain, BACKUP_RECIPIENT optional).
#
# Version: DEVMESH_VERSION from the environment, else the pinned value below, else a VERSION
# file next to this script. scripts/release.sh may substitute the literal token @@VERSION@@
# on the PINNED_VERSION line with the release version; unsubstituted it is ignored.
#
# Overrides: DEVMESH_REPO (default chsotelo/devmesh), DEVMESH_TARBALL_URL, DEVMESH_SUMS_URL
# (mirrors/tests), DEVMESH_SKIP_INSTALL=1 (stop after verify+extract).
# Test-only: INSTALL_TEST_EUID (fake uid), DEVMESH_OS_RELEASE (fake os-release),
# DEVMESH_TTY (answers file, default /dev/tty), DEVMESH_DETECT_IP=0 (skip ifconfig.me).
set -euo pipefail

PINNED_VERSION='@@VERSION@@'
readonly PINNED_VERSION
readonly PLACEHOLDER='@@VERSION''@@'
readonly MAX_TRIES=3

die() {
  echo "devmesh-install: $*" >&2
  exit "${2:-1}"
}

log() { echo "devmesh-install: $*" >&2; }

resolve_version() {
  local v=${DEVMESH_VERSION:-}
  if [[ -z $v && $PINNED_VERSION != "$PLACEHOLDER" ]]; then
    v=$PINNED_VERSION
  fi
  if [[ -z $v && -n ${BASH_SOURCE[0]:-} && -f $(dirname "${BASH_SOURCE[0]}")/VERSION ]]; then
    v=$(tr -d '[:space:]' <"$(dirname "${BASH_SOURCE[0]}")/VERSION")
  fi
  [[ -n $v ]] || v=$(latest_version)
  [[ -n $v ]] || die "unknown version: set DEVMESH_VERSION (e.g. DEVMESH_VERSION=0.7.0)"
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] || die "invalid version '$v'"
  echo "$v"
}

# The latest release, from the redirect of github.com/<repo>/releases/latest (.../tag/vX.Y.Z).
# No API token or rate limit; the tarball is still checked against SHA256SUMS.
latest_version() {
  local url
  url=$(curl -fsSL --max-time 10 -o /dev/null -w '%{url_effective}' \
    "${DEVMESH_LATEST_URL:-https://github.com/${DEVMESH_REPO:-chsotelo/devmesh}/releases/latest}" 2>/dev/null) || return 0
  [[ $url == */tag/v* ]] && printf '%s\n' "${url##*/tag/v}"
  return 0
}

require_root() {
  local version=$1
  if [[ ${INSTALL_TEST_EUID:-$EUID} -ne 0 ]]; then
    die "must run as root. Run: curl -fsSL https://raw.githubusercontent.com/${DEVMESH_REPO:-chsotelo/devmesh}/v$version/install.sh | sudo bash"
  fi
}

print_docker_help() {
  cat >&2 <<'MSG'
This installer supports Ubuntu 20.04+ and Debian 11+ only.
On any other system run the hub with Docker:

  HUB_HOST=hub.example.com docker compose -f docker/hub/compose.yml up -d
MSG
}

check_os() {
  local file=${DEVMESH_OS_RELEASE:-/etc/os-release} id="" vid="" major minor
  if [[ -r $file ]]; then
    # shellcheck source=/dev/null
    id=$(. "$file" && echo "${ID:-}")
    # shellcheck source=/dev/null
    vid=$(. "$file" && echo "${VERSION_ID:-}")
  fi
  major=${vid%%.*}
  minor=${vid#*.}
  [[ $vid == *.* ]] || minor=0
  if [[ ! $major =~ ^[0-9]+$ || ! $minor =~ ^[0-9]+$ ]]; then
    print_docker_help
    exit 2
  fi
  case $id in
    ubuntu) ((10#$major * 100 + 10#$minor >= 2004)) && return 0 ;;
    debian) ((10#$major >= 11)) && return 0 ;;
  esac
  print_docker_help
  exit 2
}

is_ip() {
  local h=$1
  [[ $h =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0
  [[ $h == *:* && $h =~ ^[0-9a-fA-F:]+$ ]]
}

valid_host() {
  is_ip "$1" ||
    [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

valid_email() { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

valid_recipient() { [[ -z $1 || $1 =~ ^age1[0-9a-z]{58}$ ]]; }

detect_ip() {
  [[ ${DEVMESH_DETECT_IP:-1} == 0 ]] && return 0
  curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true
}

# ask VAR PROMPT VALIDATOR [DEFAULT]: reads from fd 3, re-asks up to MAX_TRIES times.
ask() {
  local var=$1 prompt=$2 validator=$3 default=${4:-} ans="" tries=0
  while ((tries < MAX_TRIES)); do
    printf '%s' "$prompt" >&2
    ans=""
    read -r ans <&3 || true
    [[ -n $ans ]] || ans=$default
    if "$validator" "$ans"; then
      printf -v "$var" '%s' "$ans"
      return 0
    fi
    log "invalid answer"
    tries=$((tries + 1))
  done
  die "too many invalid answers"
}

nonempty_host() { [[ -n $1 ]] && valid_host "$1"; }
nonempty_email() { [[ -n $1 ]] && valid_email "$1"; }

collect_answers() {
  if [[ -n ${HUB_HOST:-} ]]; then
    valid_host "$HUB_HOST" || die "invalid HUB_HOST '$HUB_HOST'"
    if ! is_ip "$HUB_HOST"; then
      nonempty_email "${ACME_EMAIL:-}" || die "ACME_EMAIL is required (valid email) for a domain"
    fi
    valid_recipient "${BACKUP_RECIPIENT:-}" || die "BACKUP_RECIPIENT must be an age1... public key"
    return 0
  fi
  local tty=${DEVMESH_TTY:-/dev/tty} detected
  [[ -r $tty ]] || die "no terminal to ask questions; set HUB_HOST (and ACME_EMAIL) for a non-interactive install"
  exec 3<"$tty"
  detected=$(detect_ip)
  if [[ -n $detected ]]; then
    ask HUB_HOST "Domain or IP of this server [$detected]: " nonempty_host "$detected"
  else
    ask HUB_HOST "Domain or IP of this server: " nonempty_host
  fi
  if is_ip "$HUB_HOST"; then
    ACME_EMAIL=""
  else
    ask ACME_EMAIL "Email for Let's Encrypt: " nonempty_email
  fi
  ask BACKUP_RECIPIENT "Backup public key (age1…, empty = no off-site backup): " valid_recipient
  exec 3<&-
}

sha_verify() {
  local dir=$1 name=$2
  if command -v sha256sum >/dev/null 2>&1 && sha256sum --help 2>&1 | grep -q -- --ignore-missing; then
    (cd "$dir" && sha256sum -c --ignore-missing SHA256SUMS >/dev/null 2>&1) || return 1
    grep -q "  $name\$" "$dir/SHA256SUMS"
  else
    grep "  $name\$" "$dir/SHA256SUMS" >"$dir/SHA256SUMS.one" || return 1
    (cd "$dir" && shasum -a 256 -c SHA256SUMS.one >/dev/null 2>&1)
  fi
}

fetch() {
  curl -fsSL -o "$2" "$1" || die "download failed: $1"
}

main() {
  local version name base tar_url sums_url tmp extracted
  version=$(resolve_version)
  require_root "$version"
  check_os
  collect_answers

  name="devmesh-$version"
  base="https://github.com/${DEVMESH_REPO:-chsotelo/devmesh}/releases/download/v$version"
  tar_url=${DEVMESH_TARBALL_URL:-$base/$name.tar.gz}
  sums_url=${DEVMESH_SUMS_URL:-$base/SHA256SUMS}

  tmp=$(mktemp -d)
  if [[ ${DEVMESH_SKIP_INSTALL:-0} != 1 ]]; then
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
  fi
  fetch "$tar_url" "$tmp/$name.tar.gz"
  fetch "$sums_url" "$tmp/SHA256SUMS"
  sha_verify "$tmp" "$name.tar.gz" || die "checksum verification failed for $name.tar.gz; refusing to install"

  mkdir "$tmp/extract"
  tar -xzf "$tmp/$name.tar.gz" -C "$tmp/extract" || die "could not extract $name.tar.gz"
  extracted="$tmp/extract/$name"
  [[ -f $extracted/server/install-hub.sh ]] || die "tarball is missing server/install-hub.sh"

  if [[ ${DEVMESH_SKIP_INSTALL:-0} == 1 ]]; then
    echo "extracted: $extracted"
    echo "HUB_HOST=$HUB_HOST"
    echo "ACME_EMAIL=${ACME_EMAIL:-}"
    echo "BACKUP_RECIPIENT=${BACKUP_RECIPIENT:-}"
    return 0
  fi

  HUB_HOST=$HUB_HOST ACME_EMAIL=${ACME_EMAIL:-} BACKUP_RECIPIENT=${BACKUP_RECIPIENT:-} \
    bash "$extracted/server/install-hub.sh"

  cat <<'MSG'

Hub installed. Next step: create the first device invitation with

  devmesh invite <your-first-device-name>

The first device should be the owner one (a future release adds --owner for it).
MSG
}

main "$@"
