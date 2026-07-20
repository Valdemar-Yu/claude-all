#!/usr/bin/env bash
# cc-gpt-plbbl 安装器。支持交互(./install.sh)和非交互(curl ... | bash,用 $CCGP_* 预设)。
set -euo pipefail

PREFIX="${CCGP_PREFIX:-$HOME/.local/share/cc-gpt-plbbl}"
BINDIR="${CCGP_BINDIR:-$HOME/.local/bin}"
CONFIG_FILE="$HOME/.config/cc-gpt-plbbl/config"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
info() { echo "$(c '1;36' '[cc-gpt-plbbl]') $*"; }
warn() { echo "$(c '1;33' '[cc-gpt-plbbl]') $*" >&2; }
die()  { echo "$(c '1;31' '[cc-gpt-plbbl]') $*" >&2; exit 1; }

# ---- 1. 依赖检查 ----
command -v claude  >/dev/null 2>&1 || die "没找到 claude CLI。先装 Claude Code。"
command -v claudish >/dev/null 2>&1 || die "没找到 claudish(协议翻译层)。装:npm i -g claudish (>=7.12)"
command -v sqlite3 >/dev/null 2>&1 || warn "没 sqlite3 → CC Switch 自动取 token 不可用,需手动配 token="

# ---- 1.5 patch claudish(消除 Claude Code Both-set 警告;幂等,失败不中断)----
bash "$SELF_DIR/lib/patch-claudish.sh" || warn "claudish patch 失败(不影响功能,仅启动有警告噪音)。可手动重跑:bash $PREFIX/lib/patch-claudish.sh"

# ---- 2. 读默认值(lib/config.sh)----
source "$SELF_DIR/lib/config.sh"

# 有 tty 才交互问;curl|bash 走默认 + $CCGP_* env
ask() {
  local prompt="$1" def="$2" val
  if [ -t 0 ]; then
    printf '  %s [%s]: ' "$prompt" "$def" >&2
    read -r val
    echo "${val:-$def}"
  else
    echo "$def"
  fi
}

if [ -t 0 ]; then
  info "配置(plbbl 用户直接回车):"
  A_BASE=$(ask "base_url"              "$CCGP_BASE_URL")
  A_MODEL=$(ask "model"                "$CCGP_MODEL")
  A_EFFORT=$(ask "effort"              "$CCGP_EFFORT")
  A_PROV=$(ask  "provider oai/litellm" "$CCGP_PROVIDER")
  A_SHARE=$(ask "共享官方 claude 历史? yes/no" "$CCGP_SHARE_PROJECTS")
else
  A_BASE="$CCGP_BASE_URL"; A_MODEL="$CCGP_MODEL"; A_EFFORT="$CCGP_EFFORT"
  A_PROV="$CCGP_PROVIDER"; A_SHARE="$CCGP_SHARE_PROJECTS"
fi

# ---- 3. backup ~/.claude/.claude.json(锁独立 dir 前的保险)----
if [ -f "$HOME/.claude/.claude.json" ]; then
  cp "$HOME/.claude/.claude.json" "$HOME/.claude/.claude.json.ccgpt-bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
fi

# ---- 4. 建 config 目录 + 干净 settings.json ----
CFGDIR="$CCGP_CONFIG_DIR"
mkdir -p "$CFGDIR"
[ -f "$CFGDIR/settings.json" ] || cp "$SELF_DIR/templates/settings.json" "$CFGDIR/settings.json"
# 复制官方 .claude.json 避免 onboarding(独立 dir 会另起一份状态)
[ -f "$HOME/.claude/.claude.json" ] && cp "$HOME/.claude/.claude.json" "$CFGDIR/.claude.json" 2>/dev/null || true
info "config 目录:$CFGDIR"

# ---- 5. symlink projects(共享 session+memory)----
if [ "$A_SHARE" = "yes" ] && [ -d "$HOME/.claude/projects" ]; then
  ln -sfn "$HOME/.claude/projects" "$CFGDIR/projects"
  info "symlink $CFGDIR/projects → ~/.claude/projects"
fi

# ---- 6. 装 wrapper + lib ----
mkdir -p "$PREFIX" "$BINDIR"
rm -rf "$PREFIX/bin" "$PREFIX/lib"
cp -r "$SELF_DIR/bin" "$SELF_DIR/lib" "$PREFIX/"
chmod +x "$PREFIX/bin/cc-gpt-plbbl" "$PREFIX/bin/claude-all"
if echo ":$PATH:" | grep -q ":$BINDIR:"; then
  ln -sfn "$PREFIX/bin/cc-gpt-plbbl" "$BINDIR/cc-gpt-plbbl"
  ln -sfn "$PREFIX/bin/claude-all" "$BINDIR/claude-all"
  info "入口:$BINDIR/cc-gpt-plbbl、$BINDIR/claude-all"
