# shellcheck shell=bash
# dm vscode: VS Code terminals born inside tmux, so every device sees them and can attach.

# Machines only: the same test as devmesh_autostart_tmux in client/shell/devmesh.sh.
dm_vscode_is_machine() {
  [[ -r /etc/devmesh/node.conf ]] && return 0
  grep -qx 'DM_KIND=machine' "$HOME/.config/devmesh/node.conf" 2>/dev/null
}

# The terminal-profile key suffix VS Code uses for this platform.
dm_vscode_os() {
  case $(dm_platform) in
    macos) printf 'osx\n' ;;
    linux) printf 'linux\n' ;;
    *) return 1 ;;
  esac
}

# settings.json of each VS Code family app whose folder exists (or whose file exists).
dm_vscode_targets() {
  local base app dir
  case $(dm_platform) in
    macos) base="$HOME/Library/Application Support" ;;
    linux) base="$HOME/.config" ;;
    *) return 0 ;;
  esac
  for app in "Code" "Code - Insiders" "Cursor"; do
    dir="$base/$app"
    if [[ -e $dir/User/settings.json || -d $dir ]]; then
      printf '%s\n' "$dir/User/settings.json"
    fi
  done
}

# The keys to paste at the top level of a settings.json (used when it cannot be edited).
dm_vscode_snippet() {
  local os=$1 self=$2 esc
  esc=$(printf '%s' "$self" | sed 's/\\/\\\\/g; s/"/\\"/g')
  cat <<EOF
  "terminal.integrated.profiles.$os": {
    "devmesh": { "path": "$esc", "args": ["_vscode-shell"] }
  },
  "terminal.integrated.defaultProfile.$os": "devmesh"
EOF
}

# dm_vscode_py ACTION FILE OS [DM_PATH]: prints changed, unchanged, on, off, not-json,
# unsupported. Only this function touches the JSON (stdlib only).
dm_vscode_py() {
  python3 -I - "$@" <<'PY'
import json
import os
import shutil
import stat
import sys
import tempfile

NAME = "devmesh"
PREV = "devmesh.previousDefaultProfile"


def reject_constant(name):
    raise ValueError("non-standard JSON constant " + name)


def load(path):
    # utf-8-sig: VS Code tolerates a BOM. None = not strict JSON (comments, trailing commas).
    with open(path, encoding="utf-8-sig") as f:
        text = f.read()
    if not text.strip():
        return {}
    try:
        data = json.loads(text, parse_constant=reject_constant)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def keys(os_key):
    return "terminal.integrated.profiles." + os_key, "terminal.integrated.defaultProfile." + os_key


def turn_on(data, os_key, self_path):
    prof_key, def_key = keys(os_key)
    profiles = data.get(prof_key, {})
    if not isinstance(profiles, dict):
        return None
    out = dict(data)
    new_profiles = dict(profiles)
    new_profiles[NAME] = {"path": self_path, "args": ["_vscode-shell"]}
    out[prof_key] = new_profiles
    if out.get(def_key) != NAME:
        # Keeps the previous default; null means "there was none" (off removes the key).
        out[PREV] = out.get(def_key)
        out[def_key] = NAME
    return out


def turn_off(data, os_key):
    prof_key, def_key = keys(os_key)
    out = dict(data)
    profiles = out.get(prof_key)
    if isinstance(profiles, dict) and NAME in profiles:
        rest = {k: v for k, v in profiles.items() if k != NAME}
        if rest:
            out[prof_key] = rest
        else:
            del out[prof_key]
    # A default the user changed by hand while devmesh was on is left alone.
    if out.get(def_key) == NAME:
        prev = out.pop(PREV, None)
        if prev is None:
            out.pop(def_key, None)
        else:
            out[def_key] = prev
    else:
        out.pop(PREV, None)
    return out


def is_on(data, os_key):
    prof_key, def_key = keys(os_key)
    profiles = data.get(prof_key)
    return isinstance(profiles, dict) and NAME in profiles and data.get(def_key) == NAME


def write(path, data):
    mode = stat.S_IMODE(os.stat(path).st_mode) if os.path.exists(path) else 0o644
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main():
    action, path, os_key = sys.argv[1], sys.argv[2], sys.argv[3]
    self_path = sys.argv[4] if len(sys.argv) > 4 else ""
    data = load(path) if os.path.exists(path) else {}
    if data is None:
        print("not-json")
        return
    if action == "status":
        print("on" if is_on(data, os_key) else "off")
        return
    new = turn_off(data, os_key) if action == "off" else turn_on(data, os_key, self_path)
    if new is None:
        print("unsupported")
        return
    if new == data:
        print("unchanged")
        return
    if os.path.exists(path) and not os.path.exists(path + ".devmesh-bak"):
        shutil.copy2(path, path + ".devmesh-bak")
    write(path, new)
    print("changed")


main()
PY
}

