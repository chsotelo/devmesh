#!/usr/bin/env bash
# Starts the demo workspace (fake machines, see env.sh) in a private tmux server.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
BASH5=$(command -v bash)
[[ -x /opt/homebrew/bin/bash ]] && BASH5=/opt/homebrew/bin/bash
exec tmux -L demo -f client/tmux/workspace.conf new-session -A -s devmesh -n panel \
  "$BASH5 -c 'source docs/demo/env.sh; dm panel'"
