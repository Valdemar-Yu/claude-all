#!/usr/bin/env bash
# Install claude-all's unified statusline into one Claude Code config directory.
set -euo pipefail

_SOURCE="${BASH_SOURCE[0]:-$0}"
_ROOT="$(cd "$(dirname "$_SOURCE")/.." >/dev/null 2>&1 && pwd)"
PREFIX="${CLAUDE_ALL_PREFIX:-$HOME/.local/share/claude-all}"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

command -v python3 >/dev/null 2>&1 || { echo "[claude-all] python3 not found" >&2; exit 1; }
mkdir -p "$PREFIX/statusline" "$PREFIX/lib"
[ "$_ROOT/statusline/statusline.py" = "$PREFIX/statusline/statusline.py" ] \
  || cp "$_ROOT/statusline/statusline.py" "$PREFIX/statusline/statusline.py"
[ "$_ROOT/lib/statusline.sh" = "$PREFIX/lib/statusline.sh" ] \
  || cp "$_ROOT/lib/statusline.sh" "$PREFIX/lib/statusline.sh"
chmod +x "$PREFIX/statusline/statusline.py"
# shellcheck source=/dev/null
source "$PREFIX/lib/statusline.sh"
command="$(_claude_all_statusline_command "$PREFIX")"
_claude_all_statusline_install "$CONFIG_DIR" "$command"
echo "[claude-all] statusline installed: $CONFIG_DIR/settings.json"
