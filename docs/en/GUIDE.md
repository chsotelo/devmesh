# devmesh: user guide

**All your terminals, on all your machines, from anywhere.**
devmesh joins your dev machines, your Mac, your tablet and your phone in one private
network. From any of them you see the terminals open on the others, enter the one you
want, create new ones and move files, also when you are away from home.

Spanish version: [../es/GUIA.md](../es/GUIA.md). Install summary: [../../README.md](../../README.md).

---

## How it works, in 30 seconds

| Piece | What it is | Examples |
|---|---|---|
| **Hub** | The control point. Coordinates the private network, takes registrations and alerts you when something goes down | `hub.example.com` or `203.0.113.10` |
| **Machine** | A computer where you work. Its terminals live in tmux and can be seen from anywhere | Your always-on laptop, other PCs |
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

## 3. Day to day: one workspace

On any device type:

```bash
dm
```

It looks like the terminal panel of VS Code: **a tab per machine on top, the list of that
machine's terminals on the left, the real terminal on the right**.

```
 devmesh │ ● laptop  desktop  ○ builder                   + │ 🗑 │ ✕   <- machines (tabs) and buttons
▎ >_ api              ● │ $ claude
  >_ web                │   I updated the auth middleware…
  >_ docs             ● │   Edit src/auth.ts?   (the selected terminal, live)
```

- **Top bar = machine selector.** The active tab is bright with the machine's color; the others
  are gray; a machine that is off shows `○`. Tap or click a tab to switch machine.
- **Left = the machine's terminals**, one row each, with a dot for the agent in it (yellow
  waiting, blue working, green idle). Tap a row (or `enter`) to show it on the right; arrows or
  `j`/`k` move; the list refreshes every 3 seconds.
- **Buttons (top right):** `+` new terminal (type a name), `🗑` delete the terminal on screen
  (asks first), `✕` leave: everything keeps running and the next `dm` brings you back to the
  same place. Keys: `Ctrl+a +`, `Ctrl+a x`, `Ctrl+a d`.
- **Phone:** under 70 columns the list is hidden and the terminal fills the screen; `☰` (or
  `Ctrl+a s`) swaps to the list and back, and choosing a row returns to the terminal.
- **If the connection drops, the terminal reconnects by itself.**
- Needs tmux 3.2 or newer and the `dm-tui` binary. Without them, or with `DM_UI=cards` /
  `DM_UI=fzf`, `dm` uses the card panel / the fzf panel described below.

### The card panel (`DM_UI=cards`)

The panel is made for touch (a phone or a portrait tablet in Termux) and also works with a
keyboard and a mouse:

```
 ‹ back  devmesh 0.8.1 › laptop              [new] [↻] [send] [web] [fetch]  <- buttons: tap them
 ● laptop  3 terminals                                           [new]
╭─────────────────────────────────╮ ╭────────────────────────────────╮
│ api                   ● waiting │ │ web                            │  <- one card per terminal:
│ claude · tablet             40s │ │ node · laptop               5m │     name, state, command,
│ ── tablet ───────────────────── │ │ ────────────────────────────── │     origin, last activity,
│ I updated the auth middleware … │ │ $ npm run dev                  │     clients and a live
│ Edit src/auth.ts?               │ │ VITE v6 ready in 312 ms        │     thumbnail of its screen
╰─────────────────────────────────╯ ╰────────────────────────────────╯
 ○ desktop  offline                                             [wake]
                     enter open  n new  / filter  ? shortcuts  q quit
 tablet · 3 machines · 3 terminals · 1 waiting                          <- status + shortcuts
```

- **Cards, not a list:** each machine is a section and each terminal a card. The grid has one
  column on a phone, two on a portrait tablet and more on a wide screen. The thumbnail shows
  as many lines as fit.
- **Detail:** on a narrow screen `enter` (or tapping a selected card) opens the terminal's
  detail: a big live view with `[open]`, `[send file]` and `[web]`; `esc` goes back. From 140
  columns the detail is a pane next to the cards and `enter` opens the terminal directly.
- **Offline machines** are dimmed with their `[wake]` button (Wake-on-LAN through another
  machine on the same network). A machine with no terminals says so and offers `[new]`.
- **It refreshes by itself:** the machines every 4 seconds, the thumbnails of the cards in
  view every 3 seconds. A slow or dead machine never blocks the panel.
- **Touch:** tap a card to select it and tap again to open it; the buttons on top and the
  ones on each machine are tappable; the wheel scrolls.
- **New terminal:** `n` (or `[new]`). Pick the machine (skipped when you only have one), then a
  project, or **type a name** in the box at the bottom: typing filters the projects and
  offers `+ New terminal "<name>"`. It opens as a new tab and the panel stays.
- **Add a device:** `a`, type its name (for example `lap`) and press enter. The single-use
  line and the QR code appear. With no machines yet, the first screen explains this and
  offers `[add device]`.
- **Filter:** `/` and type; `esc` clears the filter, and `esc` on the home screen quits.

| Key | Action |
|---|---|
| arrows · `h j k l` | Move between cards and machines |
| `enter` | Open the terminal or its detail; open a machine's menu; wake an offline machine |
| `o` | Open the selected terminal |
| `n` | New terminal (on a machine screen, on that machine) |
| `s` · `f` | Send a file · fetch a file |
| `w` | Preview a machine's dev server here |
| `d` · `a` | List devices · add a device |
| `r` | Refresh |
| `/` | Filter the terminals |
| `esc` | Back (on the home screen: clear the filter, then quit) |
| `?` | Show all shortcuts |
| `q` · `ctrl+c` | Quit the panel |

