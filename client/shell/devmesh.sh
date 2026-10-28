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

# When Claude Code ends in a tmux terminal (/exit, Ctrl+C, stopped), the "claude --resume
# <id>" line it printed is typed at the next prompt: Enter resumes, Ctrl+C drops it. The
# newest such line on this pane's screen is offered, once.
devmesh_resume_line() {
  DEVMESH_RESUME=
  [ -n "${TMUX_PANE:-}" ] || return 1
  devmesh_cmd=${DEVMESH_LAST_CMD:-}
  DEVMESH_LAST_CMD=
  case $devmesh_cmd in *claude* | *flow*) ;; *) return 1 ;; esac
  # The screen is untrusted: only a plain path and a session id ever reach the prompt.
  DEVMESH_RESUME=$(tmux capture-pane -p -J -t "$TMUX_PANE" -S -20 2>/dev/null |
    grep -Eo '(cd /[A-Za-z0-9._/-]+ && )?claude --resume [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' |
    tail -n 1)
  [ -n "$DEVMESH_RESUME" ] && [ "$DEVMESH_RESUME" != "${DEVMESH_OFFERED:-}" ] || return 1
  DEVMESH_OFFERED=$DEVMESH_RESUME
}
if [ -n "${ZSH_VERSION:-}" ]; then
  devmesh_preexec() { DEVMESH_LAST_CMD=$1; }
  devmesh_precmd() { devmesh_resume_line && print -z -- "$DEVMESH_RESUME"; }
  autoload -Uz add-zsh-hook && add-zsh-hook preexec devmesh_preexec && add-zsh-hook precmd devmesh_precmd
elif [ -n "${BASH_VERSION:-}" ]; then
  # bash cannot fill its own prompt from PROMPT_COMMAND: the tmux server types the line
  # once the prompt is drawn (run-shell -C -d, tmux 3.2+; older ones type it right away).
  # The line holds only safe characters, so single quotes are enough.
  devmesh_prompt() {
    # Already set when the shell was started by an asleep terminal whose Claude just ended.
    [ -n "${DEVMESH_LAST_CMD:-}" ] || DEVMESH_LAST_CMD=$(HISTTIMEFORMAT='' history 1 2>/dev/null)
    if devmesh_resume_line; then
      tmux run-shell -b -d 0.2 -C "send-keys -t $TMUX_PANE -l '$DEVMESH_RESUME'" 2>/dev/null ||
        tmux send-keys -t "$TMUX_PANE" -l "$DEVMESH_RESUME"
    fi
    return 0
  }
  PROMPT_COMMAND="devmesh_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
