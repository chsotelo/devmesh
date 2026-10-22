# shellcheck shell=sh
# devmesh shell integration (bash/zsh). Sourced from ~/.bashrc / ~/.zshrc.

case $- in *i*) ;; *) return 0 ;; esac

alias m='dm go'
alias t='dm terms'

# Every local terminal on a machine is born inside tmux, so it is visible from other
# devices. Not inside tmux, not over SSH/mosh, not in IDE terminals, not on Termux.
# No "exec": if tmux fails or exits, the plain shell stays usable.
devmesh_autostart_tmux() {
  [ -n "${TMUX:-}" ] && return 0
  # Machines only (Linux: /etc/devmesh, macOS: ~/.config/devmesh), not phones/controls.
  if [ ! -r /etc/devmesh/node.conf ]; then
    grep -qx 'DM_KIND=machine' "$HOME/.config/devmesh/node.conf" 2>/dev/null || return 0
  fi
  [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] && return 0
  [ -n "${DEVMESH_NO_TMUX:-}${TERMUX_VERSION:-}" ] && return 0
  case "${TERM_PROGRAM:-}${TERMINAL_EMULATOR:-}" in
    vscode* | *JetBrains*) return 0 ;;
  esac
  [ -n "${INSIDE_EMACS:-}${NVIM:-}${VIM_TERMINAL:-}" ] && return 0
  command -v tmux >/dev/null 2>&1 || return 0
  tmux new-session
}
devmesh_autostart_tmux
