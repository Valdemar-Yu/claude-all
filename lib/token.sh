# lib/token.sh — 定义 _ccgp_resolve_token,把 token 填入 CCGP_TOKEN
# 优先级:$CCGP_TOKEN > 配置文件 token= > token_cmd= 外部命令 > cc-switch db 兼容
# 依赖 config.sh 已设好 CCGP_BASE_URL 和 ccgp_cfg_*。

_ccgp_resolve_token() {
  # 1. 已有 env
  [ -n "${CCGP_TOKEN:-}" ] && return 0
  # 2. 配置文件明文 token=
  if [ -n "${ccgp_cfg_token:-}" ]; then CCGP_TOKEN="$ccgp_cfg_token"; return 0; fi
  # 3. token_cmd:外部命令(op read / pass show / ...)。比明文更安全。
  if [ -n "${ccgp_cfg_token_cmd:-}" ]; then
    CCGP_TOKEN=$(sh -c "$ccgp_cfg_token_cmd" 2>/dev/null || true)
    [ -n "$CCGP_TOKEN" ] && return 0
  fi
  # 4. cc-switch db 兼容:按 base_url 匹配 website_url
  if [ -f "$HOME/.cc-switch/cc-switch.db" ] && command -v sqlite3 >/dev/null 2>&1; then
    CCGP_TOKEN=$(sqlite3 "$HOME/.cc-switch/cc-switch.db" \
      "SELECT json_extract(settings_config,'\$.env.ANTHROPIC_AUTH_TOKEN') \
       FROM providers WHERE app_type='claude' AND website_url='$CCGP_BASE_URL';" 2>/dev/null || true)
    [ -n "$CCGP_TOKEN" ] && return 0
  fi
  return 1
}
