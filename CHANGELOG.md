# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
