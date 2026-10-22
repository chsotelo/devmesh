#!/usr/bin/env bash
# End-to-end test with real systemd, sshd, WireGuard, tmux, nginx and ntfy in containers:
#   hub  (Ubuntu 20.04, like the VPS; Docker's FORWARD=DROP + DOCKER-USER emulated)
#   lap  (Ubuntu 24.04, ssh.socket activation)   pc2 (Ubuntu 22.04)
#   hub2 (Ubuntu 20.04) for the migration drill (backup -> restore -> DNS switch).
# Usage: tests/integration/run.sh        KEEP=1 to leave the containers running.
# Remote commands are deliberately single-quoted: they expand inside the containers.
# shellcheck disable=SC2016
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NET=devmesh-it
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
# check DESC CMD... — pass when CMD succeeds; output goes to the log.
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
# eventually SECONDS DESC CMD... — poll until CMD succeeds.
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
# xu CONTAINER 'shell code' — as the unprivileged user "dev", with a login environment.
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
  docker rm -f dm-hub dm-hub2 dm-hub3 dm-hub4 dm-lap dm-pc2 dm-dev3 >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [[ $FAIL -eq 0 ]] && rm -rf "$WORK"
}
trap cleanup EXIT

# Emulate what Docker does on the production VPS: FORWARD policy DROP, DOCKER-USER first.
emulate_docker_fw() {
  x "$1" bash -c 'iptables -N DOCKER-USER && iptables -A DOCKER-USER -j RETURN &&
    iptables -I FORWARD 1 -j DOCKER-USER && iptables -P FORWARD DROP'
}

install_hub() {
  local c=$1
  shift
  docker cp "$REPO/." "$c:/opt/devmesh-src"
  x "$c" env HUB_HOST="$HUB_HOST" TLS_CERT=/etc/ssl/devmesh.crt TLS_KEY=/etc/ssl/devmesh.key \
    BACKUP_RECIPIENT="$AGE_RECIPIENT" bash /opt/devmesh-src/server/install-hub.sh "$@"
}

