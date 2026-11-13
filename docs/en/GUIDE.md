# devmesh: user guide

**A private network, device trust and power for your machines.**
devmesh joins your dev machines, your Mac, your tablet and your phone in one private
network. From any of them you reach the others, wake them, send files and decide which
devices are trusted, also when you are away from home. [Herdr](https://herdr.dev) runs the
terminals and agents on top.

Spanish version: [../es/GUIA.md](../es/GUIA.md). Install summary: [../../README.md](../../README.md).

---

## How it works, in 30 seconds

| Piece | What it is | Examples |
|---|---|---|
| **Hub** | The control point. Coordinates the private network, takes registrations and alerts you when something goes down | `hub.example.com` or `203.0.113.10` |
| **Machine** | A computer where you work. You reach it from anywhere, and Herdr runs your terminals and agents on it | Your always-on laptop, other PCs |
| **Control** | A device you manage the machines from | Your Mac |
| **Mobile** | An Android tablet or phone with Termux | Your tablet, your phone |

Every device has up to three paths to the machines:
- **Path L (same local network):** direct, not through the hub. Only on the networks you
  trusted on that machine (see "Direct on your LAN").
- **Path A (WireGuard VPN):** through the hub.
- **Path B (tunnel through the hub):** used only when the VPN is not available.

You do not choose: `dm` uses whichever works.

---

## 1. Install the hub

You need a small server with a public address: Ubuntu 20.04+ or Debian 11+ (or any Linux
with Docker), 1 vCPU and 512 MB. Open **UDP 51820** and **TCP 2222**, plus **TCP 443**
(domain mode) or **TCP 8443** (IP mode). With a domain, port 80 must also be reachable for
the Let's Encrypt challenge.

### Guided installer

```bash
curl -fsSL https://raw.githubusercontent.com/chsotelo/devmesh/main/install.sh | sudo bash
```

It finds the latest release, checks it against `SHA256SUMS` and asks for:
1. **Domain or IP** of the server (it suggests the detected public IP).
2. **Email**, only for a domain (Let's Encrypt).
3. **Backup public key** (`age1…`), or empty to skip off-site backups.

To skip the questions, set `HUB_HOST` (and `ACME_EMAIL` for a domain) in the environment.

### Domain mode and IP mode

| | Domain mode | IP mode |
|---|---|---|
| `HUB_HOST` | `hub.example.com` | `203.0.113.10` |
| Certificate | Let's Encrypt | self-signed |
| Web port | 443 | 8443 |
| Join line | `curl -fsSL https://hub.example.com/j/<code> \| sh -s <secret>` | `curl -fsSL --pinnedpubkey 'sha256//…' -k https://203.0.113.10:8443/j/<code> \| sh -s <secret>` |

In IP mode there is no certificate authority to vouch for the hub, so `-k` turns off CA
validation and `--pinnedpubkey` ties the connection to the hub's own certificate. curl
still enforces the pin.

### From a checkout, over SSH

```bash
make hub HOST=root@203.0.113.10 HUB_HOST=hub.example.com ACME_EMAIL=you@example.com
```

It is idempotent: run it again to update an existing hub. Add `BACKUP_RECIPIENT=age1…` to
enable the encrypted backup, and `SSH="ssh -i ~/.ssh/id_ed25519"` to choose a key.
To avoid typing them, copy `deploy.local.mk.example` to `deploy.local.mk` (ignored by git)
and run plain `make hub`. Deploy a release (`git checkout vX.Y.Z`), not a work in progress.

### With Docker

```bash
HUB_HOST=203.0.113.10 docker compose -f docker/hub/compose.yml up -d --build
docker compose -f docker/hub/compose.yml exec hub devmesh invite lap
```

The container uses host networking. fail2ban and the `net.ipv4.ip_forward` sysctl belong to
the host. Details and limits: [../../docker/hub/README.md](../../docker/hub/README.md).

### The first device

On the hub, as root:

```bash
devmesh invite mac
```

Paste the `JOIN:` line it prints on the device (next section). Later devices are added from
any joined device with `dm add`.

---

## 2. Add any device: one name, one line

**On a joined device:**

```bash
dm add tablet
```

It asks nothing else. For a **Linux machine** you can add two options: `--lan home` (to wake
it remotely) and `--watch-hub` (it alerts you if the hub goes down):

```bash
dm add lap --lan home --watch-hub
```

You get three things:
1. **The join line**, already **copied to your clipboard**:
   ```
   JOIN: curl -fsSL https://hub.example.com/j/K7Q2M9XW4TPA | sh -s 4TPAZ85XR6QX
   ```
2. **A QR code** with the same line, to scan with a phone.
3. With `--watch-hub`, the ntfy.sh topic for those alerts.

**On the new device**, whatever it is, paste the line and press Enter:

| Device | Where to paste it | What happens |
|---|---|---|
| **Linux** (laptop, PC) | In a terminal, as your normal user | Asks for your `sudo` password and becomes a **machine**: its terminals are visible from anywhere and a `main` terminal always exists |
| **Mac** | In Terminal | No `sudo`. Becomes a **control** device. For the VPN, import `~/.config/devmesh/wireguard/devmesh.conf` in the WireGuard app |
| **Android** (Termux) | In Termux. From the QR: scan it, copy the text and paste it | Asks you to import `Download/devmesh-<name>.conf` in the WireGuard app and press Enter. The file deletes itself |

The device **detects by itself** what it is. You choose nothing.

> The line works **once** and expires after **15 minutes**. Its second part is a secret that
> never reaches the server or any log. If you make a mistake, `dm rm` cancels the invitation
> and makes the line useless at once.

**Before adding an Android device:** install **Termux** from **F-Droid** (not the Play
Store) and the **WireGuard** app. Then, so Android does not kill your sessions:
- *Settings → Developer options →* **Disable child process restrictions**
- *Battery → Termux →* **Unrestricted**

On a Mac, `dm` needs bash 4+ and Homebrew (`brew install bash`); it re-runs itself under
Homebrew's bash if it finds it.

---

## 3. Herdr on top

devmesh is the network. [Herdr](https://herdr.dev) (desktop and mobile apps) runs the
terminals and agents on your machines. devmesh does not install Herdr: it is optional, and
what needs `herdr-core` on a machine says so when it is missing.

A typical use: keep a powerful PC asleep, and from the laptop type

```bash
dm use pc claude
```

devmesh wakes `pc` with Wake-on-LAN if it is asleep, waits for it, and starts `claude` in a
Herdr terminal there. Then you watch and drive it in Herdr, on the desktop or on the phone.

### `dm use`: run something on a machine

```bash
dm use <machine> [--cwd DIR] [--attach] [-- command...]
```

- Runs the command in a Herdr terminal on that machine, through its `herdr-core`. With no
  command it starts a shell.
- If the machine is asleep it is woken first and `dm use` waits up to 180 s for it
  (`DM_USE_WAIT=<seconds>` changes it).
- `--cwd DIR` sets the folder. `--attach` attaches the terminal right here instead of only
  starting it.
- It needs `herdr-core` on the target. If it is missing, `dm use` says so and installs nothing.

### `dm power`: see and change a machine's power

```bash
dm power <machine> [status|wake|suspend|off]
```

- `status` (the default) shows whether the machine is on or off and what can be done.
- `suspend` and `off` are allowed only when another online machine on its trusted LAN can
  wake it again. `off` asks you to type the machine's name. The machine you are on never
  powers itself off.
- `wake` sends Wake-on-LAN through another machine on the same LAN, like `dm wake`.

### Herdr mobile app

Use only the official app from [herdr.dev/mobile](https://herdr.dev/mobile) (Google Play id
`dev.herdr.app`). Third-party "Herdr Mobile" apps that ask you to install a
`herdr-mobile-bridge` talk to the Herdr TUI, not to `herdr-core`, and see nothing.

1. **The phone or tablet is in the mesh with WireGuard on.** It is the WireGuard app tunnel you
   imported when you joined the device.
2. **Add each machine in the app** by its mesh IP (`10.73.0.x`, see `dm devices`), port `22` and
   the machine's user.
3. **Choose "Add the key yourself".** The app shows a key (or a whole line that adds it). On a
   joined device run:
   ```bash
   dm herdr allow phone '<what the app shows>'
   ```
   You can paste the whole line. devmesh finds the public key in it and adds it to
   `~/.ssh/authorized_keys` on every machine. The entry is tagged `devmesh-herdr:phone`,
   works only from the phone's mesh IP (`from="<mesh IP>"`) and allows no forwarding.
   Machines that are offline are reported: run the same command again when they are back,
   it is safe to repeat.
4. **Each machine needs `herdr-core`.** It comes with the Herdr desktop app, or install it.
5. **macOS machines need Remote Login.** devmesh's own sshd on a Mac listens only on
   `127.0.0.1`, so the app cannot use it. Turn on System Settings > General > Sharing >
   Remote Login, allow only your user, and turn off "full disk access for remote users".
   Make the macOS sshd keys-only. Linux machines need nothing: sshd already listens on the
   mesh IP.

```bash
dm herdr ls                    # the keys, per machine
dm herdr revoke phone          # remove the keys of that device
```

`dm rm <device>` also revokes that device's Herdr keys on every machine that is online.

### `dm go`: a plain terminal

```bash
dm go                  # pick a machine, enter its terminal "main"
dm go mac api          # machine "mac", terminal "api"
```

It opens a tmux terminal on the machine, over path A, falling back to B. Use it when Herdr is
not reachable, for example from Termux or on a network that only allows path B. Inside it:

| Shortcut | What it does |
|---|---|
| `Ctrl+b` `s` | List and jump between sessions and tabs |
| `Ctrl+b` `c` | New tab |
| `Ctrl+b` `,` | Rename the tab |
| `Ctrl+b` `%` · `Ctrl+b` `"` | Split the screen |
| `Ctrl+b` `d` | **Leave without closing anything**: everything keeps running |

### Language

Messages are in **English** by default. For Spanish set `DM_LANG=es` (for example
`DM_LANG=es dm help`), or use a Spanish locale (`LANG=es_PE.UTF-8`). Anything missing from a
translation shows in English.

### Commands

`dm` with no arguments prints this list (`dm help`).

| You want to… | Type |
|---|---|
| Run something on a machine (wakes it) | `dm use <machine> [--cwd DIR] [--attach] [-- command...]` |
| See or change a machine's power | `dm power <machine> [status\|wake\|suspend\|off]` |
| Let the Herdr app in | `dm herdr allow <device> <key>` · `dm herdr revoke <device>` · `dm herdr ls` |
| Plain terminal | `dm go [machine] [name]` |
| Send / fetch files | `dm send` · `dm fetch` |
| See a machine's web app | `dm port` (stop with `dm port stop`) |
| See / change what a machine exposes on the mesh | `dm mesh` |
| Devices · add · remove | `dm devices` · `dm add <name>` · `dm rm` |
| Approve a device · signed trust | `dm approve` · `dm trust init\|pin\|status` |
| Wake a machine | `dm wake <machine>` |
| Pull the device list | `dm refresh` |
| Update `dm` | `dm update` |
| Follow a moved hub | `dm repoint <ip-or-host>` |
| Phone push when Claude needs you | `dm notify on\|off\|status` |
| Help | `dm help` |

The shell integration adds one alias, `m='dm go'`.

---

### Mesh firewall

Linux machines only answer the other devices on the mesh for **SSH, mosh and ping**. A dev
server or a database listening on `0.0.0.0` is not reachable from the other devices, nor from
the hub. To open a port on purpose (root needed):

```bash
sudo devmesh-node mesh open tcp/8000        # also tcp/8000-8010 or udp/5353
sudo devmesh-node mesh close tcp/8000
devmesh-node mesh status                    # or just: dm mesh
```

`dm mesh` needs no root: it shows what is open and prints the exact `sudo` command to change
it. Machines enrolled before this existed get the firewall with `dm update`.

### Direct on your LAN

When your Mac, your tablet and a machine share a network (home, office), `dm` connects straight
to the machine instead of going around through the hub: latency drops from the VPS's to your
WiFi's. It is enabled per network, on each machine, while it is on that network (root needed):

```bash
sudo devmesh-node lan trust       # trust the network it is on now (subnet + router)
sudo devmesh-node lan forget      # stop trusting every network
devmesh-node lan status           # is it direct right now?
```

A network is recognised by its subnet **and** its router: a cafe with the same subnet has
another router and does not count. Off your trusted networks SSH does not even listen on the
local network (on a public WiFi nobody sees it). The host key is the same as through the hub,
so a changed address or another machine is refused and `dm` uses the hub. Devices learn the
address by themselves, from the machine, and ask again every 30 minutes; the machine checks
which network it is on every minute.

For web servers and databases prefer `dm port`: it travels inside SSH, so nothing is opened
and nothing crosses the mesh in the clear. The hub cannot read your SSH sessions, but it can
read any unencrypted service that you open and that crosses the mesh through it (the mesh is a
star). macOS and Android/Termux have no mesh firewall: macOS listens for SSH only on
`127.0.0.1`, and phones normally offer no services.

On the hub the same idea protects the VPS itself: from the mesh only SSH on 2222 and ping get
in, and containers published by Docker cannot be reached through the mesh address.

## 4. Phone alerts

Install the **ntfy** app and subscribe to:
- **Server:** `https://hub.example.com` (in IP mode, `https://203.0.113.10:8443`)
- **Topic:** `devmesh`
- **User:** `devmesh-sub`. The password is on the hub in `/etc/devmesh/ntfy-subscriber.txt`
  and only root can read it.

You get a notice when a machine goes down and when it comes back (once it stays up for 5
minutes, so a sleeping Mac that wakes for seconds now and then is not reported each time). If you used
`--watch-hub` when adding the laptop, that `dm add` gave you an **ntfy.sh** topic. Subscribe
to it to learn when the hub itself goes down.

**Claude needs you.** On each machine where you use Claude Code, run `dm notify on` once.
When a session asks for permission, or has been waiting for your answer for a minute, and
you have not touched that machine (keyboard, mouse or a terminal attached from another
device) for 2 minutes, the same app shows "Claude on <machine>: <project>" (the same message at most once every
10 minutes). It adds a `Notification` hook to
`~/.claude/settings.json` next to your own hooks; `dm notify off` removes only that hook.

---

## Approving devices

With approvers, a compromised hub cannot add access, impersonate a machine or ship code: devices only trust keys that one of *your* devices signed.

- **First approver (owner).** On the hub: `devmesh invite <name> --owner` (only while the hub has none). The device that joins with that line trusts its own key.
- **A new device joins** and waits as `pending` (`dm devices`). At the end of its join it prints its fingerprints: `Approve on an approver device: dm approve <name> (check: client SHA256:..., host SHA256:...)`.
- **Approve** on an approver device: `dm approve` lists what waits; `dm approve <name>` asks for the check. The fingerprints are not shown: read them on the new device (printed at the end of its join, or `dm trust status` there) and type the last 16 characters of the host fingerprint (machines) or client fingerprint (phones, Macs). `--signer` also makes it an approver. (`--yes` is for tests only, `DM_TEST=1`.)
- **Remove.** `dm rm` on an approver device also signs a revocation: devices drop that key and never accept an old approval of it again.
- **Existing install (0.7).** On the hub: `devmesh owner <device>`. On that device: `dm trust pin`, then `dm trust init` (asks per device for the last 16 characters of its fingerprint; `--i-checked-all` skips it: dangerous). On each machine: `dm trust pin` (prints the `sudo` lines it needs). `dm trust pin --reset` replaces the approvers (type the end of the owner fingerprint, read with `dm trust status` on the owner). `dm trust status` shows the mode, approvers and what waits.
- In signed mode a device with a missing `allowed_signers` refuses to sync, refresh or update instead of falling back.
- Known limit: trust starts from the join line and from the fingerprints you compare, so do that check on a device you hold.

## 5. If you lose a device

On any other device:

```bash
dm rm
```

Choose the device and type its name to confirm. At that moment it loses the VPN, the tunnel
and access to the hub, and within a minute all your machines stop accepting its key.

---

## 6. Maintenance (only when needed)

| Task | How |
|---|---|
| Update `dm` on a device | `dm update` |
| Update the hub | from the repo: `make hub HOST=root@203.0.113.10 HUB_HOST=hub.example.com` |
| Check hub state | on the hub, `devmesh ls` and `devmesh check` |
| Download the latest hub backup | `make backup-pull` (stays encrypted in `backups/`) |
| Move the hub to another VPS | `make restore HOST=root@<new-ip> BACKUP=backups/<file> HUB_HOST=<host>` |

> **Important:** the backups are encrypted with an `age` public key, and you need the matching
> private key to open them (`make restore` reads it from `~/.config/devmesh/backup.agekey`,
> or set `AGE_IDENTITY=`). **Copy that file to a second safe place.** Without it the backups
> cannot be opened.

### Moving the hub

- **Domain mode:** after `make restore`, point `hub.example.com` at the new IP. Your devices
  follow by themselves.
- **IP mode:** the address changes, so the devices still point at the old one. On each
  device run once:
  ```bash
  dm repoint 198.51.100.7
  ```
  `dm repoint` rewrites the hub address, the WireGuard endpoint and the ssh config, and
  **refuses to continue unless the new address presents the same SSH host key** this device
  already pinned for the hub. The restore keeps the hub's host key, so a genuine move passes.

---

## 7. Common problems

| Symptom | What to do |
|---|---|
| `dm` says a machine is OFFLINE | Check that it is on. If it has network but does not answer, try `dm wake <machine>` from another machine on its LAN |
| The VPN does not connect at a hotel or office | Do nothing: `dm` uses path B automatically |
| The tablet "disconnects" | Android is closing Termux. Open your session again: what was running on the machine is intact (in Herdr, or in tmux with `dm go`) |
| `dm` says "not enrolled" | That device is not registered: `dm add <name>` from another device and paste the line here |
| The line says "missing secret" | It was copied incompletely: it must end in `sh -s` plus 12 characters |
| The line gives 404 | It expired (15 min), was already used or was cancelled: make another with `dm add` |
| An IP-mode hub moved and devices cannot reach it | `dm repoint <new-ip>` on each device |
| Installer says the OS is not supported | Use Docker: `HUB_HOST=… docker compose -f docker/hub/compose.yml up -d --build` |
| `dm use` says herdr-core is not on the machine | Herdr is optional. Install `herdr-core` there (it comes with the Herdr desktop app) |
| The Herdr app on the phone sees no machines | WireGuard must be on in the phone, the machine added by its mesh IP, and the key passed with `dm herdr allow`. On a Mac, turn on Remote Login |
