# lib/config.sh — 加载 claude-all 单实例(plbbl)配置
# 优先级:环境变量($CCGP_*) > 配置文件 > 内置默认(plbbl 为示例)
# 被 bin/cc-gpt-plbbl 和 install.sh source。

: "${CCGP_CONFIG_FILE:=$HOME/.config/claude-all/config}"

# 读配置文件 key=value(忽略注释/空行)到 ccgp_cfg_*
_ccgp_load_file() {
  ccgp_cfg_base_url=""; ccgp_cfg_model=""; ccgp_cfg_effort=""
  ccgp_cfg_provider=""; ccgp_cfg_config_dir=""; ccgp_cfg_share_projects=""
  ccgp_cfg_token=""; ccgp_cfg_token_cmd=""
  [ -f "$CCGP_CONFIG_FILE" ] || return 0
  local k v
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      ''|\#*) continue ;;
      base_url)       ccgp_cfg_base_url="$v" ;;
      model)          ccgp_cfg_model="$v" ;;
      effort)         ccgp_cfg_effort="$v" ;;
      provider)       ccgp_cfg_provider="$v" ;;
      config_dir)     ccgp_cfg_config_dir="$v" ;;
      share_projects) ccgp_cfg_share_projects="$v" ;;
      token)          ccgp_cfg_token="$v" ;;
      token_cmd)      ccgp_cfg_token_cmd="$v" ;;
    esac
  done < "$CCGP_CONFIG_FILE"
}
_ccgp_load_file

# 解析:env > 配置文件 > 默认
CCGP_BASE_URL="${CCGP_BASE_URL:-${ccgp_cfg_base_url:-https://plbbl.com/t/<your-group>}}"
CCGP_MODEL="${CCGP_MODEL:-${ccgp_cfg_model:-oai@gpt-5.6-sol}}"
CCGP_EFFORT="${CCGP_EFFORT:-${ccgp_cfg_effort:-xhigh}}"
CCGP_PROVIDER="${CCGP_PROVIDER:-${ccgp_cfg_provider:-oai}}"
CCGP_CONFIG_DIR="${CCGP_CONFIG_DIR:-${ccgp_cfg_config_dir:-$HOME/.claude-plbbl}}"
CCGP_SHARE_PROJECTS="${CCGP_SHARE_PROJECTS:-${ccgp_cfg_share_projects:-yes}}"
