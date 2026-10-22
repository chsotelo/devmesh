#!/usr/bin/env bash
# End-to-end test of the hub container image (docker/hub). Standalone: builds the image,
# starts it on a bridge network in IP mode and probes it from a second plain container.
# Docker Desktop has no real host networking, so the test uses a bridge network, NET_ADMIN
# and /dev/net/tun instead of the compose file's network_mode: host.
# Usage: tests/integration/docker_hub.sh        KEEP=1 leaves the oss6-* resources behind.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NET=oss6-net
SUBNET=10.201.61.0/24
IP=10.201.61.10
HUB=oss6-hub
PROBE=oss6-probe
IMAGE=oss6-hub
VOLUMES=(oss6-etc oss6-var oss6-tls)
PASS=0
FAIL=0

ok() {
  printf '\033[32mok\033[0m   %s\n' "$1"
  PASS=$((PASS + 1))
}
bad() {
  printf '\033[31mFAIL\033[0m %s\n' "$1"
  FAIL=$((FAIL + 1))
}
# check DESC CMD... — pass when CMD succeeds.
check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

cleanup() {
  [[ ${KEEP:-0} == 1 ]] && return 0
  docker rm -f "$HUB" "$PROBE" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker volume rm "${VOLUMES[@]}" >/dev/null 2>&1 || true
  docker rmi "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

probe() { docker exec "$PROBE" "$@"; }
hub() { docker exec "$HUB" "$@"; }

# wait_for CMD... — retry for up to 90 s.
wait_for() {
  local _
  for _ in $(seq 1 90); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

health_code() { probe curl -s -o /dev/null -w '%{http_code}' --max-time 5 --pinnedpubkey "sha256//$1" -k "https://$IP:8443/v1/health"; }
health_ok() { [[ $(health_code "$(hub_pin)") == 200 ]]; }
hub_pin() { hub sed -n 's/^HUB_PIN=//p' /etc/devmesh/hub.conf; }
start_hub() {
  docker run -d --name "$HUB" --network "$NET" --ip "$IP" --cap-add NET_ADMIN --device /dev/net/tun \
    -e HUB_HOST="$IP" -v oss6-etc:/etc/devmesh -v oss6-var:/var/lib/devmesh -v oss6-tls:/etc/letsencrypt \
    "$IMAGE" >/dev/null
}

cleanup_before=${KEEP:-0}
KEEP=0 cleanup
KEEP=$cleanup_before

echo "== build"
if docker build -q -f "$REPO/docker/hub/Dockerfile" -t "$IMAGE" "$REPO" >/dev/null; then ok "image builds"; else
  bad "image builds"
  exit 1
fi
docker network create --subnet "$SUBNET" "$NET" >/dev/null
docker run -d --name "$PROBE" --network "$NET" ubuntu:24.04 sleep infinity >/dev/null
probe bash -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends curl openssh-client ca-certificates >/dev/null' >/dev/null 2>&1

echo "== start"
start_hub
if wait_for health_ok; then ok "pinned health check answers 200 on https://$IP:8443"; else
  bad "pinned health check answers 200 on https://$IP:8443"
  docker logs --tail 40 "$HUB" >&2 || true
  exit 1
fi
pin=$(hub_pin)
if [[ $pin =~ ^[A-Za-z0-9+/]{43}=$ ]]; then ok "hub.conf holds a certificate pin"; else bad "hub.conf holds a certificate pin"; fi
check "a wrong pin is rejected" bash -c "! docker exec $PROBE curl -sf --max-time 5 --pinnedpubkey 'sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' -k https://$IP:8443/v1/health"
check "devmesh sshd answers on 2222" bash -c "docker exec $PROBE ssh-keyscan -T 5 -p 2222 $IP | grep -q ssh-ed25519"
check "WireGuard interface is up" hub wg show devmesh
join=$(hub devmesh invite t1 2>/dev/null | sed -n 's/^JOIN: //p')
if [[ $join == *"--pinnedpubkey 'sha256//$pin' -k https://$IP:8443/j/"* ]]; then ok "invite t1 prints a pinned JOIN line"; else bad "invite t1 prints a pinned JOIN line"; fi
url=$(grep -Eo 'https://[^ ]+/j/[A-Z0-9]+' <<<"$join" || true)
code_http() { probe curl -s -o /dev/null -w '%{http_code}' --pinnedpubkey "sha256//$pin" -k "$url"; }
if [[ $(code_http) == 200 ]]; then ok "the join script is served"; else bad "the join script is served"; fi

echo "== restart keeps state"
docker restart "$HUB" >/dev/null
if wait_for health_ok; then ok "health answers after restart"; else bad "health answers after restart"; fi
if [[ $(hub_pin) == "$pin" ]]; then ok "same pin after restart"; else bad "same pin after restart"; fi
if [[ $(code_http) == 200 ]]; then ok "invite t1 still served after restart"; else bad "invite t1 still served after restart"; fi
check "invite t1 is still pending" bash -c "docker exec $HUB devmesh ls | grep -q t1"
check "a new invite works after restart" bash -c "docker exec $HUB devmesh invite t2 | grep -q '^JOIN: '"

echo "== supervisor"
hub pkill -f 'sshd -D' || true
rc=$(timeout 60 docker wait "$HUB" || echo timeout)
if [[ $rc =~ ^[0-9]+$ && $rc -ne 0 ]]; then ok "container exits non-zero when sshd dies (exit $rc)"; else bad "container exits non-zero when sshd dies ($rc)"; fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
