#!/usr/bin/env bash
# claude-all 安装器(cc-gpt-plbbl 为兼容入口)。支持本地 clone 与 curl | bash。
set -euo pipefail

CCGP_VERSION="3.3.0"
CCGP_REPO="${CCGP_REPO:-Valdemar-Yu/claude-all}"
CCGP_REF="${CCGP_REF:-main}"

c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
info() { echo "$(c '1;36' '[claude-all]') $*"; }
warn() { echo "$(c '1;33' '[claude-all]') $*" >&2; }
die()  { echo "$(c '1;31' '[claude-all]') $*" >&2; exit 1; }

# curl | bash 时只有当前脚本文本，没有同仓库的 lib/templates。先取完整归档再执行。
_SOURCE="${BASH_SOURCE[0]:-}"
SELF_DIR=""
if [ -n "$_SOURCE" ] && [ -f "$_SOURCE" ]; then
  SELF_DIR="$(cd "$(dirname "$_SOURCE")" >/dev/null 2>&1 && pwd)"
fi
if [ -z "$SELF_DIR" ] || [ ! -f "$SELF_DIR/lib/config.sh" ]; then
  command -v curl >/dev/null 2>&1 || die "curl | bash 安装需要 curl。也可 git clone 后运行 ./install.sh。"
  command -v tar  >/dev/null 2>&1 || die "curl | bash 安装需要 tar。也可 git clone 后运行 ./install.sh。"
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-all.XXXXXX")"
  trap 'rm -rf "$_tmp"' EXIT INT TERM
  _archive="${CCGP_ARCHIVE_URL:-https://github.com/$CCGP_REPO/archive/$CCGP_REF.tar.gz}"
  info "下载 $CCGP_REPO@$CCGP_REF ..."
  curl -fsSL "$_archive" | tar -xz -C "$_tmp"
  _root=""
  for _dir in "$_tmp"/*; do
    if [ -f "$_dir/install.sh" ] && [ -f "$_dir/lib/config.sh" ]; then _root="$_dir"; break; fi
  done
  [ -n "$_root" ] || die "下载的归档里没有完整安装文件。"
  CCGP_BOOTSTRAPPED=1 bash "$_root/install.sh" "$@"
  exit $?
fi

PREFIX="${CCGP_PREFIX:-$HOME/.local/share/claude-all}"
BINDIR="${CCGP_BINDIR:-$HOME/.local/bin}"
CONFIG_FILE="${CCGP_CONFIG_FILE:-$HOME/.config/claude-all/config}"
ALLDIR="${CLAUDE_ALL_HOME:-$HOME/.claude-all}"
CLAUDE_ALL_BATON_PREFIX="$PREFIX"
_CLAUDE_CLI_LIB="$SELF_DIR/lib/claude-cli.sh"
[ -f "$_CLAUDE_CLI_LIB" ] || die "安装包缺少 lib/claude-cli.sh"
# shellcheck source=/dev/null
source "$_CLAUDE_CLI_LIB"
# shellcheck source=/dev/null
source "$SELF_DIR/lib/baton.sh"
_claude_all_baton_init

# ---- 1.5 迁移 cc-gpt-plbbl 旧命名空间路径(幂等) ----
if [ -d "$HOME/.local/share/cc-gpt-plbbl" ]; then
  if [ -e "$PREFIX" ]; then
    rm -rf "$HOME/.local/share/cc-gpt-plbbl"
    info "清理旧安装目录 ~/.local/share/cc-gpt-plbbl(新目录 $PREFIX 已在)"
  else
    mv "$HOME/.local/share/cc-gpt-plbbl" "$PREFIX"
    info "迁移安装目录 → $PREFIX"
  fi
fi
if [ -d "$HOME/.claude-ccgpt" ] && [ ! -e "$HOME/.claude-plbbl" ]; then
  mv "$HOME/.claude-ccgpt" "$HOME/.claude-plbbl"
  info "迁移单实例目录 ~/.claude-ccgpt → ~/.claude-plbbl"
elif [ -d "$HOME/.claude-ccgpt" ]; then
  warn "~/.claude-ccgpt 与 ~/.claude-plbbl 都在,保留后者;前者确认无用后手动删"
fi
if [ -d "$HOME/.config/cc-gpt-plbbl" ]; then
  if [ -e "$HOME/.config/claude-all" ]; then
    rm -rf "$HOME/.config/cc-gpt-plbbl"
    info "清理旧配置目录 ~/.config/cc-gpt-plbbl(新目录已在)"
  else
    mv "$HOME/.config/cc-gpt-plbbl" "$HOME/.config/claude-all"
    info "迁移配置目录 → ~/.config/claude-all"
  fi
fi
if [ -f "$CONFIG_FILE" ] && grep -q '^config_dir=.*\.claude-ccgpt' "$CONFIG_FILE"; then
  if sed --version >/dev/null 2>&1; then
    sed -i 's|^config_dir=.*|config_dir='"$HOME"'/.claude-plbbl|' "$CONFIG_FILE"
  else
    sed -i '' 's|^config_dir=.*|config_dir='"$HOME"'/.claude-plbbl|' "$CONFIG_FILE"
  fi
  info "更新 config_dir → ~/.claude-plbbl"
fi

# 迁移后,把指向旧安装目录(cc-gpt-plbbl)的入口 symlink 重指向新目录(claude-all)
_relink_entry() {
  local entry="$1" cur
  [ -L "$entry" ] || return 0
  cur="$(readlink "$entry")"
  case "$cur" in
    */cc-gpt-plbbl/bin/*) ln -sfn "${cur/cc-gpt-plbbl/claude-all}" "$entry" && info "重链 $(basename "$entry") → ${cur/cc-gpt-plbbl/claude-all}" ;;
  esac
}
_relink_entry "$BINDIR/cc-gpt-plbbl"
_relink_entry "$BINDIR/claude-all"

# ---- 1. 依赖检查 ----
_claude_source="$(command -v claude 2>/dev/null || true)"
[ -n "$_claude_source" ] || { _claude_all_claude_error; die "没找到 claude CLI。"; }
_claude_version="$(_claude_all_claude_version "$_claude_source" 2>/dev/null || true)"
[ -n "$_claude_version" ] || { _claude_all_claude_error; die "当前 claude CLI 健康检查失败。"; }
command -v claudish >/dev/null 2>&1 || die "没找到 claudish。安装:npm i -g claudish@latest (要求 >=7.12)"
command -v python3  >/dev/null 2>&1 || die "没找到 python3。statusline、settings 合并、模型列表解析和安全 profile 写入需要 Python 3。"
command -v curl     >/dev/null 2>&1 || die "没找到 curl。模型列表发现需要 curl。"
command -v sqlite3  >/dev/null 2>&1 || warn "没找到 sqlite3：无法从 CC Switch 自动读取 token，需配置 CCGP_TOKEN/token/token_cmd。"

_BATON_ENABLED=0
_BATON_READY=0
_BATON_REASON=""
case "${CCGP_BATON:-auto}" in
  no)  info "按 CCGP_BATON=no 跳过 Baton 安装" ;;
  yes) _BATON_ENABLED=1
       command -v codex >/dev/null 2>&1 || warn "未找到 codex CLI；仍安装 Baton，使用前请安装并登录 Codex。" ;;
  auto)
    if command -v codex >/dev/null 2>&1; then
      _BATON_ENABLED=1
    else
      warn "未找到 codex CLI，跳过 Baton 安装；需要时设置 CCGP_BATON=yes 并安装/登录 Codex。"
    fi
    ;;
  *) die "CCGP_BATON 只能是 yes、no 或 auto" ;;
esac

_claudish_version="$(claudish --version 2>/dev/null || true)"
if [[ "$_claudish_version" =~ ([0-9]+)\.([0-9]+) ]]; then
  _cv_major="${BASH_REMATCH[1]}"; _cv_minor="${BASH_REMATCH[2]}"
  if [ "$_cv_major" -lt 7 ] || { [ "$_cv_major" -eq 7 ] && [ "$_cv_minor" -lt 12 ]; }; then
    die "claudish $_cv_major.$_cv_minor 过旧，要求 >=7.12。运行:npm i -g claudish@latest"
  fi
else
  warn "无法识别 claudish 版本($_claudish_version)，继续安装；若启动失败先升级到 >=7.12。"
fi

# claudish 会强制生成临时 statusLine；默认 patch 使其接受 claude-all 的覆盖变量。
_patch_args=(--statusline-only)
[ "${CCGP_PATCH_CLAUDISH:-0}" = "1" ] && _patch_args=(--auth)
bash "$SELF_DIR/lib/patch-claudish.sh" ${_patch_args[@]+"${_patch_args[@]}"} \
  || warn "claudish patch 失败；direct profile 仍可用，claudish profile 会显示其内置状态栏。"

# ---- 2. 读默认值 ----
source "$SELF_DIR/lib/config.sh"

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
  info "配置 plbbl/OpenAI 中转(凭据不会在此处询问，沿用环境、配置或 CC Switch):"
  A_BASE=$(ask "base_url"              "$CCGP_BASE_URL")
  A_MODEL=$(ask "model"                "$CCGP_MODEL")
  A_EFFORT=$(ask "effort"              "$CCGP_EFFORT")
  A_PROV=$(ask  "provider oai/litellm" "$CCGP_PROVIDER")
  A_SHARE=$(ask "共享官方 claude 历史? yes/no" "$CCGP_SHARE_PROJECTS")
else
  A_BASE="$CCGP_BASE_URL"; A_MODEL="$CCGP_MODEL"; A_EFFORT="$CCGP_EFFORT"
  A_PROV="$CCGP_PROVIDER"; A_SHARE="$CCGP_SHARE_PROJECTS"
fi
case "$A_PROV" in oai|litellm) : ;; *) die "provider 只能是 oai 或 litellm" ;; esac
case "$A_SHARE" in yes|no) : ;; *) die "share_projects 只能是 yes 或 no" ;; esac
case "$CCGP_STATUSLINE" in yes|no) : ;; *) die "statusline 只能是 yes 或 no" ;; esac

# ---- 3. 备份官方账户状态 ----
if [ -f "$HOME/.claude/.claude.json" ]; then
  cp "$HOME/.claude/.claude.json" "$HOME/.claude/.claude.json.claude-all-bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
fi

# ---- 4. 创建隔离配置目录 ----
umask 077
CFGDIR="$CCGP_CONFIG_DIR"
mkdir -p "$CFGDIR"
chmod 700 "$CFGDIR" 2>/dev/null || true
[ -f "$CFGDIR/settings.json" ] || cp "$SELF_DIR/templates/settings.json" "$CFGDIR/settings.json"
chmod 600 "$CFGDIR/settings.json" 2>/dev/null || true
printf 'managed-by=claude-all\nversion=%s\n' "$CCGP_VERSION" > "$CFGDIR/.claude-all-managed"
chmod 600 "$CFGDIR/.claude-all-managed" 2>/dev/null || true
if [ -f "$HOME/.claude/.claude.json" ]; then
  cp "$HOME/.claude/.claude.json" "$CFGDIR/.claude.json" 2>/dev/null || true
  chmod 600 "$CFGDIR/.claude.json" 2>/dev/null || true
fi
info "单环境配置:$CFGDIR"

if [ "$A_SHARE" = "yes" ] && [ -d "$HOME/.claude/projects" ]; then
  ln -sfn "$HOME/.claude/projects" "$CFGDIR/projects"
  info "共享历史:$CFGDIR/projects → ~/.claude/projects"
elif [ "$A_SHARE" = "no" ] && [ -L "$CFGDIR/projects" ]; then
  rm -f "$CFGDIR/projects"
fi

# ---- 5. 安装 wrapper 与入口 ----
mkdir -p "$PREFIX" "$BINDIR"
chmod 700 "$PREFIX" 2>/dev/null || true
rm -rf "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/statusline"
cp -R "$SELF_DIR/bin" "$SELF_DIR/lib" "$SELF_DIR/statusline" "$PREFIX/"
if [ "$_BATON_ENABLED" -eq 1 ]; then
  rm -rf "$PREFIX/baton"
  cp -R "$SELF_DIR/baton" "$PREFIX/"
fi
chmod +x "$PREFIX/bin/cc-gpt-plbbl" "$PREFIX/bin/claude-all" \
  "$PREFIX/statusline/statusline.py" "$PREFIX/statusline/install.sh"
_runtime_version="$(_claude_all_install_runtime "$_claude_source" "$PREFIX/runtime/bin")" \
  || die "无法安装健康的隔离 Claude runtime；原 runtime（如有）已保留。"
info "隔离 runtime:$PREFIX/runtime/bin/claude ($_runtime_version)"

_link_entry() {
  local name="$1" target="$2" dest="$BINDIR/$1" current
  if [ -L "$dest" ]; then
    current="$(readlink "$dest")"
    case "$current" in "$PREFIX"/*) ln -sfn "$target" "$dest"; return 0 ;; esac
    warn "保留已有链接:$dest → $current"
    return 1
  fi
  if [ -e "$dest" ]; then
    warn "保留已有文件:$dest"
    return 1
  fi
  ln -s "$target" "$dest"
}
_link_entry cc-gpt-plbbl "$PREFIX/bin/cc-gpt-plbbl" || true
_link_entry claude-plbbl "$PREFIX/bin/cc-gpt-plbbl" || true
_link_entry claude-all "$PREFIX/bin/claude-all" || true
if echo ":$PATH:" | grep -q ":$BINDIR:"; then
  info "入口:$BINDIR/claude-all、$BINDIR/claude-plbbl、$BINDIR/cc-gpt-plbbl"
else
  warn "$BINDIR 不在 PATH。添加:export PATH=\"$BINDIR:\$PATH\""
fi

# ---- 6. claude-all 状态目录与内置 profiles ----
mkdir -p "$ALLDIR/profiles"
chmod 700 "$ALLDIR" "$ALLDIR/profiles" 2>/dev/null || true
[ -f "$ALLDIR/settings.json" ] || cp "$SELF_DIR/templates/settings.json" "$ALLDIR/settings.json"
chmod 600 "$ALLDIR/settings.json" 2>/dev/null || true
if [ ! -f "$ALLDIR/.claude.json" ] && [ -f "$HOME/.claude/.claude.json" ]; then
  cp "$HOME/.claude/.claude.json" "$ALLDIR/.claude.json" 2>/dev/null || true
  chmod 600 "$ALLDIR/.claude.json" 2>/dev/null || true
fi
if [ -d "$HOME/.claude/projects" ]; then
  ln -sfn "$HOME/.claude/projects" "$ALLDIR/projects"
fi

# ---- 6.1 统一 statusline ----
# shellcheck source=/dev/null
source "$PREFIX/lib/statusline.sh"
_statusline_command="$(_claude_all_statusline_command "$PREFIX")"
if [ "$CCGP_STATUSLINE" = yes ]; then
  _claude_all_statusline_install "$CFGDIR" "$_statusline_command"
  _claude_all_statusline_install "$ALLDIR" "$_statusline_command"
  if [ "${CCGP_STATUSLINE_GLOBAL:-0}" = "1" ]; then
    _claude_all_statusline_install "$HOME/.claude" "$_statusline_command"
    [ -d "$HOME/.claude-glm" ] && _claude_all_statusline_install "$HOME/.claude-glm" "$_statusline_command"
  fi
  info "statusline:$PREFIX/statusline/statusline.py (60s 刷新)"
else
  _claude_all_statusline_remove "$CFGDIR" "$_statusline_command"
  _claude_all_statusline_remove "$ALLDIR" "$_statusline_command"
  if [ "${CCGP_STATUSLINE_GLOBAL:-0}" = "1" ]; then
    _claude_all_statusline_remove "$HOME/.claude" "$_statusline_command"
    [ -d "$HOME/.claude-glm" ] && _claude_all_statusline_remove "$HOME/.claude-glm" "$_statusline_command"
  fi
fi

_mk_builtin() {
  local name="$1" cmd="$2" label="$3"
  [ -f "$ALLDIR/profiles/$name.env" ] && return 0
  (
    umask 077
    printf '# %s — claude-all 内置 profile(可改可删)\n' "$name"
    printf 'CLAUDE_ALL_LAUNCH=cmd\n'
    printf 'CLAUDE_ALL_CMD=%q\n' "$cmd"
    printf 'CLAUDE_ALL_LABEL=%q\n' "$label"
  ) > "$ALLDIR/profiles/$name.env"
  chmod 600 "$ALLDIR/profiles/$name.env"
}
_mk_official() {
  local profile="$ALLDIR/profiles/claude.env"
  [ -f "$profile" ] && return 0
  (
    umask 077
    printf '# claude — claude-all 内置 profile(可改可删)\n'
    printf 'CLAUDE_ALL_LAUNCH=direct\n'
    printf 'CLAUDE_ALL_LABEL=%q\n' "Claude 官方 (隔离 CC Switch)"
    printf 'CLAUDE_CONFIG_DIR=%q\n' "$ALLDIR"
  ) > "$profile"
  chmod 600 "$profile"
}

_update_official() {
  local profile="$ALLDIR/profiles/claude.env"
  [ -f "$profile" ] && grep -q 'claude-all 内置 profile' "$profile" || return 0
  PROFILE="$profile" CONFIG_DIR="$ALLDIR" LABEL="Claude 官方 (隔离 CC Switch)" python3 - <<'PY'
import os, re, shlex
path = os.environ["PROFILE"]
with open(path, encoding="utf-8", errors="surrogateescape") as handle:
    text = handle.read()
text = re.sub(r"^CLAUDE_ALL_LAUNCH=.*$", "CLAUDE_ALL_LAUNCH=direct", text, count=1, flags=re.M)
text = re.sub(r"^CLAUDE_ALL_CMD=.*\n?", "", text, flags=re.M)
label_line = "CLAUDE_ALL_LABEL=" + shlex.quote(os.environ["LABEL"])
if re.search(r"^CLAUDE_ALL_LABEL=", text, flags=re.M):
    text = re.sub(r"^CLAUDE_ALL_LABEL=.*$", label_line, text, count=1, flags=re.M)
else:
    text = text.rstrip("\n") + "\n" + label_line + "\n"
config_line = "CLAUDE_CONFIG_DIR=" + shlex.quote(os.environ["CONFIG_DIR"])
if re.search(r"^CLAUDE_CONFIG_DIR=", text, flags=re.M):
    text = re.sub(r"^CLAUDE_CONFIG_DIR=.*$", config_line, text, count=1, flags=re.M)
else:
    text = text.rstrip("\n") + "\n" + config_line + "\n"
with open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
    handle.write(text)
PY
  chmod 600 "$profile"
}

_update_builtin_cmd() {
  local name="$1" command="$2" profile="$ALLDIR/profiles/$1.env"
  [ -f "$profile" ] && grep -q 'claude-all 内置 profile' "$profile" || return 0
  PROFILE="$profile" COMMAND="$command" python3 - <<'PY'
import os, re, shlex
path = os.environ["PROFILE"]
with open(path, encoding="utf-8", errors="surrogateescape") as handle:
    text = handle.read()
line = "CLAUDE_ALL_CMD=" + shlex.quote(os.environ["COMMAND"])
text, count = re.subn(r"^CLAUDE_ALL_CMD=.*$", line, text, count=1, flags=re.M)
if count:
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
        handle.write(text)
PY
  chmod 600 "$profile"
}

_mk_official
_update_official
if command -v claude-glm >/dev/null 2>&1; then
  _glm_cmd="$(command -v claude-glm)"
  _mk_builtin claude-glm "$_glm_cmd" "GLM (z.ai)"
  _update_builtin_cmd claude-glm "$_glm_cmd"
fi
_plbbl_cmd="$BINDIR/cc-gpt-plbbl"
_mk_builtin claude-plbbl "$_plbbl_cmd" "plbbl GPT (claudish)"
_update_builtin_cmd claude-plbbl "$_plbbl_cmd"
info "多环境配置:${ALLDIR}；用户自建 profiles 不覆盖"

if [ "$_BATON_ENABLED" -eq 1 ]; then
  if _baton_install_error="$(_claude_all_baton_install 2>&1)"; then
    if _claude_all_baton_link_managed_configs "$ALLDIR" "$CFGDIR" "$ALLDIR/profiles"; then
      _BATON_READY=1
      info "Baton：skill 与受管 config 链接已就绪"
      if ! _baton_path_present "$CLAUDE_ALL_BATON_GLOBAL_COUNCIL"; then
        info "council 未安装；需要时运行 $PREFIX/baton/install.sh --council（会联网 clone 第三方 council.skill）"
      fi
    else
      _BATON_REASON="受管 config 链接失败"
    fi
  else
    _BATON_REASON="${_baton_install_error:-skill 安装失败}"
  fi
  if [ "$_BATON_READY" -eq 0 ]; then
    if [ "${CCGP_BATON:-auto}" = yes ]; then
      [ -n "${_BATON_REASON}" ] && warn "Baton：${_BATON_REASON}"
      die "Baton 安装失败。请检查 ~/.claude/skills/baton 与 ~/.local/bin/baton 的冲突提示。"
    fi
    warn "Baton 未就绪：${_BATON_REASON}；核心 claude-all 安装继续。需要时设置 CCGP_BATON=yes 重试。"
  fi
fi

# ---- 7. 写单环境配置，保留已有 token/token_cmd ----
mkdir -p "$(dirname "$CONFIG_FILE")"
chmod 700 "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
{
  printf '# claude-all 配置(install.sh 生成)\n'
  printf 'base_url=%s\n' "$A_BASE"
  printf 'model=%s\n' "$A_MODEL"
  printf 'effort=%s\n' "$A_EFFORT"
  printf 'provider=%s\n' "$A_PROV"
  printf 'config_dir=%s\n' "$CFGDIR"
  printf 'share_projects=%s\n' "$A_SHARE"
  printf 'statusline=%s\n' "$CCGP_STATUSLINE"
  if [ -n "$CCGP_POOL_USAGE_URL" ]; then printf 'pool_usage_url=%s\n' "$CCGP_POOL_USAGE_URL"; else printf '# pool_usage_url=\n'; fi
  if [ -n "$CCGP_POOL_KEYCHAIN_SERVICE" ]; then printf 'pool_keychain_service=%s\n' "$CCGP_POOL_KEYCHAIN_SERVICE"; else printf '# pool_keychain_service=\n'; fi
  printf 'pool_cookie_name=%s\n' "$CCGP_POOL_COOKIE_NAME"
  if [ -n "${ccgp_cfg_token:-}" ]; then printf 'token=%s\n' "$ccgp_cfg_token"; else printf '# token=\n'; fi
  if [ -n "${ccgp_cfg_token_cmd:-}" ]; then printf 'token_cmd=%s\n' "$ccgp_cfg_token_cmd"; else printf "# token_cmd=op read 'op://Vault/plbbl/token'\n"; fi
} > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
info "单环境参数:$CONFIG_FILE"

# ---- 8. 可用凭据时 probe ----
source "$SELF_DIR/lib/token.sh"
CCGP_BASE_URL="$A_BASE"
if [ "${CCGP_SKIP_PROBE:-0}" = "1" ]; then
  info "按 CCGP_SKIP_PROBE=1 跳过模型 probe"
elif _ccgp_resolve_token 2>/dev/null && [ -n "${CCGP_TOKEN:-}" ]; then
  case "$A_PROV" in oai) PENV="OPENAI" ;; *) PENV="LITELLM" ;; esac
  info "probe $A_MODEL ..."
  if env "${PENV}_BASE_URL=$A_BASE" "${PENV}_API_KEY=$CCGP_TOKEN" \
       claudish --probe "$A_MODEL" --probe-timeout 40 --json 2>/dev/null \
       | grep -q '"state"[[:space:]]*:[[:space:]]*"live"'; then
    info "$(c '1;32' 'probe 通过')"
  else
    warn "probe 未通过(token/网络/模型名)。安装已完成，可稍后用 claude-plbbl 验证。"
  fi
else
  warn "没取到 token，跳过 probe。可配置 CCGP_TOKEN、token=、token_cmd= 或 CC Switch provider。"
fi

echo
info "$(c '1;32' "安装完成 v$CCGP_VERSION")。主入口:claude-all；兼容入口:claude-plbbl / cc-gpt-plbbl"
if [ "$_BATON_ENABLED" -eq 1 ] && [ "$_BATON_READY" -eq 0 ]; then
  warn "Baton 未就绪：${_BATON_REASON}"
fi
