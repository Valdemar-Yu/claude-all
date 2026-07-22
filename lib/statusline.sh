#!/usr/bin/env bash
# claude-all statusline settings merge helpers. Sourced by install/uninstall scripts.

_claude_all_statusline_command() {
  STATUSLINE_PATH="$1/statusline/statusline.py" python3 - <<'PY'
import os, shlex
print("python3 " + shlex.quote(os.environ["STATUSLINE_PATH"]), end="")
PY
}

_claude_all_statusline_install() {
  local config_dir="$1" command="$2" settings="$1/settings.json"
  mkdir -p "$config_dir"
  chmod 700 "$config_dir" 2>/dev/null || true
  STATUSLINE_SETTINGS="$settings" STATUSLINE_COMMAND="$command" python3 - <<'PY'
import json, os, shutil, tempfile, time
path = os.environ["STATUSLINE_SETTINGS"]
command = os.environ["STATUSLINE_COMMAND"]
state_path = path + ".claude-all-statusline.json"
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("settings root is not an object")
except FileNotFoundError:
    data = {}
if not os.path.exists(state_path):
    previous = data.get("statusLine")
    managed = isinstance(previous, dict) and "/claude-all/statusline/statusline.py" in str(previous.get("command", ""))
    state = {"had_statusline": previous is not None and not managed,
             "statusline": previous if previous is not None and not managed else None}
    fd, tmp_state = tempfile.mkstemp(prefix=".statusline-state.", dir=os.path.dirname(path), text=True)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, ensure_ascii=False, separators=(",", ":"))
        os.chmod(tmp_state, 0o600)
        os.replace(tmp_state, state_path)
    finally:
        try: os.unlink(tmp_state)
        except FileNotFoundError: pass
if os.path.exists(path):
    backup = f"{path}.claude-all-bak.{time.time_ns()}"
    shutil.copy2(path, backup)
data["statusLine"] = {"type": "command", "command": command, "refreshInterval": 60}
fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=os.path.dirname(path), text=True)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
os.chmod(path, 0o600)
PY
}

_claude_all_statusline_remove() {
  local config_dir="$1" command="$2" settings="$1/settings.json"
  [ -f "$settings" ] || return 0
  STATUSLINE_SETTINGS="$settings" STATUSLINE_COMMAND="$command" python3 - <<'PY'
import json, os, tempfile
path = os.environ["STATUSLINE_SETTINGS"]
command = os.environ["STATUSLINE_COMMAND"]
state_path = path + ".claude-all-statusline.json"
try:
    data = json.load(open(path))
except Exception:
    raise SystemExit(0)
status = data.get("statusLine")
if not isinstance(status, dict) or status.get("command") != command:
    raise SystemExit(0)
try:
    state = json.load(open(state_path))
except Exception:
    state = {"had_statusline": False, "statusline": None}
if state.get("had_statusline"):
    data["statusLine"] = state.get("statusline")
else:
    data.pop("statusLine", None)
fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=os.path.dirname(path), text=True)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
try: os.unlink(state_path)
except FileNotFoundError: pass
PY
}
