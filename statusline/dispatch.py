#!/usr/bin/env python3
"""Dispatch claudish statusline calls to a project's Baton wrapper when present."""
import json
import os
import shlex
import subprocess
import sys


HERE = os.path.dirname(os.path.abspath(__file__))
ORIGINAL = os.path.join(HERE, "statusline.py")
GUARD = "CLAUDE_ALL_STATUSLINE_DISPATCH_ACTIVE"


def _project_dir(session):
    workspace = session.get("workspace") or {}
    return (
        workspace.get("project_dir")
        or workspace.get("current_dir")
        or session.get("cwd")
        or os.getcwd()
    )


def _statusline_command(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError, TypeError):
        return None
    status = data.get("statusLine") if isinstance(data, dict) else None
    if not isinstance(status, dict) or status.get("type", "command") != "command":
        return None
    command = status.get("command")
    return command if isinstance(command, str) else None


def _trusted_baton_scripts():
    candidates = [
        os.path.join(HERE, "..", "baton", "skills", "baton", "scripts", "statusline.py"),
        os.path.expanduser("~/.claude/skills/baton/scripts/statusline.py"),
    ]
    trusted = []
    for candidate in candidates:
        if not os.path.isfile(candidate):
            continue
        real = os.path.realpath(candidate)
        if real not in trusted:
            trusted.append(real)
    return trusted


def _trusted_baton_script(command):
    """Return a trusted Baton script only for Baton's exact command shape."""
    try:
        parts = shlex.split(command or "")
    except ValueError:
        return None
    if len(parts) != 3 or parts[2] != "--baton-statusline":
        return None
    interpreter = os.path.realpath(parts[0])
    if os.path.basename(parts[0]) not in ("python", "python3") and interpreter != os.path.realpath(sys.executable):
        return None
    script = parts[1]
    if not script.endswith("skills/baton/scripts/statusline.py"):
        return None
    try:
        script_real = os.path.realpath(script)
        if not os.path.isfile(script_real):
            return None
        for trusted in _trusted_baton_scripts():
            if os.path.samefile(script_real, trusted):
                return trusted
    except OSError:
        return None
    return None


def _run(argv, raw, env):
    try:
        return subprocess.run(
            argv,
            shell=False,
            input=raw,
            capture_output=True,
            timeout=8,
            env=env,
        )
    except (OSError, subprocess.SubprocessError):
        return None


def main():
    raw = sys.stdin.buffer.read()
    try:
        session = json.loads(raw or b"{}")
    except (ValueError, TypeError):
        session = {}
    if not isinstance(session, dict):
        session = {}

    env = dict(os.environ)
    env[GUARD] = "1"
    if not os.environ.get(GUARD):
        project = _project_dir(session)
        baton_command = _statusline_command(
            os.path.join(project, ".claude", "settings.local.json")
        )
        baton_script = _trusted_baton_script(baton_command)
        if baton_script:
            result = _run([sys.executable, baton_script, "--baton-statusline"], raw, env)
            if result is not None and result.returncode == 0 and result.stdout:
                sys.stdout.buffer.write(result.stdout)
                return

    result = _run([sys.executable, ORIGINAL], raw, env)
    if result is not None and result.stdout:
        sys.stdout.buffer.write(result.stdout)


if __name__ == "__main__":
    main()
