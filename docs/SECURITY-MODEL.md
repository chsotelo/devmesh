# devmesh security model

## Assets

- **Access to your machines**: who can open an SSH session on each machine.
- **Terminal contents**: what you type and see in the shared tmux sessions.
- **Keys**: each device's client key (`~/.ssh/id_devmesh`), machines' host keys, WireGuard keys, the hub's keys.
- **Client code** that `dm update` installs on every device.

## Mechanism

Approvers are devices of yours (the first one joins with `devmesh invite <name> --owner`). They sign with `ssh-keygen -Y sign`, namespace `devmesh`:

| Message | Meaning |
|---|---|
| `devmesh-client-v1 <name> <key>` | a device's client key may log in to machines |
| `devmesh-host-v1 <name> <key>` | a machine's SSH host key |
| `devmesh-signer-v1 <name> <key>` | a device is also an approver |
| `devmesh-bundle-v1 <version> <sha256>` | the client bundle for `dm update` |
| `devmesh-revoke-v1 <name> <key>` | a key is revoked |
| `devmesh-epoch-v1 <serial> <sha256>` | the revocation set at serial N |

Each device verifies against its local `allowed_signers` (`ssh-keygen -Y verify`); the hub only stores and repeats signatures. Machines install only verified client keys (`devmesh-node`, every minute); `dm refresh` builds `known_hosts` only from signed host keys; `dm update` installs only a signed bundle that is not older than the installed one. Revocations are kept locally, so an old valid signature of a revoked key is never accepted again, and the signed epoch (serial + hash of the revocation set) makes a bundle that hides a revocation, or rolls back, get rejected. The hub's `ssh_config` and device list are unsigned but validated against the exact grammar the hub renders (no commands, aliases limited to known devices, trust options required).

## Attackers

| Attacker | Without approvers (0.7) | With approvers, devices in signed mode |
|---|---|---|
| Internet, no keys | Nothing: only 51820/udp, 2222/tcp and 443 or 8443/tcp are open; joining needs the code and its secret | Same |
| Stolen join line | Joins a device if used within 15 min (single use) | The device is **pending**: machines do not accept its key until an approver signs it, and the approver must type, for every key it signs, the last 16 characters of that key's fingerprint as printed on the new device: the client key, plus the host key for a machine (also for `--signer`) |
| Root on the hub | Adds a key and enters machines; impersonates machines; ships code to every device | Cannot add access, impersonate a machine or ship code. Can cut the service, see metadata (names, IPs, who connects and when), refuse to publish approvals or revocations, and attack devices that have not joined yet (see below) |
| Stolen phone or laptop | Enters machines until `dm rm` | Same until revoked. If it is an approver: revoke it from another approver (`dm rm`), which signs the revocation; machines drop the key and approver at the next sync |
| Compromised machine | That machine and the projects on it; its mesh address could probe other machines, but they answer only SSH, mosh and ping (Linux) | Same |

## Residual risks

- **Trust on first use at join.** The hub serves the join script, the first approver list and the current epoch. A hub compromised before a device joins can make that device trust the wrong approvers. Mitigation: at the end of the join the device prints its fingerprints; the approver types the last 16 characters of each key it signs (client, and host for machines), never shown by `dm approve`. `dm trust pin` asks for the last 16 characters of the owner's fingerprint read on the owner device (`dm trust status`): the root of trust is exactly that one confirmed key, and every other approver is accepted only through a valid signature chain from it (a second `owner` row is refused). Never copy these values from the hub.
- **Open mode.** Devices without `allowed_signers` (not pinned, `DM_TRUST` not `signed`) behave as in 0.7: the hub controls their keys, host keys and updates. `dm trust pin` ends this, one device at a time.
- **Metadata and availability.** The hub sees the topology and connection metadata and can drop service. Device names and IPs are not secret.
- **Revocation freshness.** A device learns about a revocation when it syncs a bundle carrying the new epoch. Until then, or while the hub withholds the new bundle entirely, it keeps trusting the key. A device that has seen epoch N never accepts anything older, nor a serial more than 1000 ahead of the stored one.
- **Approver compromise.** An approver key can approve anything until it is revoked by another approver. Keep approvers few and locked.
- **Requirement.** Verifying devices need OpenSSH 8.1 or newer (`ssh-keygen -Y`): Ubuntu 20.04 and later, macOS 13 and later, current Termux.
- **Not protected.** The operating system of each machine, and what Claude or any program runs there.

