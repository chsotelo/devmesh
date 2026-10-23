#!/usr/bin/env bash
# Starts the demo workspace (fake machines, see env.sh) with the VS Code like layout.
# DM_DEMO=1 makes every terminal pane print the canned screen of the ssh stub instead of
# opening a live remote tmux (the fake ssh cannot run one).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
BASH5=$(command -v bash)
[[ -x /opt/homebrew/bin/bash ]] && BASH5=/opt/homebrew/bin/bash
tmux -L demo kill-server 2>/dev/null || true
exec env -u TMUX "$BASH5" -c 'source docs/demo/env.sh; export DM_DEMO=1 DM_WS_SOCKET=demo; exec dm'
