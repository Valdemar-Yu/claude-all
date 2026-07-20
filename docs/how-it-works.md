# 工作原理

claude-all 让 Claude Code(只懂 Anthropic `/v1/messages` 协议)用上第三方 GPT 订阅/中转站(只提供 OpenAI `/v1/chat/completions` 协议)。中间靠 **claudish** 做协议翻译。

## 三层结构

```
Claude Code  ─(Anthropic /v1/messages)─▶  claudish  ─(OpenAI /v1/chat/completions)─▶  plbbl / 第三方中转
                                          翻译 + 工具调用映射
```

- **Claude Code** 正常启动,以为自己在跟 Anthropic API 说话。
- **claudish** 本地代理:把 Anthropic 请求翻成 OpenAI 格式发出去,把 OpenAI 响应(含 `tool_calls`)翻回 Anthropic 格式给 Claude Code。
- **第三方中转** 你订阅的 GPT 服务(plbbl 等),OpenAI 协议。

## 关键设计

### 为什么用独立 config 目录
Claude Code 启动时读 `$CLAUDE_CONFIG_DIR/settings.json` 的 `env` 字段并强制应用。如果用官方 `~/.claude`(常被 CC Switch 之类工具写入了 `ANTHROPIC_BASE_URL=...`),这个 env 会**覆盖** claudish 设的本地代理地址,Claude Code 直连中转的 `/v1/messages` → 大多中转禁用该端点 → 403。

所以单实例(cc-gpt-plbbl)锁 `CLAUDE_CONFIG_DIR=~/.claude-plbbl`,settings.json 保持干净(无 `ANTHROPIC_*`)。claudish 的代理地址才不被覆盖。

### 为什么 symlink projects
独立 config 目录会让 session/memory 跟官方 claude 隔离。`projects` 软链到 `~/.claude/projects` 后,两边读写同一份 session 文件 → 可以 `cc-gpt-plbbl -r` resume 官方 claude 的历史,反之亦然。不想共享就配置 `share_projects=no`。

### 为什么默认 oai 不用 litellm
claudish 的 `litellm` provider 是通用兼容层,工具调用(tool_use)翻译偶发残缺,报 `missing required parameters`。`oai` 是一等公民 provider,工具调用翻译稳。详见 [troubleshooting.md](troubleshooting.md)。

### token 从哪来
优先级:env `$CCGP_TOKEN` > 配置文件 `token=` > `token_cmd=` 外部命令(op/pass)> CC Switch db 按 base_url 匹配。推荐 `token_cmd` 接密码管理器,token 不落盘。
