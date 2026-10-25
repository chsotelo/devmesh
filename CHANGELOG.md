# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.9.14] - 2026-10-24

### Fixed

- A mosh connection that fails right away (seen from the tablet after a machine woke from
  sleep) no longer loops on "reconnecting": the same terminal opens over plain ssh.

## [0.9.13] - 2026-10-24

### Fixed

- A machine that could not be reached for a moment (a Mac waking from sleep, a phone
  changing networks) no longer closes the terminal pane of the workspace: it keeps
  reconnecting, and a missing pane is made again. Before, every tap then failed with
  "no workspace window".
- Back online, the workspace shows again the terminal it was showing before.
- A device added after the workspace was built gets its tab on its own (within a minute,
  or when dm is opened again); no restart needed.
- A device just enrolled fetches the panel on its first "dm" (the join line leaves the
  binary out), so it shows the same layout as every other device instead of the old panel.

## [0.9.12] - 2026-10-24

### Changed

- Each terminal of the list is three lines tall (its name between two padding lines with
  the same background), a comfortable touch target; a tap anywhere on it opens it.
- A list longer than the screen shows a scrollbar and scrolls one terminal per wheel step
  or swipe, on its own: the terminal on the right keeps its position (it scrolls its own
  history).

## [0.9.11] - 2026-10-23

### Changed

- The status bar is three lines tall: machine tabs and Exit (and the list toggle on
  phones) are large touch targets on tablet, phone and desktop alike.
- The terminal list remembers its last reading per machine: a new workspace draws the
  list and opens the last terminal at once instead of "Loading…" while the machine
  answers. The language catalog is cached the same way.

### Fixed

- The workspace jumped on its first frames: it was built at 160x45 and laid out for the
  real screen only after attaching. It is now built at the size of the terminal and laid
  out before it is shown.
- Two tests meant to load the layout in a real tmux were running against the stub.

## [0.9.10] - 2026-10-23

### Changed

- The list buttons are larger touch targets: three lines tall with a background, the
  label centered, filling the list width, and an empty line before the terminals. Exit
  and the narrow-screen buttons in the status bar get wider padding.

## [0.9.9] - 2026-10-23

### Changed

- "+ New" and "Delete" moved from the status bar to the top of the terminal list, like the
  VS Code terminal panel (keys `n`/`+` and `x`/`Delete` in the list). The status bar keeps
  only Exit (and the list toggle on narrow screens).

### Fixed

- The workspace could flicker on Android: every size report re-applied the list width,
  and each resize redraws the whole window. The list is now resized only when its width
  changed.

## [0.9.8] - 2026-10-23

### Fixed

- Accents and symbols showed as "_" in remote terminals (e.g. "_Hola! _En qu_"): over ssh
  the locale does not arrive and tmux fell back to ASCII. Every attach now forces UTF-8
  (`tmux -u`).
- The workspace could stay wider than the screen that opened it (buttons cut on a tablet).
  It now always takes the size of the screen looking at it.
- A new remote terminal never got its origin/creation metadata (`set-option` does not take
  the `=name` form).

## [0.9.7] - 2026-10-23

### Fixed

- A device without any tmux session yet (a phone, a fresh machine) showed as "offline":
  `dm _who` failed under pipefail when tmux had no server. It now reports no terminals,
  and the panel offers "+" to create the first one.

## [0.9.6] - 2026-10-23

### Fixed

- After `dm update`, `dm` re-attached the workspace built by the previous version, whose
  list was still the old program in memory (on Termux: "fork/exec …"). The workspace is now
  stamped with the dm version and rebuilt when it changes.
- The Termux extra-keys notice is shown once, not on every `dm update`.

## [0.9.5] - 2026-10-23

### Added

- A tab for this device (⌂), first: its own terminals, reached locally (no ssh, no hub).
  On a phone it lists the local tmux sessions; on a machine it replaces the trip through
  the hub to itself.

### Fixed

- Termux: the panel's list stayed on "loading…" with "fork/exec …": Go programs bypass
  termux-exec, so dm's "#!/usr/bin/env bash" could not run. dm now passes its bash
  (`DM_BASH`) and the panel runs dm through it.
