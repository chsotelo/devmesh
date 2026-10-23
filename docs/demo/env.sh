# shellcheck shell=bash
# Demo environment for docs/demo.tape: fake machines answered by the test ssh stub,
# so the GIF shows a realistic panel without real devices. Source it, then run "dm panel".
DEMO_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DEMO_DIR=$(mktemp -d)
# Only the ssh stub goes first in PATH: tmux stays the real one (the layout is real tmux).
mkdir -p "$DEMO_DIR/bin"
ln -s "$DEMO_REPO/tests/stubs/ssh" "$DEMO_DIR/bin/ssh"
export PATH="$DEMO_DIR/bin:$DEMO_REPO/client/bin:$PATH"
export DM_SHARE="$DEMO_REPO/client" DM_CACHE="$DEMO_DIR/cache" DM_CONF="$DEMO_DIR/node.conf"
export STUB_SSH_DIR="$DEMO_DIR/ssh" DM_LANG=${DM_LANG:-en} HOME="$DEMO_DIR/home"
mkdir -p "$DM_CACHE" "$HOME/.ssh"
printf 'DM_NAME=tablet\nDM_KIND=phone\nDM_HUB_HOST=hub.example.com\n' >"$DM_CONF"
printf 'laptop\tmachine\t10.73.0.2\t2202\t33\tdev\thome\t-\n' >"$DM_CACHE/hosts.tsv"
printf 'desktop\tmachine\t10.73.0.4\t2204\t99\tdev\toffice\t-\n' >>"$DM_CACHE/hosts.tsv"
printf 'builder\tmachine\t10.73.0.6\t2206\t178\tdev\toffice\taa:bb:cc:dd:ee:06\n' >>"$DM_CACHE/hosts.tsv"
printf 'tablet\tphone\t10.73.0.3\t-\t-\t-\t-\t-\n' >>"$DM_CACHE/hosts.tsv"
# builder is switched off: the panel shows it dimmed, with its wake button.
export STUB_SSH_DOWN="builder builder-b"

demo_reply() {
  mkdir -p "$STUB_SSH_DIR/$1"
  printf '%s' "$3" >"$STUB_SSH_DIR/$1/$2"
}
demo_now=$(date +%s)
t=$'\t'
demo_reply laptop dm__who "api${t}1${t}api:claude${t}1${t}claude${t}waiting${t}tablet${t}$((demo_now - 7200))${t}$((demo_now - 40))${t}tablet
web${t}1${t}web:npm${t}1${t}node${t}-${t}laptop${t}$((demo_now - 9000))${t}$((demo_now - 300))${t}-
docs${t}1${t}docs:claude${t}1${t}claude${t}working${t}laptop${t}$((demo_now - 600))${t}$((demo_now - 5))${t}-
"
demo_reply desktop dm__who "main${t}1${t}main:zsh${t}1${t}zsh${t}-${t}desktop${t}$((demo_now - 86400))${t}$((demo_now - 3600))${t}-
"
demo_reply laptop dm__capture_api_1 $'$ claude\n\n  I updated the auth middleware and added tests.\n\n  Edit src/auth.ts?\n  ❯ 1. Yes\n    2. Yes, and don\'t ask again\n    3. No\n'
demo_reply laptop dm__capture_docs_1 $'$ claude\n\n  ● Writing docs/guide.md…\n'
demo_reply laptop dm__capture_web_1 $'$ npm run dev\n\n  VITE v6  ready in 312 ms\n  ➜  Local: http://localhost:5173/\n'
demo_reply desktop dm__capture_main_1 $'~ $ ls\nnotes.md  src  tests\n~ $ uptime\n up 12 days, 3:41\n~ $ \n'
demo_reply laptop dm__capture_mobile_1 $'$ cd ~/PROJECTS/mobile\n$ claude\n\n  ● Reading the project files…\n'
demo_reply laptop dm__projects $'api\ndocs\nweb\nmobile\n'
unset t demo_now
