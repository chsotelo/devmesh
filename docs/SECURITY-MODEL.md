# devmesh security model

## Assets

- **Access to your machines**: who can open an SSH session on each machine.
- **Terminal contents**: what you type and see in the terminals on your machines (`dm go` sessions, Herdr terminals).
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

Each device verifies against its local `allowed_signers` (`ssh-keygen -Y verify`); the hub only stores and repeats signatures. Machines install only verified client keys (`devmesh-node`, every minute); `dm refresh` builds `known_hosts` only from signed host keys; `dm update` installs only a signed bundle that is not older than the installed one; unattended updates (`devmesh-node update` on machines every 30 minutes, `dm` on Macs and phones when it opens) run only in signed mode, with the same check, and the hub serves machines the signed bundle alone. Revocations are kept locally, so an old valid signature of a revoked key is never accepted again, and the signed epoch (serial + hash of the revocation set) makes a bundle that hides a revocation, or rolls back, get rejected. The hub's `ssh_config` and device list are unsigned but validated against the exact grammar the hub renders (no commands, aliases limited to known devices, trust options required).

## Attackers

| Attacker | Without approvers (0.7) | With approvers, devices in signed mode |
|---|---|---|
| Internet, no keys | Nothing: only 51820/udp, 2222/tcp and 443 or 8443/tcp are open; joining needs the code and its secret | Same |
| Stolen join line | Joins a device if used within 15 min (single use) | The device is **pending**: machines do not accept its key until an approver signs it, and the approver must type, for every key it signs, the last 16 characters of that key's fingerprint as printed on the new device: the client key, plus the host key for a machine (also for `--signer`). Until then it is a mesh peer that can only read (`ls`, `hosts`, `bundle`...) and remove itself: it cannot remove other devices, invite, or push notifications |
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
- **Not protected.** The operating system of each machine, and what any program, agent or terminal runs there.

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
| Trusted LAN, Linux machine | 22/tcp, 60000-61000/udp | only while the machine is on a LAN its owner trusted (`sudo devmesh-node lan trust`: subnet **and** router MAC, `DM_LAN_TRUST`). Then sshd also binds the LAN address and the chain `DEVMESH-LAN` accepts that subnet on that interface only. On any other network (a cafe using the same range has another router) sshd is not bound to the LAN at all and `DEVMESH-LAN` drops these ports outside the mesh and localhost. `devmesh-lan.timer` re-checks every minute |
| Mesh, Linux machine | 60000-61000/udp | mosh (path A) |
| Mesh, Linux machine | ping | diagnosis |
| Mesh, Linux machine | `DM_MESH_OPEN` | only what the owner opens with `sudo devmesh-node mesh open` |
| Mesh, any other port | n/a | dropped by the chain `DEVMESH-IN` on the machine (installed by `PostUp` of the WireGuard interface), so a service on `0.0.0.0` is not reachable by other devices or by the hub. Ports Docker publishes never reach `INPUT` (Docker DNATs them to the container): the chain `DEVMESH-FWD`, hooked from `DOCKER-USER`, applies the same allowlist to them |
| macOS, Android/Termux | n/a | no mesh firewall (no `pf` / no root); macOS sshd listens on `127.0.0.1` only |

Path L (same LAN) changes where the connection goes, not what it trusts: the client only uses
an address the machine itself reported over path A/B while on a trusted LAN, private and
without leading zeros, with the same pinned host key (`HostKeyAlias`,
`StrictHostKeyChecking`). A stale address or a different host fails and `dm` falls back to the
hub. Fail-closed: the guarantee is sshd's bind, not only the firewall, so a flushed iptables
does not expose sshd on an untrusted network. Up to one minute after leaving a trusted LAN
for a network with the same subnet and the same address, sshd may still be bound there
(pubkey only) until the timer runs.

Traffic with no encryption of its own that crosses the mesh is decrypted at the hub (star
topology), so root on the hub can read it. SSH and `dm port` (inside SSH) are not readable.
Use `dm port` for web servers and databases instead of opening them.

## Herdr app keys and machine power

- **Herdr app keys (`dm herdr`).** `dm herdr allow <device> <ssh-public-key>` appends one line
  to `~/.ssh/authorized_keys` on every machine, tagged `devmesh-herdr:<device>`. The line is
  restricted with `from="<the device's mesh IP>"` and `no-agent-forwarding,no-port-forwarding,no-X11-forwarding`,
  so the key works only from that device's mesh address and cannot forward anything. It is
  a login separate from the device's devmesh client key: the approver signatures do not cover
  it, and the mesh address limits where it can be used, not who holds the private key.
  `dm herdr ls` lists the keys, `dm herdr revoke <device>` removes them, and `dm rm <device>`
  revokes them on every online machine (offline ones are reported; run the revoke again later).
  The address of a removed device is quarantined on the hub: it is handed out again only when no
  other address is free, so a line left on an offline machine does not match the next device.
- **macOS.** devmesh's own sshd on a Mac is localhost-only. For the Herdr app the owner turns
  on macOS Remote Login on purpose, which opens port 22 on the Mac's network interfaces:
  allow only your user, turn off full disk access for remote users, and make that sshd keys-only.
- **`dm use`** runs a command in a Herdr terminal on a machine over the same SSH access as
  `dm go`. It wakes the machine first with Wake-on-LAN when it is asleep. It needs herdr-core
  on the target; devmesh never installs it.
- **Power:** Linux nodes get `/etc/polkit-1/rules.d/50-devmesh-power.rules`, which lets the
  enrolled user (validated name) suspend and power off without a password; that is what a
  logged-in desktop user can already do locally. Wake-on-WLAN is enabled only on the WiFi
  connection of the machine's trusted LAN. `dm power` offers suspend or power off only when
  another online machine shares that LAN, so the machine can be woken again; `off` asks you
  to type the machine's name.

## Doors into phones (`dm door`)

Phones and tablets are clients: nothing listens on them. `dm door open` changes that for a
limited time and only for your machines:

- The sshd runs inside Termux, so Android's sandbox applies: it reaches Termux's own files and
  the shared storage the user granted (photos, Download, documents), never other apps' data.
- It listens only on the device's mesh address (port 8022). With the WireGuard tunnel off it
  cannot bind and does not start.
- `authorized_keys` holds only the client keys of machines whose host key and client key an
  approver signed, verified on the device from the signed bundle, each with
  `from="<machine mesh IP>",restrict`. The hub cannot add a key; a forged or reused signature is
  dropped. Pending devices, phones and tablets never get in.
- The door's host key is the device's own approver-signed client key. Machines pin it under the
  alias `devmesh-door-<device>` from the verified bundle, so there is no trust on first use.
- A timer closes it (1 minute to 4 hours, by the clock, started before sshd); `dm door close`
  closes it at once and ends every session it started. Closing removes the keys and config, and
  only signals processes whose command line is still the door's.
- A machine that enters gets a shell as the Termux user (rsync needs one). While the door is
  open it can read and change that shared storage and copy the device's own client key (it
  could then act as that device). The door therefore refuses to open on an approver device.
  Open it only while an agent works on it.

## Trust dependencies

OpenSSH (signatures, sshd), WireGuard, nginx, ntfy, curl, tmux (for `dm go`); in domain mode, Let's Encrypt; for backups, age. A flaw in any of these is outside what the signatures cover.
