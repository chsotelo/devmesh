# devmesh

![ci](https://github.com/chsotelo/devmesh/actions/workflows/ci.yml/badge.svg)

devmesh is a private network, device trust and power control for your machines: a WireGuard
network with a reverse-SSH fallback, joined with one line on Linux, macOS or Android
(Termux). No accounts and no third-party cloud: the hub is a small server you own.

It does not run your terminals or agents. [Herdr](https://herdr.dev) does that, on top:
devmesh reaches your machines, wakes them, and decides which devices are trusted.

## How it works

```
  devices                       hub (your VPS)                machines
  Mac · tablet · phone                                        Linux · macOS
  ┌──────────────┐   A: WireGuard (udp/51820)   ┌─────────┐   ┌─────────────┐
  │     dm       │ ═══════════════════════════> │         │ ══> │ Herdr · ssh  │
  │  Herdr app   │                              │   hub   │   └─────────────┘
  │              │   B: ssh (tcp/2222) ───────> │         │ <── reverse tunnel
  └──────────────┘      via the hub             └─────────┘     opened by each machine
```

- **Path L, same LAN:** on a network the machine trusts (`sudo devmesh-node lan trust`),
  devices on it connect straight to the machine, without the hub.
- **Path A, WireGuard:** devices reach machines over the private network, through the hub.
- **Path B, reverse SSH:** each machine keeps a tunnel open to the hub. When UDP is
  blocked, `dm` goes through the hub over SSH. It tries A first and falls back to B by itself.
- Herdr, `dm use` and `dm go` all travel over these paths.

## Requirements

| Piece | Needs |
|---|---|
| Hub | Ubuntu 20.04+ or Debian 11+ (native install), or any Linux with Docker. 1 vCPU, 512 MB. UDP 51820 and TCP 2222 open, plus TCP 443 (domain mode) or TCP 8443 (IP mode). A domain also needs port 80 for the Let's Encrypt challenge |
| Machines | Linux with systemd, or macOS 13+ with Homebrew |
| Phone / tablet | Android with Termux from F-Droid |
| Herdr (optional) | `herdr-core` on each machine you drive with `dm use` or the Herdr app. devmesh never installs it. `dm go` needs tmux instead |

## Install the hub

Guided installer (Ubuntu/Debian, as root). It resolves the latest release, verifies it
against `SHA256SUMS`, asks for a domain or an IP, an email (domain only, for Let's Encrypt)
and an optional [age](https://age-encryption.org) public key for encrypted backups:

```sh
curl -fsSL https://raw.githubusercontent.com/chsotelo/devmesh/main/install.sh | sudo bash
```

Non-interactive: set `HUB_HOST` (and `ACME_EMAIL` for a domain, `BACKUP_RECIPIENT` optional).

- **Domain mode** (`hub.example.com`): Let's Encrypt certificate on 443.
- **IP mode** (`203.0.113.10`): self-signed certificate on its own port, 8443. The join
  line carries the certificate pin (`--pinnedpubkey 'sha256//…' -k`), so it is still verified.

From a checkout, over SSH (idempotent; also re-applies an existing hub):

```sh
make hub HOST=root@203.0.113.10 HUB_HOST=hub.example.com ACME_EMAIL=you@example.com
```

With Docker (host networking; see [docker/hub/README.md](docker/hub/README.md) for limits,
such as fail2ban and `ip_forward` living on the host):

```sh
HUB_HOST=203.0.113.10 docker compose -f docker/hub/compose.yml up -d --build
```

Backups and moving the hub: `make backup-pull` fetches the latest encrypted backup;
`make restore HOST=root@<new-ip> BACKUP=backups/<file>.tar.gz.age HUB_HOST=<host>` rebuilds
on a new VPS. In IP mode, run `dm repoint <new-ip>` once on each device afterwards.

## Join a device

On a device that is already joined (the first one: on the hub, `devmesh invite <name>`):

```sh
dm add tablet          # prints and copies one JOIN line, plus a QR code
```

Paste the `JOIN:` line on the new device. It works for Linux, macOS and Termux, is valid
once and expires after 15 minutes. Linux machines ask for `sudo`; Termux asks you to
import a WireGuard config into the WireGuard app.

## Herdr on top

devmesh gets you to the machine; [Herdr](https://herdr.dev) (desktop and mobile apps) runs the
terminals and agents there. A typical use: keep a powerful PC asleep and start work on it from
the laptop.

```sh
dm use pc claude       # wakes pc if it is asleep, starts claude in a Herdr terminal on it
```

Then watch and drive it in Herdr, on the desktop or on the phone. `dm use` needs `herdr-core` on
the machine; if it is missing, devmesh says so and installs nothing.

- `dm use <machine> [--cwd DIR] [--attach] [-- command...]`: runs a command (default: a shell)
  in a Herdr terminal on that machine. If the machine is asleep it sends Wake-on-LAN and waits
  up to 180 s (`DM_USE_WAIT`). `--attach` attaches the terminal right here.
- `dm power <machine> [status|wake|suspend|off]`: `status` shows on or off and what can be done.
  `suspend` and `off` are offered only when another machine on its LAN can wake it again;
  `off` asks you to type the machine's name.
- `dm herdr allow <device> <ssh-public-key>`: lets the Herdr mobile app on that device sign in
  to every machine. See below.
- `dm go [machine] [name]`: a plain tmux terminal. Use it when Herdr is not reachable, for
  example from Termux or on a network that only allows path B.

### Herdr mobile app

Use only the official app from [herdr.dev/mobile](https://herdr.dev/mobile) (Google Play id
`dev.herdr.app`). Third-party "Herdr Mobile" apps that ask to install a `herdr-mobile-bridge`
talk to the Herdr TUI, not to `herdr-core`, and see nothing.

1. The phone or tablet must be in the mesh with WireGuard on (the tunnel imported in the
   WireGuard app when you joined it).
2. In the app, add each machine by its mesh IP (`10.73.0.x`), port 22 and the machine's user.
3. Choose "Add the key yourself". On a joined device run, with the line the app shows:
   ```sh
   dm herdr allow phone '<line from the app>'
   ```
   You can paste the whole line. The key goes to every machine's `~/.ssh/authorized_keys`,
   tagged `devmesh-herdr:phone`, usable only from the phone's mesh IP and with no forwarding.
   Machines that are offline are reported; run it again later, it is safe to repeat.
4. Each machine needs `herdr-core` (it comes with the Herdr desktop app, or install it).
5. macOS machines: devmesh's own sshd listens on localhost only, so the app needs macOS
   Remote Login (System Settings > General > Sharing > Remote Login). Allow only your user,
   turn off full disk access for remote users, and make the macOS sshd keys-only.

`dm herdr ls` lists the keys; `dm herdr revoke <device>` removes them. `dm rm <device>` also
revokes that device's Herdr keys on the machines that are online.

## Commands

| Command | What it does |
|---|---|
| `dm use <machine> [--cwd DIR] [--attach] [-- command...]` | run a command in a Herdr terminal on a machine, waking it first |
| `dm power <machine> [status\|wake\|suspend\|off]` | power state; suspend and off only when it can be woken again |
| `dm herdr allow <device> <key>` / `revoke <device>` / `ls` | Herdr mobile app keys on every machine |
| `dm go [machine] [name]` | plain tmux terminal (default `main`); fallback when Herdr is not reachable |
| `dm send [file]` / `dm fetch` | send a file to a machine / bring one back |
| `dm port [stop]` | preview a machine's dev server at `http://localhost:<port>` |
| `dm mesh` | what this Linux machine exposes on the mesh (only SSH, mosh and ping by default) |
| `dm add <name> [--lan L] [--watch-hub]` | join line for a new device |
| `dm devices` / `dm rm` | list / revoke devices |
| `dm approve` / `dm trust` | approve devices / signed trust (see the guide) |
| `dm wake [machine]` | Wake-on-LAN through a machine on the same LAN |
| `dm refresh` / `dm update` | pull device list and ssh config / update the client |
| `dm repoint <ip\|host>` | follow the hub to a new address (checks its host key) |
| `dm notify on\|off\|status` | machines: a phone push (ntfy) when Claude Code asks for permission or waits for you |

`dm` with no arguments prints help. Hub side (as root): `devmesh invite|remove|ls|check|gc|backup|restore|apply|dist`.

## How it compares

| | devmesh | Tailscale + tmux | Headscale / NetBird | Claude Code Remote Control | Moshi / Termius |
|---|---|---|---|---|---|
| What it is | hub + client scripts: network, trust, power | managed VPN you pair with your own tmux | self-hosted VPN control servers | official feature to drive a Claude Code session remotely | SSH/mosh terminal apps |
| Self-hosted | yes, all of it | coordination is a vendor service | yes | no (Anthropic service) | the app is not; your SSH servers are |
| Network layer | WireGuard + SSH fallback | WireGuard (with relays) | WireGuard-based | not a network | your own network or VPN |
| Terminals and agents | Herdr on top; `dm go` as a plain fallback | you assemble them | not their scope | one session per instance, ends when the terminal closes | per-host sessions |
| Send/fetch files, wake, power | built in | you assemble them | not their scope | no | no |
| Phone client | Herdr mobile app; Termux (Android) | native apps | native apps | Claude apps | native apps (iOS/Android) |
| Maturity | young, small | established | established | official | established |

Pick the VPN products if you only need the network. devmesh covers the network, device trust and
power, with Herdr on top for the terminals, at the cost of running a hub.

## Security model

With approvers, the hub is not trusted for access: authorized SSH keys, machine host keys and
client updates (`dm update`) are only accepted when an approver (one of your own devices)
signed them, and revocations are signed too. A compromised hub can cut the service and see
metadata, but cannot add a key, impersonate a machine or ship code, as long as devices run in
signed mode and joined before the compromise. Join lines are single-use, expire in 15 minutes,
and their second part is a secret that never reaches the server. Full threat model, residual
risks and exposed ports: [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md). To report a
vulnerability, see [SECURITY.md](SECURITY.md).

## Develop

```sh
brew install bash bats-core shellcheck shfmt age   # macOS
make check             # shellcheck + shfmt + bats (stubs)
make integration       # real hub and machines in Docker (needs Docker, internet)
```

## More

User guide: [English](docs/en/GUIDE.md) · [Español](docs/es/GUIA.md) · Background:
[docs/history/DESIGN.md](docs/history/DESIGN.md) · [CONTRIBUTING.md](CONTRIBUTING.md) ·
[CHANGELOG.md](CHANGELOG.md)

## License

MIT, see [LICENSE](LICENSE).
