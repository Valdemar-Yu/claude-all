# Statusline

claude-all 内置一份 Claude Code 单行状态栏，合并自 [`cc-statusline`](https://github.com/Valdemar-Yu/cc-statusline) 的 Claude/Kimi/GLM 支持，并加入可配置的 PLBBL 账号池周额度。

```text
🤖 gpt-5.6-sol ⚡xhigh  🧠 ██░░░░░░ 20% (80k/400k)  📅 周余 95% ↻6d10h  🕐 26-07-22 15:33
```

## 显示内容

- 模型名、1M 上下文标记和 `/effort` 档位。
- 上下文已用百分比、token 数和颜色进度条。
- Claude 官方 5h/7d 配额。
- Kimi Coding Plan 5h/7d 配额。
- Z.ai GLM Coding Plan 5h token/月 MCP 配额。
- 可选 PLBBL 账号池周剩余额度：多个账号归一化到 0–100%，并选最近的未来重置时间。
- 根据终端宽度降级的时钟。

上下文最大值优先采用 claude-all 根据当前模型和中转路由传入的有效上限；PLBBL 下 GPT-5.6 是 400k，GPT-5.4 是 1M。缺失或请求失败的分段会被省略，不会让状态栏脚本退出。`refreshInterval: 60` 使倒计时在空闲时继续更新。

## 安装

主安装器会把脚本放在：

```text
~/.local/share/claude-all/statusline/statusline.py
```

并配置 claude-all 管理的 `~/.claude-all` 和 `~/.claude-plbbl`。若要单独安装到当前 Claude Code 配置目录：

```bash
./statusline/install.sh
```

指定配置目录：

```bash
CLAUDE_CONFIG_DIR=~/.claude-glm ./statusline/install.sh
```

主安装器默认不改官方 `~/.claude` 和外部 wrapper 的 `~/.claude-glm`。需要同时配置时使用：

```bash
CCGP_STATUSLINE_GLOBAL=1 CCGP_SKIP_PROBE=1 ./install.sh
```

安装前的 `settings.json` 会备份为 `settings.json.claude-all-bak.<时间戳>`；JSON 中其他字段保持不变。

## PLBBL 账号池

公共仓库不内置账号池地址或访问口令。在 `~/.config/claude-all/config` 配置：

```text
statusline=yes
pool_usage_url=https://pool.example.com/api/codex/accounts
pool_keychain_service=pool.example.com statusline
pool_cookie_name=chatgpt_code_access
```

macOS Keychain 中的 service 必须与配置一致，account 使用当前系统用户名：

```bash
security add-generic-password -U -a "$USER" -s "pool.example.com statusline" -w
```

脚本只把口令作为 HTTPS 请求 Cookie 使用。缓存仅保存归一化百分比、账号计数和时间戳，不保存 Cookie、口令、邮箱、账号或 token。

账号池接口预期返回：

```json
{
  "items": [
    {
      "usage_status": "available",
      "usage": {
        "used_percent": 5,
        "resets_at": 1785261574
      }
    }
  ]
}
```

计算规则：对可读账号的 `100-used_percent` 求平均，得到 0–100% 总额度；在这些账号的 `resets_at` 中选择最近的未来时间。异常、需重新授权或 usage 不可读的账号不按满额处理。

## Kimi 与 GLM

Kimi 在 `ANTHROPIC_BASE_URL` 包含 `kimi` 时读取 `https://api.kimi.com/coding/v1/usages`。GLM 在 base URL 包含 `z.ai` 或 `open.bigmodel.cn` 时读取同 host 的 `/api/monitor/usage/quota/limit`。两者复用进程中已有 token，只放入请求头，不写入缓存。

GLM 显示：

- `TOKENS_LIMIT`：最紧张的 5h token 池。
- `TIME_LIMIT`：月 MCP 工具额度。

## claudish 覆盖

claudish 会为 Claude Code 生成临时 `--settings`，默认覆盖用户的 `statusLine`。claude-all 安装器会对 claudish 做一个幂等 patch，使下面两个环境变量生效：

```text
CLAUDISH_STATUSLINE_COMMAND
CLAUDISH_STATUSLINE_REFRESH
```

claudish 升级后若重新出现内置状态栏，运行：

```bash
bash ~/.local/share/claude-all/lib/patch-claudish.sh --statusline-only
```

## 缓存

默认目录：

```text
~/.cache/claude-all/statusline/
```

可通过 `CLAUDE_ALL_STATUSLINE_CACHE_DIR` 修改。目录权限为 `0700`；PLBBL 聚合缓存使用原子写入和 `0600` 权限。网络失败时显示带 `~` 的旧值；无成功缓存时省略对应分段。
