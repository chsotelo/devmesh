#!/usr/bin/env bash
# Integration scenario for OSS-20/21/22 (approved keys, signed host keys, signed bundle) with a
# real hub (20.04) and two machines in systemd containers. Same helpers as run.sh.
#   pc2 (22.04) joins with --owner: it is the first approver (machine and approver at once)
#   lap (24.04) joins afterwards: pending until pc2 approves it
# "Root on the hub" is simulated by editing the hub's files after they were rendered.
# Usage: tests/integration/trust.sh        (images: make integration-images)  KEEP=1 keeps containers
# Remote commands are deliberately single-quoted: they expand inside the containers.
# shellcheck disable=SC2016
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NET=devmesh-it-trust
HUB_HOST=hub.devmesh.test
WORK=$(mktemp -d)
LOG="$WORK/log"
PASS=0
FAIL=0
FAILED=()

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok() {
  printf '\033[32mok\033[0m   %s\n' "$1"
  PASS=$((PASS + 1))
}
bad() {
  printf '\033[31mFAIL\033[0m %s\n' "$1"
  FAIL=$((FAIL + 1))
  FAILED+=("$1")
}
check() {
  local desc=$1
  shift
  printf '\n### %s\n' "$desc" >>"$LOG"
  if "$@" >>"$LOG" 2>&1; then ok "$desc"; else bad "$desc"; fi
}
check_not() {
  local desc=$1
  shift
  printf '\n### (must fail) %s\n' "$desc" >>"$LOG"
  if "$@" >>"$LOG" 2>&1; then bad "$desc"; else ok "$desc"; fi
}
eventually() {
  local secs=$1 desc=$2 i
  shift 2
  for ((i = 0; i < secs; i += 3)); do
    if "$@" >>"$LOG" 2>&1; then
      ok "$desc"
      return 0
    fi
    sleep 3
  done
  bad "$desc (after ${secs}s)"
}

x() { docker exec "$@"; }
xu() {
  local c=$1
  shift
  docker exec -u dev "$c" bash -lc "$*"
}

start_host() {
  local name=$1 image=$2 alias=${3:-}
  local args=(-d --name "$name" --hostname "${name#dm-}" --privileged --cgroupns=host
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock --network "$NET")
  [[ -n $alias ]] && args+=(--network-alias "$alias")
  docker run "${args[@]}" "$image" >/dev/null
  local i state
  for ((i = 0; i < 60; i++)); do
    state=$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)
    [[ $state == running || $state == degraded ]] && return 0
    sleep 1
  done
  echo "systemd did not come up in $name ($state)" >&2
  return 1
}

cleanup() {
  if [[ ${KEEP:-0} == 1 ]]; then
    echo "KEEP=1: containers left running; log at $LOG"
    return
  fi
  docker rm -f dm-thub dm-tlap dm-tpc2 >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [[ $FAIL -eq 0 ]] && rm -rf "$WORK"
}
trap cleanup EXIT

# enroll HUB NAME CONTAINER [invite args] — runs the exact one-liner "invite" prints.
enroll() {
  local hub=$1 name=$2 c=$3 out cmd
  shift 3
  out=$(x "$hub" devmesh invite "$name" "$@")
  printf '%s\n' "$out" >>"$LOG"
  cmd=$(sed -n 's/^JOIN: //p' <<<"$out")
  [[ -n $cmd ]] || return 1
  xu "$c" "$cmd"
}

# ---------------------------------------------------------------------------------
say "containers and hub"
docker network create "$NET" >/dev/null
start_host dm-thub devmesh-it:20.04 "$HUB_HOST"
start_host dm-tlap devmesh-it:24.04
start_host dm-tpc2 devmesh-it:22.04
age-keygen -o "$WORK/age.key" 2>/dev/null
AGE_RECIPIENT=$(age-keygen -y "$WORK/age.key")
x dm-thub openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$HUB_HOST" \
  -addext "subjectAltName=DNS:$HUB_HOST" -keyout /etc/ssl/devmesh.key -out /etc/ssl/devmesh.crt 2>/dev/null
docker cp dm-thub:/etc/ssl/devmesh.crt "$WORK/devmesh.crt"
for c in dm-tlap dm-tpc2; do
  docker cp "$WORK/devmesh.crt" "$c:/usr/local/share/ca-certificates/devmesh.crt"
  x "$c" update-ca-certificates >/dev/null
done
docker cp "$REPO/." dm-thub:/opt/devmesh-src
check "hub installs" x dm-thub env HUB_HOST="$HUB_HOST" TLS_CERT=/etc/ssl/devmesh.crt TLS_KEY=/etc/ssl/devmesh.key \
  BACKUP_RECIPIENT="$AGE_RECIPIENT" bash /opt/devmesh-src/server/install-hub.sh

say "owner and pending device"
check "pc2 joins as the owner (first approver)" enroll dm-thub pc2 dm-tpc2 --owner
check "the hub lists pc2 as approver" bash -c "docker exec dm-thub devmesh signers | grep -q '^pc2'"
check "pc2 trusts its own key and runs in signed mode" bash -c \
  "docker exec dm-tpc2 test -s /etc/devmesh/allowed_signers && docker exec dm-tpc2 grep -qx DM_TRUST=signed /etc/devmesh/node.conf"