## Exposed ports (hub)

| Port | Why |
|---|---|
| 51820/udp | WireGuard (path A) |
| 2222/tcp | devmesh's own sshd: restricted accounts only (`enroll`, `dmadmin`, `tunnel`), keys only, no shell |
| 443/tcp (domain mode) or 8443/tcp (IP mode) | join scripts and ntfy |
| 80/tcp (domain mode, optional) | Let's Encrypt challenge |
| `HUB_OPEN_PORTS` (optional, from the mesh only) | services running on the hub itself that the owner opens on purpose, e.g. `HUB_OPEN_PORTS="8730 9000/udp"` in `hub.conf` (TCP by default, `port/udp` for UDP) |

From the mesh (interface `devmesh`) the hub accepts only established traffic, ping, 2222/tcp and
the ports listed in `HUB_OPEN_PORTS` (chain `DEVMESH-HUB-IN`; invalid entries are skipped with a
warning). Those rules apply to INPUT from the `devmesh` interface only, so an opened port is
reachable from the mesh and never from the internet. A service on the hub that has no encryption of
its own ends at the hub itself: nothing crosses the mesh decrypted beyond the WireGuard tunnel that
terminates there. Apply a change with `devmesh-fw up devmesh` (idempotent, the tunnel stays up).
The hub's `DOCKER-USER` rule, and Docker's `DOCKER-USER` drops what enters from the mesh and is
routed anywhere else, so containers published on the VPS are not reachable through `10.73.0.1`.
Forwarding between devices stays open on the hub: the filter is on each machine.

## Exposed ports (machines)

| Where | Port | Why |
|---|---|---|
| Mesh, Linux machine | 22/tcp | sshd (listens on the devmesh IP and on `127.0.0.1`) |
| Mesh, Linux machine | 60000-61000/udp | mosh (path A) |
| Mesh, Linux machine | ping | diagnosis |
| Mesh, Linux machine | `DM_MESH_OPEN` | only what the owner opens with `sudo devmesh-node mesh open` |
| Mesh, any other port | n/a | dropped by the chain `DEVMESH-IN` on the machine (installed by `PostUp` of the WireGuard interface), so a service on `0.0.0.0` is not reachable by other devices or by the hub |
| macOS, Android/Termux | n/a | no mesh firewall (no `pf` / no root); macOS sshd listens on `127.0.0.1` only |

Traffic with no encryption of its own that crosses the mesh is decrypted at the hub (star
topology), so root on the hub can read it. SSH and `dm port` (inside SSH) are not readable.
Use `dm port` for web servers and databases instead of opening them.

## The Go panel (`dm-tui`)

`dm-tui` is a presentation layer and nothing else: it holds no keys, opens no network connection and has no ssh code. Every remote or sensitive operation is done by the bash `dm`, started with an argument vector (never a shell string), and arguments are validated again in Go before they are passed. What machines send (window names, commands, screens, project folders) is untrusted: escape sequences, control characters and bidi marks are stripped before anything is drawn, so a terminal title cannot move the cursor or fake the interface. The binaries travel in the signed client bundle (`devmesh-bundle-v1`), so `dm update` verifies them like the scripts.

## Trust dependencies

OpenSSH (signatures, sshd), WireGuard, nginx, ntfy, curl, tmux; in domain mode, Let's Encrypt; for backups, age. A flaw in any of these is outside what the signatures cover.