- A machine check could fail under pipefail (`| grep -q` and SIGPIPE).

### Changed

- Buttons with words in the user's language (New / Delete / Exit, Nueva / Borrar / Salir);
  phones get symbols (☰ + − ✕) since Termux has no emoji font.

## [0.9.4] - 2026-10-23

### Changed

- Terminal list closer to VS Code: the `>_` icon takes the machine color and the running
  program follows the name in gray (`api  claude`); the active machine tab is underlined;
  the `+ 🗑 ✕ ☰` buttons are wider for touch.

## [0.9.3] - 2026-10-23

### Fixed

- `dm` re-attached a workspace left by an older version (tabs per terminal, card panel)
  instead of opening the VS Code like layout. An old workspace is now replaced; it only
  holds views, the terminals on the machines are kept.
- `dm` typed inside a remote terminal opened a panel inside the panel (and so on). It now
  refuses when another device is looking at that terminal, and in a local tmux (machines
  start every terminal in tmux) it hands the window over to the panel instead of nesting.

## [0.9.2] - 2026-10-23

### Changed

- `dm` now opens a VS Code like terminal panel on tmux (3.2+): the status bar is the machine
  selector, each machine window has the list of its terminals on the left (`dm-tui sidebar`) and
  the real remote terminal on the right; status buttons `+` new, `delete` and `exit`, a `☰`
  button on phones (under 70 columns the terminal fills the screen). The card panel stays with
  `DM_UI=cards` and the fzf panel with `DM_UI=fzf`; both are also the automatic fallback without
  `dm-tui` or with tmux older than 3.2.

### Added

- `dm _ws <sub>` workspace commands (validated, used by the layout) and `dm _feed HOST`.
- `DM_DEMO=1` demo hook and `DM_WS_SOCKET` to run a second workspace (screenshots, tests).

## [0.9.1] - 2026-10-23

### Added

- Hub: optional `HUB_OPEN_PORTS` in `hub.conf` (`8730 9000/udp`) opens services running on
  the hub to the mesh only (chain `DEVMESH-HUB-IN`). Re-apply with `devmesh-fw up devmesh`.

## [0.9.0] - 2026-10-22

### Added

- `dm vscode on|off|status` (machines): a `devmesh` terminal profile in VS Code, Insiders and
  Cursor, so their terminals start inside tmux and other devices can attach to them. `on`
  backs up `settings.json` once, keeps your previous default terminal and refuses to edit
  files with comments (it prints the snippet instead).
- `dm _vscode-shell`: the shell that profile runs; the tmux session is named after the folder.
- New panel, `dm-tui` (Go, Bubble Tea), built for touch on a portrait tablet or a phone:
  every machine is a section and every terminal a card with its agent state, origin,
  clients, last activity and a live thumbnail of its screen. One column on a phone, two on
  a portrait tablet, more on wide screens, plus a detail pane from 140 columns (full screen
  detail on narrow ones). Machines refresh every 4 s and the thumbnails of the visible
  cards every 3 s, never blocking the keyboard. Tappable cards and buttons, wheel scroll,
  filter (`/`), guided new terminal, add device, devices list, shortcuts, and a friendly
  first-run screen. It only draws: every remote operation still goes through the bash `dm`.
- `dm _feed`, `_shot`, `_proj`, `_i18n` and `_new` (machine-readable feed, thumbnails,
  projects, the active translation catalog and the validated "new terminal") that the panel
  relies on. `dm` starts `dm-tui` when there is a binary for the OS/arch (`bin/dm-tui-<os>-<arch>`
  in the share directory, or `dm-tui` in PATH; Termux is android/arm64) and `DM_TUI` is not
  `0`; otherwise it keeps using the fzf panel.
- `make tui`, `make tui-all` (macOS, Linux and Android/Termux, arm64 and amd64),
  `make tui-check`; `make hub` builds them so the signed client bundle carries them, and
  the release tarball includes them. CI has a new `go` job (vet, gofmt, tests, builds).
- Repository hygiene: no tracked symlink may point outside the repository; `.claude/` is ignored.

