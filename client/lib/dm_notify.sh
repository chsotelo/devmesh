# shellcheck shell=bash
# dm notify: when a Claude Code session needs the user (a permission prompt, or idle waiting
# for an answer) and the user is away from that machine, the hub pushes it to the phone
# through its ntfy. Claude calls "dm _notify"
# from its Notification hook; "dm notify on|off" adds or removes that hook.

# dm_user_idle: seconds since the user last touched this machine, through its keyboard or
# mouse (macOS, GNOME) or any tmux client (local terminals and devices attached over ssh).
# Fails when it cannot tell.
dm_user_idle() {
  local best="" s a now
  now=$(date +%s)
  case $(dm_platform) in
    macos) s=$(ioreg -c IOHIDSystem -d 4 2>/dev/null | awk '/HIDIdleTime/ {print int($NF / 1000000000); exit}') ;;
    linux)
      s=$(gdbus call --session --dest org.gnome.Mutter.IdleMonitor --object-path /org/gnome/Mutter/IdleMonitor/Core \
        --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null | grep -Eo '[0-9]+' | tail -n 1)
      s=${s:+$((s / 1000))}
      ;;
    *) s="" ;;
  esac
  [[ $s =~ ^[0-9]+$ ]] && best=$s
  while read -r a; do
    [[ $a =~ ^[0-9]+$ ]] || continue
    s=$((now > a ? now - a : 0))
    if [[ -z $best ]] || ((s < best)); then best=$s; fi
  done < <(tmux list-clients -F '#{client_activity}' 2>/dev/null)
  [[ -n $best ]] || return 1
  printf '%s\n' "$best"
}

# _notify: Claude's hook JSON on stdin. Nothing is sent while the user is at this machine
# (touched it in the last DM_NOTIFY_AWAY seconds). Never fails, so Claude is never held up.
dm_notify_hook() {
  local input kind=wait proj idle
  input=$(head -c 65536)
  if idle=$(dm_user_idle) && ((idle < ${DM_NOTIFY_AWAY:-120})); then
    return 0
  fi
  # notification_type (older Claude versions: only the message says it).
  if [[ $input =~ \"notification_type\"[[:space:]]*:[[:space:]]*\"permission_prompt\" ||
    $input =~ \"message\"[[:space:]]*:[[:space:]]*\"Claude\ needs\ your\ permission ]]; then
    kind=perm
  fi
  proj=$(dm_sanitize "$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")")
  ssh -o BatchMode=yes -o ConnectTimeout=5 hub-admin notify claude "${proj:-session}" "$kind" \
    </dev/null >/dev/null 2>&1 || true
}

# dm_notify_py ACTION FILE [COMMAND]: prints changed, unchanged, on, off or not-json.
# Only this function touches Claude's settings.json (stdlib only).
dm_notify_py() {
  python3 -I - "$@" <<'PY'
import json
import os
import shutil
import stat
import sys
import tempfile


def reject_constant(name):
    raise ValueError("non-standard JSON constant " + name)


def load(path):
    with open(path, encoding="utf-8-sig") as f:
        text = f.read()
    if not text.strip():
        return {}
    try:
        data = json.loads(text, parse_constant=reject_constant)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def is_dm_notify(command):
    command = str(command)
    return command == "dm _notify" or command.endswith("/dm _notify")


def ours(group):
    # A group whose every hook is devmesh's "<path>/dm _notify".
    hooks = group.get("hooks") if isinstance(group, dict) else None
    return isinstance(hooks, list) and bool(hooks) and all(
        isinstance(h, dict) and is_dm_notify(h.get("command", "")) for h in hooks)


def groups(data):
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        return None
    groups = hooks.get("Notification", [])
    return groups if isinstance(groups, list) else None


def turn_off(data):
    rest = [g for g in groups(data) if not ours(g)]
    hooks = dict(data.get("hooks", {}))
    if rest:
        hooks["Notification"] = rest
    else:
        hooks.pop("Notification", None)
    out = dict(data)
    if hooks:
        out["hooks"] = hooks
    else:
        out.pop("hooks", None)
    return out


def turn_on(data, command):
    out = turn_off(data)
    hooks = dict(out.get("hooks", {}))
    entry = {"hooks": [{"type": "command", "command": command, "timeout": 10}]}
    hooks["Notification"] = list(hooks.get("Notification", [])) + [entry]
    out["hooks"] = hooks
    return out


def write(path, data):
    mode = stat.S_IMODE(os.stat(path).st_mode) if os.path.exists(path) else 0o600
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
    # A symlinked settings file (dotfiles) stays a link: its target is what gets edited.
    action, path = sys.argv[1], os.path.realpath(sys.argv[2])
    data = load(path) if os.path.exists(path) else {}
    if data is None or groups(data) is None:
        print("not-json")
        return
    if action == "status":
        print("on" if any(ours(g) for g in groups(data)) else "off")
        return
    new = turn_off(data) if action == "off" else turn_on(data, sys.argv[3])
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

# dm notify on|off|status: the Notification hook in ~/.claude/settings.json.
dm_notify() {
  local file="$HOME/.claude/settings.json" action=${1:-status} res
  case $action in on | off | status) ;; *) dm_die "usage: dm notify on|off|status" ;; esac
  command -v python3 >/dev/null 2>&1 || dm_die "python3 not found: nothing was changed"
  [[ $action != on ]] || [[ -n ${DM_SELF:-} ]] || dm_die "DM_SELF is not set: run dm from its installed path"
  mkdir -p "${file%/*}"
  res=$(dm_notify_py "$action" "$file" "${DM_SELF:-} _notify") || res=error
  case $res in
    on | off) printf '%s       %s\n' "$res" "$file" ;;
    changed | unchanged) printf '%s       %s\n' "$action" "$file" ;;
    *) dm_die "not modified: $file is not plain JSON (comments or trailing commas?)" ;;
  esac
}