else
  warn "$BINDIR 不在 PATH。加:export PATH=\"$BINDIR:\$PATH\",或直接用 $PREFIX/bin/cc-gpt-plbbl"
fi

# ---- 6.5 claude-all:统一环境目录 + 内置 profile ----
ALLDIR="$HOME/.claude-all"
mkdir -p "$ALLDIR/profiles"
chmod 700 "$ALLDIR/profiles"
[ -f "$ALLDIR/settings.json" ] || cp "$SELF_DIR/templates/settings.json" "$ALLDIR/settings.json"
if [ ! -f "$ALLDIR/.claude.json" ] && [ -f "$HOME/.claude/.claude.json" ]; then
  cp "$HOME/.claude/.claude.json" "$ALLDIR/.claude.json" 2>/dev/null || true
fi
if [ -d "$HOME/.claude/projects" ]; then
  ln -sfn "$HOME/.claude/projects" "$ALLDIR/projects"
fi

# 内置 profile(cmd 型,聚合 ~/.local/bin 已有启动脚本;已存在不覆盖)
_mk_builtin() { # $1=名字 $2=命令 $3=label
  [ -f "$ALLDIR/profiles/$1.env" ] && return 0
  ( umask 077; cat > "$ALLDIR/profiles/$1.env" <<EOF
# $1 — claude-all 内置 profile(install 生成,可改可删:rm $ALLDIR/profiles/$1.env)
CLAUDE_ALL_LAUNCH=cmd
CLAUDE_ALL_CMD="$2"
CLAUDE_ALL_LABEL="$3"
EOF
  )
  chmod 600 "$ALLDIR/profiles/$1.env"
}
command -v claude       >/dev/null 2>&1 && _mk_builtin claude       claude       "cc-switch 当前源"
command -v claude-glm   >/dev/null 2>&1 && _mk_builtin claude-glm   claude-glm   "GLM (z.ai)"
command -v claude-plbbl >/dev/null 2>&1 && _mk_builtin claude-plbbl claude-plbbl "plbbl GPT (claudish)"
command -v claude-fugu  >/dev/null 2>&1 && _mk_builtin claude-fugu  claude-fugu  "Sakana Fugu (claudish)"
info "claude-all 环境目录:$ALLDIR(菜单选 [+ Add new API] 或 claude-all add 可加新 API)"

# ---- 7. 写配置文件 ----
mkdir -p "$(dirname "$CONFIG_FILE")"
cat > "$CONFIG_FILE" <<EOF
# cc-gpt-plbbl 配置(install.sh 生成)
base_url=$A_BASE
model=$A_MODEL
effort=$A_EFFORT
provider=$A_PROV
config_dir=$CFGDIR
share_projects=$A_SHARE
# token 留空则按优先级自动找(env > token= > token_cmd > cc-switch)。需要时取消注释:
# token=
# token_cmd=op read 'op://Vault/plbbl/token'
EOF
info "配置:$CONFIG_FILE"

# ---- 8. 自检:claudish probe ----
source "$SELF_DIR/lib/token.sh"
CCGP_BASE_URL="$A_BASE"
if _ccgp_resolve_token 2>/dev/null && [ -n "${CCGP_TOKEN:-}" ]; then
  case "$A_PROV" in oai) PENV="OPENAI" ;; *) PENV="LITELLM" ;; esac
  info "probe ${A_MODEL} ..."
  if env "${PENV}_BASE_URL=$A_BASE" "${PENV}_API_KEY=$CCGP_TOKEN" \
       claudish --probe "$A_MODEL" --probe-timeout 40 --json 2>/dev/null \
       | grep -q '"state"[[:space:]]*:[[:space:]]*"live"'; then
    info "$(c '1;32' '✓ probe 通过')"
  else
    warn "probe 未通过(token/网络/模型名)。装好了,可手动 cc-gpt-plbbl 测。"
  fi
else
  warn "没取到 token,跳过 probe。配 token 后再测。"
fi

echo
info "$(c '1;32' '完成')。跑:cc-gpt-plbbl -i   |   环境菜单:claude-all   |   切模型:cc-gpt-plbbl --model oai@gpt-5.3-codex-spark   |   排错:docs/troubleshooting.md"
