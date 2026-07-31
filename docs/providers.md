# 已测端点与模型

## plbbl.com(默认示例)

OpenAI 协议中转,按 group 路由。`/v1/messages` 禁用,只能 `/v1/chat/completions`。

### 实测模型(2026-07,oai provider)

| 模型 | 状态 | 备注 |
|---|---|---|
| `oai@gpt-5.6-sol` | 可用(默认) | 工具调用稳 |
| `oai@gpt-5.6` / `gpt-5.6-luna` / `gpt-5.6-terra` | 可用 | 5.6 系列变体 |
| `oai@gpt-5.3-codex-spark` | 可用 | 最快(1.3s / 2671 tps),codex 系 |
| `oai@gpt-5.4` | 可用 | 较慢(51 tps) |
| `oai@codex-auto-review` | 可用 | |
| `oai@gpt-5.2` / `gpt-5.2-chat-latest` | 不可用 | 报 400(Codex/ChatGPT-account 路由不接受) |

effort 档位:`none / minimal / low / medium / high / xhigh / max`,经 `--effort` 传。

### 配置

运行 `claude-all add`，选择 `openai`，输入 group base URL 和 token。向导从 `https://plbbl.com/t/<group>/v1/models` 读取候选模型，并分别配置主模型、subagent 和 Agent Team teammate。profile 中的实际模型 ID 不需要手写 `oai@` 前缀，启动时由 `CLAUDE_ALL_PROVIDER=oai` 统一补齐。

旧的 `~/.config/claude-all/config` 单实例仍使用：

```
base_url=https://plbbl.com/t/<你的-group>
model=oai@gpt-5.6-sol
provider=oai
```

## 其他同类中转

只要是 OpenAI 协议(`/v1/chat/completions`)的 GPT 中转,改 `base_url` + `token` + `model` 即可:

- 订阅制:base_url 带 `/t/<group>` 之类路径,token 是订阅 key。
- 镜像站:base_url 是站点域名,token 是站内 key,模型名按站内文档。

如果中转支持 `/v1/messages`(Anthropic 协议),其实不需要本项目——直接 CC Switch 指过去就行。本项目专治「只有 OpenAI 协议」的中转。

## 你的中转没列上面?

先运行 `claude-all add`。若服务端实现标准 `/v1/models`，向导直接显示模型多选；若返回 404、认证失败、非法 JSON 或空列表，向导会显示原因并进入手动输入。模型列表不是推理 probe：中转可能列出账户实际无权调用的模型，首次使用仍以真实请求结果为准。

欢迎提 PR 补充实测结果。
