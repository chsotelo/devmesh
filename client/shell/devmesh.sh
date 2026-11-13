# shellcheck shell=sh
# devmesh shell integration (bash/zsh). Sourced from ~/.bashrc / ~/.zshrc.
# Terminals that every device can see are Herdr's job now: this only adds a shortcut.

case $- in *i*) ;; *) return 0 ;; esac

alias m='dm go'