check_not "a second --owner invite is refused" x dm-thub devmesh invite evil --owner
check "lap joins (pending)" enroll dm-thub lap dm-tlap
check "lap received the owner as approver and is in signed mode" bash -c \
  "docker exec dm-tlap grep -q '^pc2 ' /etc/devmesh/allowed_signers && docker exec dm-tlap grep -qx DM_TRUST=signed /etc/devmesh/node.conf"
check "devmesh ls shows lap pending" bash -c "docker exec dm-thub devmesh ls | grep -q 'lap.*pending approval'"
x dm-tpc2 systemctl start devmesh-keys.service || true
check_not "pc2 does not accept lap's key while it is pending" x dm-tpc2 grep -q 'devmesh:lap' /etc/devmesh/clients.pub
xu dm-tpc2 "dm refresh" >>"$LOG" 2>&1 || true
xu dm-tlap "dm refresh" >>"$LOG" 2>&1 || true
check_not "lap cannot ssh into pc2 yet" xu dm-tlap "ssh -o BatchMode=yes -o ConnectTimeout=6 pc2 true"

say "approve"
check "dm approve (no name) lists lap" bash -c "docker exec -u dev dm-tpc2 bash -lc 'dm approve' 2>&1 | grep -q lap"
check "pc2 approves lap (client and host key)" xu dm-tpc2 "DM_TEST=1 dm approve lap --yes"
check "pc2 approves its own host key" xu dm-tpc2 "DM_TEST=1 dm approve pc2 --yes"
check_not "a device that is not an approver cannot approve" xu dm-tlap "DM_TEST=1 dm approve lap --yes"
eventually 90 "pc2 installs lap's key after the next sync" x dm-tpc2 grep -q 'devmesh:lap' /etc/devmesh/clients.pub
xu dm-tpc2 "dm refresh" >>"$LOG" 2>&1 || true
xu dm-tlap "dm refresh" >>"$LOG" 2>&1 || true
eventually 30 "lap can ssh into pc2 (key approved, host key signed)" xu dm-tlap "ssh -o BatchMode=yes -o ConnectTimeout=6 pc2 hostname"

say "root on the hub cannot add access (OSS-20 CA3)"
x dm-thub bash -c '
  ssh-keygen -q -t ed25519 -N "" -f /root/evil
  key=$(awk "{print \$1 \" \" \$2}" /root/evil.pub)
  printf "%s devmesh:evil\n" "$key" >>/etc/devmesh/clients.pub
  printf "client evil %s %s\n" "$key" "$(printf "A%.0s" $(seq 1 120))" >>/etc/devmesh/clients.bundle
  printf "signer evil %s owner\n" "$key" >>/etc/devmesh/clients.bundle'
x dm-tpc2 systemctl start devmesh-keys.service || true
x dm-tlap systemctl start devmesh-keys.service || true
check_not "pc2 (signed mode) does not install the injected key" x dm-tpc2 grep -q 'devmesh:evil' /etc/devmesh/clients.pub
check_not "lap (signed mode) does not install the injected key" x dm-tlap grep -q 'devmesh:evil' /etc/devmesh/clients.pub
check_not "the injected key cannot log in to pc2" x dm-thub ssh -i /root/evil -o IdentitiesOnly=yes -o BatchMode=yes \
  -o ConnectTimeout=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null dev@10.73.0.2 true
check_not "no injected approver reached pc2's allowed_signers" x dm-tpc2 grep -q '^evil ' /etc/devmesh/allowed_signers
x dm-thub devmesh apply

say "root on the hub cannot impersonate a machine (OSS-22 CA)"
x dm-thub bash -c '
  ssh-keygen -q -t ed25519 -N "" -f /root/fake-host
  fake=$(awk "{print \$1 \" \" \$2}" /root/fake-host.pub)
  sed -i -E "s|^(host lap )ssh-ed25519 [A-Za-z0-9+/]+|\1$fake|" /etc/devmesh/clients.bundle'
check "dm refresh on pc2 drops the replaced host key" bash -c \
  "docker exec -u dev dm-tpc2 bash -lc 'dm refresh' 2>&1 | grep -q 'dropped host key of lap'"
check_not "the replaced key is not in known_hosts" bash -c \
  "docker exec -u dev dm-tpc2 grep -q \"\$(docker exec dm-thub awk '{print \$2}' /root/fake-host.pub)\" /home/dev/.ssh/devmesh_known_hosts"
check_not "ssh lap fails instead of connecting" xu dm-tpc2 "ssh -o BatchMode=yes -o ConnectTimeout=6 lap true"
x dm-thub devmesh apply
check "after the hub re-renders, the approved host key is back" xu dm-tpc2 "dm refresh && ssh -o BatchMode=yes -o ConnectTimeout=6 lap hostname"

say "signed client bundle (OSS-21)"
check_not "dm update refuses an unsigned bundle in signed mode" xu dm-tpc2 "dm update"

# ---------------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m (log: %s)\n' "$PASS" "$FAIL" "$LOG"
if ((FAIL)); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