### Changed

- On the home screen of the new panel `esc` clears the filter and then quits (it used to do
  nothing without a filter).
- Enrollment scripts leave the `dm-tui` binaries out (they are several MB each); `dm update`
  installs the one for the device.

## [0.8.1] - 2026-10-22

### Fixed

- Termux: the 0.8.0 `ControlPath` (`~/.ssh/devmesh-%n-%C`) exceeded the Unix socket
  path limit under Termux's long home, so every ssh to the hub failed ("too long for Unix
  domain socket") and `dm update` could not run. It is now `~/.ssh/dm-%n`; the 0.8.0
  value is still accepted. Stuck devices: replace the ControlPath line in
  `~/.ssh/config.d/devmesh` with `ControlPath ~/.ssh/dm-%n`, then `dm update`.

## [0.8.0] - 2026-10-22

### Added

- Mesh firewall on Linux machines (`devmesh-node-fw`, run as `PostUp`/`PostDown` of the
  WireGuard interface): the mesh reaches only SSH, mosh and ping by default. Open ports on
  purpose with `sudo devmesh-node mesh open|close <tcp|udp>/<port>`; `devmesh-node mesh status`
  and `dm mesh` show the state. `dm update` installs it on existing machines. Without
  `iptables` the machine is left as before, with a warning.
- Hub: from the mesh only ping and SSH on 2222 are accepted, and Docker published
  containers are not reachable through the mesh address (`DOCKER-USER` drop).
- Signed trust: device keys, machine host keys and client bundles are signed
  by approver devices (`ssh-keygen -Y`). New devices stay pending until
  `dm approve` (fingerprint tails typed from the new device). Signed
  revocations with a monotonic epoch (`dm rm` on an approver). Commands:
  `dm approve`, `dm trust init|pin|status`, `devmesh invite <name> --owner`.
- `docs/SECURITY-MODEL.md`: assets, attackers, guarantees and residual risks.
- Hub without a domain: IP mode with a self-signed certificate on its own
  port (8443) and a pinned public key in the join line; `dm repoint` after
  moving an IP-mode hub.
- Hub in Docker (`docker/hub/`), and a guided installer (`install.sh`) that
  verifies the release checksums.
- `dm watch`: notifications when an agent waits for approval, with Approve,
  Reject and Open buttons on Android (Termux:API).
- English user interface by default, Spanish with `DM_LANG=es` or `LANG=es_*`.
- Termux extra-keys row (Esc, Ctrl, Tab, arrows) when the user has none.
- CI (lint, unit on Linux and macOS, integration, Docker image) and releases
  with SHA256SUMS and build provenance; demo GIF (`make demo`).
- MIT license, security policy, contributing guide, issue templates,
  repository hygiene tests.

### Changed

- Services listening on `0.0.0.0` on a machine (dev servers, databases) are no longer
  reachable from other devices or from the hub unless opened. Use `dm port`, or
  `sudo devmesh-node mesh open`.
- `node.conf` gains the optional `DM_MESH_OPEN`, kept across re-runs of the join line.
- The hub's ssh_config is validated against the exact grammar devmesh renders
  before it is installed (no command-running options, every alias pinned to
  its own host key); the device list is validated field by field.
- `ControlPath` is now `~/.ssh/devmesh-%n-%C` (one shared connection per alias).
- Documentation: `README.md` and `docs/en/GUIDE.md` in English,
  `docs/es/GUIA.md` in Spanish, design history in `docs/history/DESIGN.md`.

### Fixed

- `dm _who` on Debian/Ubuntu (mawk) listed attached devices with a leading
  comma; awk regexes no longer use `{m,n}` intervals.
- `dm repoint` updates the root-owned WireGuard config and the node's
  known_hosts.

### Removed

- Personal deployment data from tracked files.

## [0.6.1] - 2026-10-21

### Added

- Live single-screen panel: machine cards, terminal list with agent state,
  and a live preview of the selected terminal.

### Changed

- SSH connections are shared between commands on the same host.
- The `dm port` command opens its own connection instead of reusing the
  terminal connection.

### Fixed

- Project-name filtering in the panel.
