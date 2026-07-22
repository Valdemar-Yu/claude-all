#!/usr/bin/env bash
# Patch claudish so claude-all can replace its generated statusline.
# Optional --auth also removes the duplicate ANTHROPIC_API_KEY placeholder.
set -euo pipefail

c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
info() { echo "$(c '1;36' '[claude-all]') $*"; }
warn() { echo "$(c '1;33' '[claude-all]') $*" >&2; }

PATCH_AUTH=0
for arg in "$@"; do
  case "$arg" in
    --auth) PATCH_AUTH=1 ;;
    --statusline-only) PATCH_AUTH=0 ;;
    *) warn "未知参数:$arg"; exit 2 ;;
  esac
done

command -v claudish >/dev/null 2>&1 || { warn "没找到 claudish,跳过 patch"; exit 0; }
_BIN="$(command -v claudish)"
while [ -L "$_BIN" ]; do
  _DIR="$(cd -P "$(dirname "$_BIN")" >/dev/null 2>&1 && pwd)"
  _BIN="$(readlink "$_BIN")"
  case "$_BIN" in /*) : ;; *) _BIN="$_DIR/$_BIN" ;; esac
done
_DIST="$(cd -P "$(dirname "$_BIN")/../dist" >/dev/null 2>&1 && pwd)/index.js"
[ -f "$_DIST" ] || { warn "没找到 claudish dist/index.js"; exit 0; }

[ -f "$_DIST.claude-all-bak" ] || cp "$_DIST" "$_DIST.claude-all-bak"
_run_backup="$(mktemp "${TMPDIR:-/tmp}/claudish-index.XXXXXX")"
cp "$_DIST" "$_run_backup"
trap 'rm -f "$_run_backup"' EXIT INT TERM

DIST="$_DIST" PATCH_AUTH="$PATCH_AUTH" python3 - <<'PY'
import os, tempfile
from pathlib import Path
path = Path(os.environ["DIST"])
text = path.read_text()
changed = []

if "CLAUDISH_STATUSLINE_COMMAND" not in text:
    old = '''  const statusLine = {
    type: "command",
    command: statusCommand,
    padding: 0
  };'''
    new = '''  const customStatusCommand = process.env.CLAUDISH_STATUSLINE_COMMAND;
  if (customStatusCommand) {
    statusCommand = customStatusCommand;
  }
  const statusLine = {
    type: "command",
    command: statusCommand,
    padding: 0
  };
  const customRefresh = Number.parseInt(process.env.CLAUDISH_STATUSLINE_REFRESH ?? "", 10);
  if (Number.isFinite(customRefresh) && customRefresh >= 1) {
    statusLine.refreshInterval = customRefresh;
  }'''
    if text.count(old) != 1:
        raise SystemExit("claudish statusLine anchor not found uniquely")
    text = text.replace(old, new, 1)
    changed.append("statusline")

if os.environ["PATCH_AUTH"] == "1" and "claude-all auth patch" not in text:
    lines = text.splitlines()
    found = False
    for i, line in enumerate(lines):
        if 'env.ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || "sk-ant-api03-placeholder' in line:
            indent = line[:len(line) - len(line.lstrip())]
            lines[i] = indent + "/* claude-all auth patch: keep ANTHROPIC_AUTH_TOKEN only */"
            found = True
            break
    if found:
        text = "\n".join(lines) + ("\n" if text.endswith("\n") else "")
        changed.append("auth")
    elif not ('env.ANTHROPIC_AUTH_TOKEN = process.env.ANTHROPIC_AUTH_TOKEN || "placeholder-token' in text
              and 'env.ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || "sk-ant-api03-placeholder' not in text):
        raise SystemExit("claudish auth placeholder anchor not found")

fd, tmp = tempfile.mkstemp(prefix=".index.js.claude-all.", dir=str(path.parent), text=True)
try:
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, path.stat().st_mode & 0o777)
    os.replace(tmp, path)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
print(",".join(changed) if changed else "already-patched")
PY

if command -v node >/dev/null 2>&1 && ! node --check "$_DIST" >/dev/null 2>&1; then
  cp "$_run_backup" "$_DIST"
  warn "patch 后语法检查失败,已回滚本次改动"
  exit 1
fi
info "claudish statusline patch 已就绪。claudish 升级后重跑本脚本。"