ctr_ip() { docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$1"; }

# install_hub_ip CONTAINER IP [args] — hub in IP mode: no domain, no TLS_CERT, no ACME.
install_hub_ip() {
  local c=$1 ip=$2
  shift 2
  docker cp "$REPO/." "$c:/opt/devmesh-src"
  x "$c" env HUB_HOST="$ip" BACKUP_RECIPIENT="$AGE_RECIPIENT" bash /opt/devmesh-src/server/install-hub.sh "$@"
}

trust_hub_cert() {
  docker cp "$WORK/devmesh.crt" "$1:/usr/local/share/ca-certificates/devmesh.crt"
  x "$1" update-ca-certificates >/dev/null
}

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
say "containers"
docker network create "$NET" >/dev/null
start_host dm-hub devmesh-it:20.04 "$HUB_HOST"
start_host dm-lap devmesh-it:24.04
start_host dm-pc2 devmesh-it:22.04
age-keygen -o "$WORK/age.key" 2>/dev/null
AGE_RECIPIENT=$(age-keygen -y "$WORK/age.key")
x dm-hub openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$HUB_HOST" \
  -addext "subjectAltName=DNS:$HUB_HOST" -keyout /etc/ssl/devmesh.key -out /etc/ssl/devmesh.crt 2>/dev/null
docker cp dm-hub:/etc/ssl/devmesh.crt "$WORK/devmesh.crt"
trust_hub_cert dm-lap
trust_hub_cert dm-pc2
emulate_docker_fw dm-hub
x dm-hub sshd -T -C user=root,host=x,addr=203.0.113.9 >"$WORK/sshd-root-before"

say "hub install (twice: idempotent)"
check "install-hub on a fresh Ubuntu 20.04" install_hub dm-hub
if ((FAIL)); then
  printf '\nhub install failed; stopping (log: %s)\n' "$LOG"
  tail -n 30 "$LOG"
  exit 1
fi
check "install-hub re-run is idempotent" install_hub dm-hub
check "re-run changes nothing in the firewall" grep -q '(no changes)' "$LOG"
# OSS-25: the report of the FIRST install lists what install-hub added; devmesh rules only.
fw_report_lines() { awk '/^### install-hub on a fresh/ {f = 1; next} /^###/ {f = 0} f && /^[<>] /' "$LOG"; }
fw_report_only_devmesh() {
  local l n=0
  while IFS= read -r l; do
    n=$((n + 1))
    grep -qiE 'devmesh|51820' <<<"$l" || {
      echo "not a devmesh rule: $l"
      return 1
    }
  done < <(fw_report_lines)
  ((n > 0))
}
check "firewall report of install-hub shows only devmesh rules" fw_report_only_devmesh
check "the report includes the new hub rules (DEVMESH-HUB-IN and the DOCKER-USER drop)" bash -c \
  "grep -q 'DEVMESH-HUB-IN' <<<\"\$(awk '/^### install-hub on a fresh/ {f = 1; next} /^###/ {f = 0} f && /^[<>] /' '$LOG')\" && grep -q 'DOCKER-USER -i devmesh ! -o devmesh -j DROP' <<<\"\$(awk '/^### install-hub on a fresh/ {f = 1; next} /^###/ {f = 0} f && /^[<>] /' '$LOG')\""
x dm-hub sshd -T -C user=root,host=x,addr=203.0.113.9 >"$WORK/sshd-root-after"
check "global sshd settings for root are unchanged" diff "$WORK/sshd-root-before" "$WORK/sshd-root-after"
check_not "system sshd has no devmesh files" bash -c "docker exec dm-hub ls /etc/ssh/sshd_config.d/ | grep -q ."
check "devmesh-sshd runs on its own port 2222" bash -c "docker exec dm-hub systemctl is-active devmesh-sshd && docker exec dm-hub ss -Hltn | grep -q ':2222 '"
check "fail2ban bans cover 2222 and never the VPN subnet" bash -c \
  "docker exec dm-hub cat /etc/fail2ban/jail.d/devmesh.conf | grep -q 'port = ssh,2222' && docker exec dm-hub fail2ban-client get sshd ignoreip | grep -q '10.73.0.0/24'"
check "forward rule lives in DOCKER-USER" x dm-hub iptables -C DOCKER-USER -i devmesh -o devmesh -j ACCEPT
check "FORWARD policy is still DROP" bash -c "docker exec dm-hub iptables -S FORWARD | grep -qx -- '-P FORWARD DROP'"
check "timers active (gc, check, backup)" x dm-hub systemctl is-active devmesh-gc.timer devmesh-check.timer devmesh-backup.timer
check "ntfy runs behind nginx with TLS" x dm-hub curl -fsS --cacert /etc/ssl/devmesh.crt "https://$HUB_HOST/v1/health"
check_not "ntfy denies anonymous reads" x dm-hub curl -fsS --cacert /etc/ssl/devmesh.crt "https://$HUB_HOST/devmesh/json?poll=1"
check_not "join folder has no listing" x dm-hub curl -fsS --cacert /etc/ssl/devmesh.crt "https://$HUB_HOST/j/"

say "enrollment with the universal JOIN line (curl | sh -s SECRET), kind detected on the device"
check "lap (24.04) enrolls" enroll dm-hub lap dm-lap --lan home --watch-hub
check "pc2 (22.04) enrolls" enroll dm-hub pc2 dm-pc2 --lan home
machines_with_port() {
  x dm-hub awk -F'\t' '$2 == "machine" && $4 ~ /^22[0-9][0-9]$/ && $5 ~ /^[0-9]+$/' /etc/devmesh/registry.tsv | wc -l | tr -d ' '
}
check "both registered as machines with port and color from the hub" test "$(machines_with_port)" = 2
check_not "a used code cannot be replayed" bash -c "docker exec dm-hub ls /var/www/devmesh/j | grep -q ."
xu dm-lap "dm refresh" >>"$LOG" 2>&1 || true

say "network: WireGuard through the hub (Docker-style FORWARD DROP)"
eventually 30 "lap reaches the hub over WireGuard" x dm-lap ping -c1 -W2 10.73.0.1
eventually 30 "pc2 reaches lap peer-to-peer via the hub" x dm-pc2 ping -c1 -W2 10.73.0.2
check "lap client config routes only the devmesh subnet" bash -c "docker exec dm-lap grep -qx 'AllowedIPs = 10.73.0.0/24' /etc/wireguard/devmesh.conf"

say "ssh: path A, path B, pinned host keys"
# A new device's key reaches existing machines on their next key sync (<= 1 min, R3).
eventually 90 "lap learns pc2's key via the key-sync timer" bash -c "docker exec dm-lap grep -q 'devmesh:pc2' /etc/devmesh/clients.pub"
check "key-sync service succeeds when nothing changed" x dm-lap systemctl start devmesh-keys.service
check "pc2 -> lap over path A (WireGuard)" bash -c "[ \"\$(docker exec -u dev dm-pc2 bash -lc 'ssh -o BatchMode=yes lap hostname')\" = lap ]"
x dm-pc2 systemctl stop wg-quick@devmesh || true
check "pc2 -> lap over path B (reverse tunnel, WireGuard down)" bash -c "[ \"\$(docker exec -u dev dm-pc2 bash -lc 'ssh -o BatchMode=yes lap-b hostname')\" = lap ]"
x dm-pc2 systemctl start wg-quick@devmesh || true
LAP_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" dm-lap)
check_not "lap sshd is not reachable on its LAN address" x dm-hub nc -z -w3 "$LAP_IP" 22
check "ssh.socket disabled on 24.04, sshd bound to devmesh IP" bash -c "docker exec dm-lap ss -Hltn | grep -q '10.73.0.2:22'"
check_not "github-style hosts are untouched by the devmesh ssh config" bash -c \
  "docker exec -u dev dm-pc2 bash -lc 'ssh -G github.com' | grep -q devmesh_known_hosts"

say "terminals"
eventually 40 "tmux 'main' kept alive on lap (user service + linger)" x dm-lap sudo -u dev tmux has-session -t main
x dm-lap sudo -u dev tmux new-session -d -s work -c /home/dev || true
check "dm who on pc2 lists lap terminals" bash -c "docker exec -u dev dm-pc2 bash -lc 'dm who' | grep -q 'lap:work:0'"
check "dm _has works over ssh" xu dm-pc2 "ssh lap dm _has work"
check "dm _attach is refused for bad names" bash -c "! docker exec -u dev dm-pc2 bash -lc 'ssh lap dm _has \"a.b\"'"
x dm-lap sudo -u dev bash -c 'cd /home/dev && nohup python3 -m http.server 8000 --bind 127.0.0.1 >/dev/null 2>&1 &'
sleep 1
check "UI preview: localhost-only dev server reachable from pc2 via ssh -L" xu dm-pc2 \
  "ssh -f -N -o ExitOnForwardFailure=yes -L 127.0.0.1:18000:127.0.0.1:8000 lap && curl -fsS http://127.0.0.1:18000/ >/dev/null"
check "file transfer to a machine inbox" xu dm-pc2 "echo hi >/tmp/x.txt && scp -q /tmp/x.txt lap:devmesh-inbox/ 2>/dev/null || (ssh lap mkdir -p devmesh-inbox && scp -q /tmp/x.txt lap:devmesh-inbox/)"
check "the file landed" x dm-lap test -s /home/dev/devmesh-inbox/x.txt

say "hub status and key sync"
x dm-lap systemctl start devmesh-keys.service || true
check "lap accepts pc2's client key after sync" bash -c "docker exec dm-lap grep -q 'devmesh:pc2' /etc/devmesh/clients.pub"
check "devmesh ls: lap tunnel up and version reported" bash -c "docker exec dm-hub devmesh ls | grep -E '^lap .* up +[0-9]+ +[0-9]+\.[0-9]+\.[0-9]+ '"

# ---------------------------------------------------------------------------------
# OSS-25: mesh firewall. The machine decides what the mesh may reach; the hub protects itself.
say "mesh firewall (OSS-25): machine"
# The terminals section left a localhost-only server on 8000; replace it with one on 0.0.0.0.
x dm-lap pkill -f 'http.server 8000' || true
sleep 1
x dm-lap sudo -u dev bash -c 'cd /home/dev && nohup python3 -m http.server 8000 --bind 0.0.0.0 >/dev/null 2>&1 &'
sleep 1
lap_curl() { x "$1" curl -fsS -m 5 -o /dev/null "http://10.73.0.2:8000/"; }
check "lap serves 0.0.0.0:8000 locally" x dm-lap curl -fsS -m 5 -o /dev/null http://127.0.0.1:8000/
check "lap: mesh interface is filtered (hook into DEVMESH-IN)" x dm-lap iptables -C INPUT -i devmesh -j DEVMESH-IN
check "lap: the WireGuard config carries PostUp/PostDown exactly once" bash -c \
  "[ \"\$(docker exec dm-lap grep -c '^PostUp = .*devmesh-node-fw up %i' /etc/wireguard/devmesh.conf)\" = 1 ] && [ \"\$(docker exec dm-lap grep -c '^PostDown = .*devmesh-node-fw down %i' /etc/wireguard/devmesh.conf)\" = 1 ]"
check "lap: mosh range is allowed, the chain ends in DROP" bash -c \
  "docker exec dm-lap iptables -S DEVMESH-IN | grep -q -- '--dport 60000:61000 -j ACCEPT' && [ \"\$(docker exec dm-lap iptables -S DEVMESH-IN | tail -n 1)\" = '-A DEVMESH-IN -j DROP' ]"
check_not "pc2 cannot reach lap:8000 over the mesh" lap_curl dm-pc2
check_not "the hub cannot reach lap:8000 over the mesh (10.73.0.1)" lap_curl dm-hub
check "pc2 -> lap ssh over the mesh still works" bash -c "[ \"\$(docker exec -u dev dm-pc2 bash -lc 'ssh -o BatchMode=yes lap hostname')\" = lap ]"
check "pc2 -> lap ping still works" x dm-pc2 ping -c1 -W2 10.73.0.2
check "hub -> lap ping still works" x dm-hub ping -c1 -W2 10.73.0.2
check "dm mesh (no root) shows the state and the sudo command" bash -c \
  "docker exec -u dev dm-lap bash -lc 'dm mesh' | grep -q 'sudo devmesh-node mesh open'"
check_not "devmesh-node mesh open needs root" xu dm-lap "/usr/local/sbin/devmesh-node mesh open tcp/8000"
check "devmesh-node mesh open tcp/8000" x dm-lap /usr/local/sbin/devmesh-node mesh open tcp/8000
check "pc2 reaches lap:8000 once opened" lap_curl dm-pc2
check "the hub reaches lap:8000 once opened" lap_curl dm-hub
check "open is idempotent (one entry in node.conf)" bash -c \
  "[ \"\$(docker exec dm-lap grep -c '^DM_MESH_OPEN=' /etc/devmesh/node.conf)\" = 1 ] && docker exec dm-lap /usr/local/sbin/devmesh-node mesh open tcp/8000 && [ \"\$(docker exec dm-lap grep -c '^DM_MESH_OPEN=' /etc/devmesh/node.conf)\" = 1 ]"
check "devmesh-node mesh status lists tcp/8000" bash -c "docker exec dm-lap /usr/local/sbin/devmesh-node mesh status | grep -q 'tcp/8000'"

say "mesh firewall: outbound paths and lifecycle on lap (port 8000 open)"
x dm-lap systemctl stop wg-quick@devmesh || true
check_not "WireGuard down: PostDown removed the hook" x dm-lap iptables -C INPUT -i devmesh -j DEVMESH-IN
check_not "WireGuard down: PostDown removed the chain" x dm-lap iptables -n -L DEVMESH-IN
x dm-lap systemctl start wg-quick@devmesh || true
eventually 30 "WireGuard up: PostUp restored the hook, with the opened port" bash -c \
  "docker exec dm-lap iptables -C INPUT -i devmesh -j DEVMESH-IN && docker exec dm-lap iptables -S DEVMESH-IN | grep -q -- '--dport 8000 -j ACCEPT'"
eventually 30 "lap -> hub over WireGuard (outbound reply path)" x dm-lap ping -c1 -W2 10.73.0.1
eventually 30 "lap -> pc2 ssh over the mesh (dm toward other machines)" xu dm-lap "ssh -o BatchMode=yes -o ConnectTimeout=5 pc2 hostname"
check "lap -> hub-admin still works" xu dm-lap "ssh -o ConnectTimeout=5 hub-admin version"
check "lap's reverse tunnel (path B) is still up on the hub" bash -c "docker exec dm-hub ss -Hltn | grep -q '127.0.0.1:2202'"
check "devmesh-node mesh close tcp/8000" x dm-lap /usr/local/sbin/devmesh-node mesh close tcp/8000
check_not "pc2 cannot reach lap:8000 after close" lap_curl dm-pc2
check_not "the hub cannot reach lap:8000 after close" lap_curl dm-hub
check_not "DM_MESH_OPEN is gone from node.conf" x dm-lap grep -q '^DM_MESH_OPEN=' /etc/devmesh/node.conf
check "ssh from pc2 still works after close" bash -c "[ \"\$(docker exec -u dev dm-pc2 bash -lc 'ssh -o BatchMode=yes lap hostname')\" = lap ]"

# An older machine (no hooks yet) is protected by what "dm update" runs: linux_install_client.
x dm-lap bash -c "iptables -D INPUT -i devmesh -j DEVMESH-IN; sed -i '/devmesh-node-fw/d' /etc/wireguard/devmesh.conf"
check "older machine: without hooks lap:8000 is open again (control)" lap_curl dm-pc2
docker cp "$REPO/client" dm-lap:/tmp/dist-client
check "dm update's installer adds the hooks and applies the firewall" x dm-lap env DM_DIST_DIR=/tmp/dist-client \
  DM_VERSION="$(cat "$REPO/VERSION")" bash -c 'source "$DM_DIST_DIR/lib/bootstrap_linux.sh" && linux_install_client'
check_not "older machine: lap:8000 is blocked after the update" lap_curl dm-pc2
check "older machine: hooks present once" bash -c \
  "[ \"\$(docker exec dm-lap grep -c 'devmesh-node-fw' /etc/wireguard/devmesh.conf)\" = 2 ]"
x dm-lap pkill -f 'http.server 8000' || true

say "mesh firewall (OSS-25): hub"
x dm-hub bash -c 'nohup python3 -m http.server 8099 --bind 0.0.0.0 >/dev/null 2>&1 &'
sleep 1
check "hub: INPUT from devmesh jumps to DEVMESH-HUB-IN" x dm-hub iptables -C INPUT -i devmesh -j DEVMESH-HUB-IN
hub_chain_ok() {
  local out
  out=$(x dm-hub iptables -S DEVMESH-HUB-IN | grep '^-A')
  [[ $(wc -l <<<"$out" | tr -d ' ') == 4 ]] &&
    grep -q 'ESTABLISHED' <<<"$(sed -n 1p <<<"$out")" &&
    grep -q 'icmp' <<<"$(sed -n 2p <<<"$out")" &&
    grep -q -- '--dport 2222 -j ACCEPT' <<<"$(sed -n 3p <<<"$out")" &&
    [[ $(sed -n 4p <<<"$out") == '-A DEVMESH-HUB-IN -j DROP' ]]
}
check "hub: the chain allows only established, ping and 2222, then drops" hub_chain_ok
docker_user_order_ok() {
  local out
  out=$(x dm-hub iptables -S DOCKER-USER | grep '^-A')
  [[ $(sed -n 1p <<<"$out") == '-A DOCKER-USER -i devmesh ! -o devmesh -j DROP' ]] &&
    [[ $out == *'-A DOCKER-USER -i devmesh -o devmesh -j ACCEPT'* ]]
}
check "hub: DOCKER-USER drop (devmesh -> anywhere but devmesh) sits before the devmesh ACCEPT" docker_user_order_ok
check_not "lap -> hub 10.73.0.1:2586 (ntfy) fails" x dm-lap curl -fsS -m 5 -o /dev/null http://10.73.0.1:2586/
check_not "lap -> hub 10.73.0.1:443 (nginx) fails" x dm-lap nc -z -w3 10.73.0.1 443
check_not "lap -> hub 10.73.0.1:8099 (any other port) fails" x dm-lap curl -fsS -m 5 -o /dev/null http://10.73.0.1:8099/
check "lap -> hub 10.73.0.1:2222 responds" x dm-lap nc -z -w3 10.73.0.1 2222
check "lap -> hub ping works" x dm-lap ping -c1 -W2 10.73.0.1
x dm-hub iptables -D INPUT -i devmesh -j DEVMESH-HUB-IN
check "control: without the INPUT rule lap reaches hub:8099 (the filter is what blocks it)" \
  x dm-lap curl -fsS -m 5 -o /dev/null http://10.73.0.1:8099/
x dm-hub /usr/local/sbin/devmesh-fw up devmesh
check_not "hub: re-applying the rules blocks hub:8099 again" x dm-lap curl -fsS -m 5 -o /dev/null http://10.73.0.1:8099/
check "devmesh-fw up is idempotent (one hook, one drop rule)" bash -c \
  "[ \"\$(docker exec dm-hub iptables -S INPUT | grep -c 'DEVMESH-HUB-IN')\" = 1 ] && [ \"\$(docker exec dm-hub iptables -S DOCKER-USER | grep -c -- '! -o devmesh -j DROP')\" = 1 ]"

# A container published on the hub, emulated the way Docker does it: DNAT of any local address
# to a backend (pc2 plays the container), forwarded through FORWARD -> DOCKER-USER.
PUB_BACKEND=$(ctr_ip dm-pc2)
HUB_LAN_IP=$(ctr_ip dm-hub)
x dm-pc2 bash -c 'nohup python3 -m http.server 8080 --bind 0.0.0.0 >/dev/null 2>&1 &'
published_rules() {
  x dm-hub bash -c "iptables -t nat $1 PREROUTING -p tcp --dport 18080 -m addrtype --dst-type LOCAL -j DNAT --to-destination $PUB_BACKEND:8080 &&
    iptables -t nat $1 POSTROUTING -d $PUB_BACKEND -p tcp --dport 8080 -j MASQUERADE &&
    iptables $1 FORWARD -p tcp -d $PUB_BACKEND --dport 8080 -j ACCEPT &&
    iptables $1 FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
}
if published_rules -A >>"$LOG" 2>&1; then
  sleep 1
  check "published container: reachable through the hub's public (non-mesh) address, as before" \
    x dm-lap curl -fsS -m 5 -o /dev/null "http://$HUB_LAN_IP:18080/"
  check_not "published container: not reachable through 10.73.0.1 from lap" \
    x dm-lap curl -fsS -m 5 -o /dev/null http://10.73.0.1:18080/
  x dm-hub iptables -D DOCKER-USER -i devmesh '!' -o devmesh -j DROP
  check "control: without the DOCKER-USER drop the container IS reachable via the mesh" \
    x dm-lap curl -fsS -m 5 -o /dev/null http://10.73.0.1:18080/
  x dm-hub /usr/local/sbin/devmesh-fw up devmesh
  check_not "published container: blocked again after re-applying the rules" \
    x dm-lap curl -fsS -m 5 -o /dev/null http://10.73.0.1:18080/
  published_rules -D >>"$LOG" 2>&1 || true
else
  printf 'SKIP published-container sub-check: DNAT emulation unavailable in this Docker VM (see log)\n'
fi
x dm-hub pkill -f 'http.server 8099' || true
x dm-pc2 pkill -f 'http.server 8080' || true

say "restrictions (production hub)"
check "dmadmin allowlist works" xu dm-pc2 "ssh hub-admin ls"
check_not "dmadmin: no command chaining" xu dm-pc2 "ssh hub-admin 'ls; id'"
check_not "dmadmin: no arbitrary command" xu dm-pc2 "ssh hub-admin id"
check_not "tunnel user: no shell" xu dm-pc2 "ssh hub-jump id"
check_not "root cannot log in on the devmesh port" x dm-lap ssh -p 2222 -o BatchMode=yes -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /etc/devmesh/tunnel_ed25519 root@hub.devmesh.test true
check_not "passwords are refused on the devmesh port" x dm-lap ssh -p 2222 -o BatchMode=yes -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password,keyboard-interactive tunnel@hub.devmesh.test true
check_not "client key cannot squat a tunnel port with -R" xu dm-pc2 \
  "timeout 15 ssh -o ExitOnForwardFailure=yes -N -R localhost:2299:localhost:22 hub-jump"
x dm-lap bash -c 'ssh -f -N -p 2222 -i /etc/devmesh/tunnel_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes \
  -o UserKnownHostsFile=/etc/devmesh/known_hosts -o HostKeyAlias=hub.devmesh.test \
  -L 127.0.0.1:19999:127.0.0.1:22 tunnel@hub.devmesh.test' >>"$LOG" 2>&1 || true
check_not "machine tunnel key cannot -L into hub services" x dm-lap bash -c \
  'exec 3<>/dev/tcp/127.0.0.1/19999 && timeout 3 head -c 4 <&3 | grep -q SSH'
x dm-lap pkill -f 'L 127.0.0.1:19999' || true

say "alerts (machine down / back) through the authenticated ntfy"
x dm-hub bash -c 'printf "DOWN_AFTER=5\nALERT_GRACE=1\n" >>/etc/devmesh/hub.conf'
x dm-lap systemctl stop devmesh-tunnel.service wg-quick@devmesh || true
sleep 8
x dm-hub devmesh check || true
sleep 2
x dm-hub devmesh check || true
SUB=$(x dm-hub awk '{print $NF}' /etc/devmesh/ntfy-subscriber.txt)
ntfy_has() {
  x dm-hub curl -fsS --cacert /etc/ssl/devmesh.crt -u "devmesh-sub:$SUB" "https://$HUB_HOST/devmesh/json?poll=1" |
    grep -q "$1"
}
check "alert 'lap is down' delivered" ntfy_has 'lap is down'
x dm-lap systemctl start wg-quick@devmesh devmesh-tunnel.service || true
eventually 30 "lap back on WireGuard" x dm-lap ping -c1 -W2 10.73.0.1
x dm-hub devmesh check || true
check "alert 'lap is back' delivered" ntfy_has 'lap is back'

say "revocation"
check "remove pc2" x dm-hub devmesh remove pc2 --confirm pc2
check_not "pc2 loses hub-admin immediately" xu dm-pc2 "ssh -o ConnectTimeout=5 hub-admin ls"
check_not "pc2 loses path B immediately" xu dm-pc2 "ssh -o ConnectTimeout=5 lap-b true"
check_not "pc2 loses WireGuard immediately" x dm-pc2 ping -c1 -W2 10.73.0.2
x dm-lap systemctl start devmesh-keys.service || true
check_not "lap drops pc2's key after sync" bash -c "docker exec dm-lap grep -q 'devmesh:pc2' /etc/devmesh/clients.pub"
x dm-pc2 systemctl start devmesh-keys.service || true
check "revoked pc2 backs off instead of hammering the hub" x dm-pc2 test -s /var/lib/devmesh/revoked
check "the hub did not ban pc2's address" bash -c "! docker exec dm-hub fail2ban-client status sshd | grep -q \"\$(docker inspect -f '{{(index .NetworkSettings.Networks \"devmesh-it\").IPAddress}}' dm-pc2)\""

say "backup -> restore on a new hub -> DNS switch (migration drill)"
BK=$(x dm-hub devmesh backup || true)
docker cp "dm-hub:$BK" "$WORK/state.age"
check "backup decrypts only with the owner's age key" age -d -i "$WORK/age.key" -o "$WORK/state.tgz" "$WORK/state.age"
OLD_KEY=$(x dm-hub ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')
start_host dm-hub2 devmesh-it:20.04
emulate_docker_fw dm-hub2
docker cp dm-hub:/etc/ssl/devmesh.crt "$WORK/hub.crt"
docker cp dm-hub:/etc/ssl/devmesh.key "$WORK/hub.key"
docker cp "$WORK/hub.crt" dm-hub2:/etc/ssl/devmesh.crt
docker cp "$WORK/hub.key" dm-hub2:/etc/ssl/devmesh.key
docker cp "$WORK/state.tgz" dm-hub2:/root/state.tgz
check "install-hub --restore on the new VPS" install_hub dm-hub2 --restore /root/state.tgz
check "same SSH host key after restore" bash -c "[ \"\$(docker exec dm-hub2 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print \$2}')\" = '$OLD_KEY' ]"
# "DNS switch": the old hub leaves, the new one takes the name.
docker network disconnect "$NET" dm-hub || true
docker network disconnect "$NET" dm-hub2 || true
docker network connect --alias "$HUB_HOST" "$NET" dm-hub2
check "devices are known to the new hub" bash -c "docker exec dm-hub2 devmesh ls | grep -q '^lap '"
eventually 30 "lap reaches hub-admin on the new hub with its pinned key" xu dm-lap "ssh -o ConnectTimeout=5 hub-admin version"
eventually 330 "lap follows the hub to its new IP over WireGuard (reresolve timer)" x dm-lap ping -c1 -W2 10.73.0.1
eventually 120 "lap's reverse tunnel is back on the new hub" bash -c "docker exec dm-hub2 ss -Hltn | grep -q '127.0.0.1:2202'"

# ---------------------------------------------------------------------------------
# OSS-05: hub without a domain. Self-signed certificate + pinned public key.
say "IP mode: join with a pinned self-signed hub, TLS proxy attack, migration with dm repoint"
start_host dm-hub3 devmesh-it:20.04
start_host dm-dev3 devmesh-it:22.04
emulate_docker_fw dm-hub3
HUB3_IP=$(ctr_ip dm-hub3)
check "install-hub with HUB_HOST=<ip> (no certificate given)" install_hub_ip dm-hub3 "$HUB3_IP"
hub3_pin() { x dm-hub3 grep '^HUB_PIN=' /etc/devmesh/hub.conf; }
rerun_keeps_pin() {
  local before
  before=$(hub3_pin)
  x dm-hub3 env HUB_HOST="$HUB3_IP" bash /opt/devmesh-src/server/install-hub.sh >/dev/null 2>&1
  [[ -n $before && $before == "$(hub3_pin)" ]]
}
check "IP-mode re-run keeps the same certificate" rerun_keeps_pin
JOIN3=$(x dm-hub3 devmesh invite dev3 | sed -n 's/^JOIN: //p')
PIN3=$(sed -n "s/.*sha256\/\/\([^']*\)'.*/\1/p" <<<"$JOIN3")
join_is_pinned() { [[ $JOIN3 == "curl -fsSL --pinnedpubkey 'sha256//$PIN3' -k https://$HUB3_IP:8443/j/"* && -n $PIN3 ]]; }
check "the printed line carries --pinnedpubkey and -k for the hub IP" join_is_pinned
check "dev3 joins with the printed line" xu dm-dev3 "$JOIN3"
check "node.conf records the hub pin" x dm-dev3 grep -qx "DM_HUB_PIN=$PIN3" /etc/devmesh/node.conf
check "the pin connects to the real hub (-k, correct pin)" x dm-lap curl -fsS --pinnedpubkey "sha256//$PIN3" -k "https://$HUB3_IP:8443/v1/health"

# A TLS endpoint with another certificate on the hub's address, as a man in the middle would present.
x dm-hub3 openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=fake \
  -keyout /tmp/fake.key -out /tmp/fake.crt 2>/dev/null
docker exec -d dm-hub3 openssl s_server -accept 9443 -cert /tmp/fake.crt -key /tmp/fake.key -www
sleep 2
pin_rejected() {
  local rc=0
  x dm-lap curl -fsS --pinnedpubkey "sha256//$PIN3" -k "https://$HUB3_IP:9443/" >/dev/null 2>&1 || rc=$?
  [[ $rc -eq 90 ]]
}
check "a TLS endpoint with another certificate fails the pin (curl error 90, even with -k)" pin_rejected

eventually 30 "dev3 reaches hub3 over WireGuard" x dm-dev3 ping -c1 -W2 10.73.0.1
xu dm-dev3 "dm refresh" >>"$LOG" 2>&1 || true
BK3=$(x dm-hub3 devmesh backup || true)
docker cp "dm-hub3:$BK3" "$WORK/state3.age"
age -d -i "$WORK/age.key" -o "$WORK/state3.tgz" "$WORK/state3.age" >>"$LOG" 2>&1 || true
check "the IP-mode backup carries the tls directory" bash -c "tar -tzf '$WORK/state3.tgz' | grep -q 'etc/devmesh/tls/cert.pem'"

start_host dm-hub4 devmesh-it:20.04
emulate_docker_fw dm-hub4
HUB4_IP=$(ctr_ip dm-hub4)
docker cp "$WORK/state3.tgz" dm-hub4:/root/state.tgz
check "restore on a new hub with another IP" install_hub_ip dm-hub4 "$HUB4_IP" --restore /root/state.tgz
check "restore prints the dm repoint hint" bash -c "grep -q 'dm repoint $HUB4_IP' '$LOG'"
docker network disconnect "$NET" dm-hub3 || true
# Root-owned files (node.conf, WireGuard config) are changed by the sudo commands repoint prints.
repoint_dev3() {
  xu dm-dev3 "dm repoint $HUB4_IP 2>&1 | tee /tmp/repoint.out | sed -n 's/^  \\(sudo .*\\)\$/\\1/p' | sh && grep -q refreshed /tmp/repoint.out"
}
check "dm repoint on dev3 (host key matches the pinned one)" repoint_dev3
check "node.conf points at the new hub" x dm-dev3 grep -qx "DM_HUB_HOST=$HUB4_IP" /etc/devmesh/node.conf
eventually 30 "dev3 reaches hub-admin on the new hub (pinned key)" xu dm-dev3 "ssh -o ConnectTimeout=5 hub-admin version"
eventually 60 "path A: dev3 reaches the new hub over WireGuard" x dm-dev3 ping -c1 -W2 10.73.0.1
eventually 150 "path B: dev3's reverse tunnel is back on the new hub" bash -c "docker exec dm-hub4 ss -Hltn | grep -q '127.0.0.1:22[0-9][0-9]'"

# ---------------------------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m (log: %s)\n' "$PASS" "$FAIL" "$LOG"
if ((FAIL)); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
