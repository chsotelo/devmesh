# devmesh hub in Docker

```sh
HUB_HOST=203.0.113.10 docker compose -f docker/hub/compose.yml up -d --build
docker exec devmesh-hub-hub-1 devmesh invite lap     # container name: docker compose ps
```

- `HUB_HOST` is the public IP (IP mode: self-signed certificate, HTTPS on 8443, the join line carries the pin) or a domain.
- Host networking is required (WireGuard creates its interface in the host namespace). Open UDP 51820 and TCP 2222, plus TCP 8443 (IP mode) or 80/443 (domain mode).
- State lives in the volumes `devmesh-etc` (`/etc/devmesh`), `devmesh-var` (`/var/lib/devmesh`, also ntfy data, join scripts and backups) and `devmesh-tls` (`/etc/letsencrypt`).
- If the host kernel has no WireGuard module the entrypoint uses `wireguard-go`.
- `BACKUP_RECIPIENT=age1...` enables the daily encrypted backup (`docker exec ... devmesh backup-latest`).

Limitations:

- fail2ban is not run in the container; run it on the host and ban ports `ssh,2222`, never `10.73.0.0/24`.
- Domain mode needs a certificate: mount `TLS_CERT`/`TLS_KEY` or set `ACME_EMAIL` (DNS must point at the host, port 80 free; the entrypoint requests it through the running nginx and renews daily).
- `net.ipv4.ip_forward` is a host sysctl; enable it on the host if the container cannot.
- The entrypoint exits non-zero if sshd, nginx, ntfy or the maintenance loop dies; `restart: unless-stopped` restarts the hub.