The panel is the `dm-tui` program that comes with the client. It only draws: everything
that touches a machine is done by `dm`, as before. Where there is no `dm-tui` for your
system, or with `DM_TUI=0 dm`, the classic fzf panel is used instead (with an fzf older than
0.66, a one-menu-at-a-time version). If tmux is missing, the panel runs without tabs.

### Claude sessions

The list on the left shows that machine's **Claude Code sessions** by the name you gave them
(`claude --name "19Oct - redi general"`) and one word of state: `working`, `waiting`, or how
long they have been idle (`20 min`, `5 h`, `3 d`). Tap one and it opens on the right: type
there as usual. devmesh reads the session registry Claude Code keeps itself; nothing to
install.

- **Stop:** select a session and tap `Stop`. It ends and frees its memory, and stays in
  `History ›`. When sessions have been idle for over 1 h, one line offers to stop them all.
- **On their own after 2 h:** sessions running in devmesh that sit idle for 2 h stop by
  themselves, checked every 5 minutes (`DM_CLAUDE_AUTOSTOP_MIN=0` turns it off). Their terminal
  stays open, asleep, showing the session; Enter resumes it right there with the whole
  conversation. Sessions not running inside tmux are never touched.
- **Closed by hand:** when Claude ends in a devmesh terminal (`/exit`, Ctrl+C), the
  `claude --resume …` line it prints is already typed at the next prompt: Enter resumes,
  Ctrl+C drops it.
- **History ›:** named, stopped sessions from the last 30 days, with a search box.
  `Resume` reopens one where it left off, with the whole conversation.
- **＋ New:** a name (prefilled with the date, `27Oct - `) and a project folder; it starts
  `claude --name` there.
- **Move to <machine>:** stops the session here and resumes it on the other machine with
  the whole conversation; from then on that machine provides the memory, CPU and runs the
  commands (you keep seeing and typing from wherever you are). The other machine needs
  Claude installed and the same project under `~/PROJECTS` at the same commit: with
  uncommitted changes or different commits it tells you what to do instead of moving.
- **Terminals ›:** your usual terminals.
- **`⏻` suspend, power off, wake:** only what can be undone from here is offered. A machine
  is suspended or powered off only when another online machine shares its trusted network
  and Wake-on-WLAN is on, so it can be woken again. Power off asks twice and only the power
  button turns it back on. The machine you are on never powers itself off.

### Language

The panel and the device setup messages are in **English** by default. For Spanish set
`DM_LANG=es` (for example `DM_LANG=es dm`), or use a Spanish locale (`LANG=es_PE.UTF-8`).
Anything missing from a translation shows in English.

### Commands, if you prefer them

| You want to… | Type |
|---|---|
| Open the workspace | `dm` |
| New terminal (guided) | `dm new`, or straight on a machine: `dm new mac` |
| Enter directly | `dm go mac api` |
| See every terminal | `dm list` · `dm who` (table with agent state and clients) |
| Close a terminal | `dm close` |
| Send / fetch files | `dm send` · `dm fetch` |
| See a machine's web app | `dm port` (stop with `dm port stop`) |
| See / change what a machine exposes on the mesh | `dm mesh` |
| Devices · add · remove | `dm devices` · `dm add <name>` · `dm rm` |
| Wake a machine | `dm wake <machine>` |
| Pull the device list | `dm refresh` |
| Update `dm` | `dm update` |
| Follow a moved hub | `dm repoint <ip-or-host>` |
| Report the agent state (hooks) | `dm agent working\|waiting\|idle\|clear` |
| Help | `dm help` |

### Inside a terminal (tmux)

| Shortcut | What it does |
|---|---|
| `Ctrl+b` `s` | List and jump between sessions and tabs |
| `Ctrl+b` `c` | New tab |
| `Ctrl+b` `,` | Rename the tab |
| `Ctrl+b` `%` · `Ctrl+b` `"` | Split the screen |
| `Ctrl+b` `d` | **Leave without closing anything**: everything keeps running |

The bottom bar always tells you where you are: **machine │ session │ tabs │ who is connected**,
in that machine's color.

### VS Code terminals

On a machine, `dm vscode on` adds a `devmesh` terminal profile to VS Code (and VS Code
Insiders and Cursor, if installed). Terminals opened from then on start inside tmux,
named after the project folder (a second one in the same folder is `<project>-2`), so
other devices see them and can attach to the same live terminal.

- `dm vscode status` shows, per settings file, whether it is `on`, `off`, `not-json` or `missing`.
- `dm vscode off` removes the profile and restores your previous default terminal.
- Settings files with comments or trailing commas are not changed: `dm` prints the
  snippet to paste. A `settings.json.devmesh-bak` copy is made before the first change.
- Terminals keep running when VS Code closes. Scroll with the mouse (tmux mouse is on).
  `Ctrl+b` is tmux's prefix key.

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
device) for 2 minutes, the same app shows "Claude on <machine>: <project>". It adds a `Notification` hook to
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
| The tablet "disconnects" | Android is closing Termux. Type `dm` again: your terminals are intact on the machine |
| `dm` says "not enrolled" | That device is not registered: `dm add <name>` from another device and paste the line here |
| The line says "missing secret" | It was copied incompletely: it must end in `sh -s` plus 12 characters |
| The line gives 404 | It expired (15 min), was already used or was cancelled: make another with `dm add` |
| An IP-mode hub moved and devices cannot reach it | `dm repoint <new-ip>` on each device |
| Installer says the OS is not supported | Use Docker: `HUB_HOST=… docker compose -f docker/hub/compose.yml up -d --build` |
| I want to see what Claude is doing in each terminal | Add the hooks from `share/devmesh/hooks/claude-code-hooks.json` to that machine's `~/.claude/settings.json` |
