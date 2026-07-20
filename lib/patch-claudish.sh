#!/usr/bin/env bash
# cc-gpt-plbbl — patch 全局 claudish:删掉它注入的 ANTHROPIC_API_KEY 占位符,只留 ANTHROPIC_AUTH_TOKEN。
# 根因见 docs/troubleshooting.md「Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY set」。
# 幂等;claudish 升级会还原,重跑一次本脚本即可。
set -euo pipefail

c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
info() { echo "$(c '1;36' '[cc-gpt-plbbl]') $*"; }
warn() { echo "$(c '1;33' '[cc-gpt-plbbl]') $*" >&2; }

command -v claudish >/dev/null 2>&1 || { warn "没找到 claudish,跳过 patch"; exit 0; }

# 解析 claudish bin 的真实路径(跨 symlink,兼容 macOS 无 readlink -f)
_BIN="$(command -v claudish)"
while [ -L "$_BIN" ]; do
  _DIR="$(cd -P "$(dirname "$_BIN")" >/dev/null 2>&1 && pwd)"
  _BIN="$(readlink "$_BIN")"
  case "$_BIN" in /*) : ;; *) _BIN="$_DIR/$_BIN" ;; esac
done
_DIST="$(cd -P "$(dirname "$_BIN")/../dist" >/dev/null 2>&1 && pwd)/index.js"

if [ ! -f "$_DIST" ]; then
  warn "没找到 claudish 的 dist/index.js(非标准安装?),跳过 patch"
  exit 0
fi

# 幂等:已 patch 过直接退
if grep -q 'cc-gpt-plbbl patch' "$_DIST"; then
  info "claudish 已 patch,跳过"
  exit 0
fi

# 特征行:claudish 注入的 ANTHROPIC_API_KEY 占位符
_LINE=$(grep -n 'ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || "sk-ant-api03-placeholder' "$_DIST" | head -1 | cut -d: -f1 || true)
if [ -z "${_LINE:-}" ]; then
  warn "没匹配到 claudish 占位符特征行(claudish 版本变了?),跳过 patch。功能不受影响,只是会有 Both-set 警告。"
  exit 0
fi

[ -f "$_DIST.ccgpt-bak" ] || cp "$_DIST" "$_DIST.ccgpt-bak"
_PATCH_LINE='      /* cc-gpt-plbbl patch: 仅保留 ANTHROPIC_AUTH_TOKEN,消除 Claude Code Both-set 警告(原行见 index.js.ccgpt-bak) */'
if sed --version >/dev/null 2>&1; then
  sed -i "${_LINE}s|.*|${_PATCH_LINE}|" "$_DIST"        # GNU sed (Linux)
else
  sed -i '' "${_LINE}s|.*|${_PATCH_LINE}|" "$_DIST"     # BSD sed (macOS)
fi

# 语法自检,挂了回滚
if command -v node >/dev/null 2>&1 && ! node --check "$_DIST" 2>/dev/null; then
  cp "$_DIST.ccgpt-bak" "$_DIST"
  warn "patch 后语法检查失败,已回滚"
  exit 1
fi
info "claudish patch 完成(dist/index.js 第 $_LINE 行)。claudish 升级后重跑本脚本。"
