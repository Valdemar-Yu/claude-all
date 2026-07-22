#!/usr/bin/env bash
# claude-all 卸载器。config 目录改名为 .backup 保留(session/memory 不丢)。
set -euo pipefail

PREFIX="$HOME/.local/share/claude-all"
BINDIR="$HOME/.local/bin"
CFGDIR="$HOME/.claude-plbbl"
TS="$(date +%s 2>/dev/null || echo bak)"

c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
info() { echo "$(c '1;36' '[claude-all]') $*"; }

info "卸载..."
if [ -f "$PREFIX/lib/statusline.sh" ]; then
  # shellcheck source=/dev/null
  source "$PREFIX/lib/statusline.sh"
  _statusline_command="$(_claude_all_statusline_command "$PREFIX")"
  _claude_all_statusline_remove "$HOME/.claude-all" "$_statusline_command"
  _claude_all_statusline_remove "$CFGDIR" "$_statusline_command"
  _claude_all_statusline_remove "$HOME/.claude" "$_statusline_command"
  [ -d "$HOME/.claude-glm" ] && _claude_all_statusline_remove "$HOME/.claude-glm" "$_statusline_command"
fi
rm -f "$BINDIR/claude-all" "$BINDIR/cc-gpt-plbbl" "$BINDIR/claude-plbbl"
rm -rf "$PREFIX"

# config dir 含 session/memory(可能 symlink 到 ~/.claude/projects),改名保留不直删
if [ -d "$CFGDIR" ]; then
  mv "$CFGDIR" "$CFGDIR.backup.$TS"
  info "config 目录保留为 $CFGDIR.backup.$TS(确认无用后可删:rm -rf $_)"
fi

info "完成。配置文件 ~/.config/claude-all/config 保留(手动删:rm -rf ~/.config/claude-all)。"
info "~/.claude-all 多环境目录与官方 ~/.claude 未受影响(单独清理:rm -rf ~/.claude-all)。"
info "注:install 时对 claudish 的 patch(若有)未还原,备份在 claudish 包内 dist/index.js.claude-all-bak,无害。"