dm_vscode_no_python() {
  local os self
  os=$(dm_vscode_os) || dm_die "unsupported platform"
  self=${DM_SELF:-dm}
  dm_info "python3 not found: nothing was changed. Paste these keys at the top level of each"
  dm_info "settings.json listed by 'dm vscode status', then open a new terminal:"
  dm_vscode_snippet "$os" "$self" >&2
}

dm_vscode_on() {
  local os self file res rc=0 targets
  os=$(dm_vscode_os) || dm_die "unsupported platform"
  self=${DM_SELF:-}
  [[ -n $self ]] || dm_die "DM_SELF is not set: run dm from its installed path"
  targets=$(dm_vscode_targets)
  if [[ -z $targets ]]; then
    dm_info "no VS Code, VS Code Insiders or Cursor settings folder found"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    dm_vscode_no_python
    return 1
  fi
  while IFS= read -r file; do
    mkdir -p "$(dirname "$file")"
    res=$(dm_vscode_py on "$file" "$os" "$self") || res=error
    case $res in
      changed) printf 'on        %s\n' "$file" ;;
      unchanged) printf 'on        %s (already on)\n' "$file" ;;
      *)
        printf 'not modified: %s is not plain JSON (comments or trailing commas?)\n' "$file" >&2
        printf 'Paste these keys at its top level instead:\n' >&2
        dm_vscode_snippet "$os" "$self" >&2
        rc=1
        ;;
    esac
  done <<<"$targets"
  if [[ $rc -eq 0 ]]; then
    dm_info ""
    dm_info "New VS Code terminals now start inside tmux, named after the project."
    dm_info "They keep running when VS Code closes. Scroll with the mouse (tmux mouse is on)."
    dm_info "Ctrl+b is tmux's prefix key."
  fi
  return "$rc"
}

dm_vscode_off() {
  local os file res rc=0 targets
  os=$(dm_vscode_os) || dm_die "unsupported platform"
  targets=$(dm_vscode_targets)
  if [[ -z $targets ]]; then
    dm_info "no VS Code, VS Code Insiders or Cursor settings folder found"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    dm_info "python3 not found: nothing was changed. Remove the devmesh keys from settings.json by hand."
    return 1
  fi
  while IFS= read -r file; do
    [[ -e $file ]] || continue
    res=$(dm_vscode_py off "$file" "$os") || res=error
    case $res in
      changed | unchanged) printf 'off       %s\n' "$file" ;;
      *)
        printf 'not modified: %s is not plain JSON (remove the devmesh keys by hand)\n' "$file" >&2
        rc=1
        ;;
    esac
  done <<<"$targets"
  return "$rc"
}

dm_vscode_status() {
  local os file res rc=0 targets
  os=$(dm_vscode_os) || dm_die "unsupported platform"
  targets=$(dm_vscode_targets)
  if [[ -z $targets ]]; then
    dm_info "no VS Code, VS Code Insiders or Cursor settings folder found"
    return 0
  fi
  while IFS= read -r file; do
    if [[ ! -e $file ]]; then
      printf 'missing   %s\n' "$file"
      continue
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      printf 'unknown   %s (python3 not found)\n' "$file"
      continue
    fi
    res=$(dm_vscode_py status "$file" "$os") || res=error
    printf '%-9s %s\n' "$res" "$file"
    [[ $res == on || $res == off ]] || rc=1
  done <<<"$targets"
  return "$rc"
}

# dm vscode on|off|status: machines only, the profile is opt-in (client/shell is unchanged).
dm_vscode() {
  dm_vscode_is_machine || dm_die "dm vscode runs on machines only (this device is a phone or a client)"
  case ${1:-status} in
    on) dm_vscode_on ;;
    off) dm_vscode_off ;;
    status) dm_vscode_status ;;
    *) dm_die "usage: dm vscode on|off|status" ;;
  esac
}

# _vscode-shell: the shell a VS Code "devmesh" profile runs. VS Code starts it in the
# workspace folder, so the session is named after that folder: <proj>, <proj>-2, <proj>-3...
dm_vscode_shell() {
  local shell=${SHELL:-/bin/zsh} proj name n=2
  if [[ -n ${TMUX:-} ]] || ! command -v tmux >/dev/null 2>&1; then
    exec "$shell" -l
  fi
  proj=$(dm_sanitize "${PWD##*/}")
  # Truncated so "<proj>-N" stays a valid session name for dm_valid_session (30 chars).
  proj=$(dm_sanitize "${proj:0:28}")
  proj=${proj:-vscode}
  name=$proj
  # Created detached first: options chained after an attaching new-session only run once
  # that client detaches. "new-session -d" also fails when two terminals race for a name.
  until tmux new-session -d -s "$name" -c "$PWD" 2>/dev/null; do
    name="$proj-$n"
    n=$((n + 1))
    ((n < 100)) || exec "$shell" -l
  done
  tmux set-option -t "$name" @origin vscode \; set-option -t "$name" @created "$(date +%s)"
  # -u: UTF-8 always. Over ssh the locale variables do not arrive, and without UTF-8 tmux
  # draws every accent and symbol as "_".
  exec tmux -u attach-session -t "$name"
}
