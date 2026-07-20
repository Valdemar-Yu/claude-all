#!/usr/bin/env bash
# cc-gpt-plbbl 卸载器。config 目录改名为 .backup 保留(session/memory 不丢)。
set -euo pipefail

PREFIX="$HOME/.local/share/cc-gpt-plbbl"
BINDIR="$HOME/.local/bin"
CFGDIR="$HOME/.claude-ccgpt"
TS="$(date +%s 2>/dev/null || echo bak)"

c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
info() { echo "$(c '1;36' '[cc-gpt-plbbl]') $*"; }

info "卸载..."
rm -f "$BINDIR/cc-gpt-plbbl"
rm -rf "$PREFIX"

# config dir 含 session/memory(可能 symlink 到 ~/.claude/projects),改名保留不直删
if [ -d "$CFGDIR" ]; then
  mv "$CFGDIR" "$CFGDIR.backup.$TS"
  info "config 目录保留为 $CFGDIR.backup.$TS(确认无用后可删:rm -rf $_)"
fi

info "完成。配置文件 ~/.config/cc-gpt-plbbl/config 保留(手动删:rm -rf ~/.config/cc-gpt-plbbl)。"
info "~/.claude 和官方 claude 未受影响。"
info "注:install 时对 claudish 的 patch(若有)未还原,备份在 claudish 包内 dist/index.js.ccgpt-bak,无害。"
