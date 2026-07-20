# cc-gpt-plbbl

> 让 Claude Code 用上第三方 GPT 订阅 / 中转站(plbbl 等)。基于 claudish 做协议翻译,封装配置隔离、工具调用稳定性与历史共享。
>
> **EN** — Use Claude Code with third-party GPT relay/subscription services (plbbl etc.). claudish translates Anthropic↔OpenAI; this wraps config isolation, stable tool-calling, and session/memory sharing. Install: `curl -fsSL https://raw.githubusercontent.com/Valdemar-Yu/cc-gpt-plbbl/main/install.sh | bash`

[安装](#安装) · [用法](#用法) · [原理](docs/how-it-works.md) · [排错](docs/troubleshooting.md) · [已测模型](docs/providers.md)

## 解决什么问题

你买了 plbbl 这类第三方 GPT 订阅 / 中转,只有 OpenAI 协议(`/v1/chat/completions`),但想用 Claude Code(只懂 Anthropic `/v1/messages`)。直连、CC Switch 都不通——协议不兼容,且这类中转大多禁用了 `/v1/messages`。

cc-gpt-plbbl 在中间加一层 claudish 翻译,并把踩过的坑都封掉:

- 协议翻译(Anthropic ↔ OpenAI)
- 工具调用稳定(默认 claudish `oai` provider,绕开 `litellm` 的偶发残缺 tool call)
- config 隔离(不污染、也不被 CC Switch 污染官方 `~/.claude`)
- 历史共享(独立 dir + projects symlink,可 resume 官方 claude 的 session + memory)
- `.claude.json` 防护(install 自动 backup)

## 前置

- Claude Code CLI
- Node.js + claudish:`npm i -g claudish`(>= 7.12)
- macOS 或 Linux

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/Valdemar-Yu/cc-gpt-plbbl/main/install.sh | bash
```

交互式填 base_url / token / 模型(plbbl 用户回车用默认即可)。或先 clone 再 `./install.sh`。

非交互(脚本 / CI)用 env 预设:

```bash
curl -fsSL https://raw.githubusercontent.com/Valdemar-Yu/cc-gpt-plbbl/main/install.sh \
  | CCGP_BASE_URL=https://plbbl.com/t/your-group CCGP_TOKEN=sk-xxx bash
```

## 用法

```bash
cc-gpt-plbbl -i                                  # 交互(默认 gpt-5.6-sol + xhigh)
cc-gpt-plbbl "写个快排"                            # 单次
cc-gpt-plbbl -r                                  # resume 官方 claude 的历史 session
cc-gpt-plbbl -i --model oai@gpt-5.3-codex-spark  # 切模型(更快)
cc-gpt-plbbl -i --effort high                    # 降档(xhigh 太慢时)
```

## 配置

`~/.config/cc-gpt-plbbl/config`(模板见 [`templates/config.example`](templates/config.example)):

```
base_url=https://plbbl.com/t/<group>
model=oai@gpt-5.6-sol
effort=xhigh
provider=oai
share_projects=yes
token=sk-xxx            # 或更安全:token_cmd=op read 'op://Vault/plbbl/token'
```

token 优先级:env `$CCGP_TOKEN` > `token=` > `token_cmd=` > CC Switch db(按 base_url 匹配)。

## 原理 / 排错

- [工作原理](docs/how-it-works.md):协议翻译、config 隔离、symlink 共享、为什么用 oai
- [排错](docs/troubleshooting.md):403、`missing required parameters`、`.claude.json` 被冲、Both-set 警告、bash unbound
- [已测模型](docs/providers.md):plbbl 模型矩阵 + 同类中转怎么配

## 卸载

```bash
./uninstall.sh          # clone 仓库后,或:
curl -fsSL https://raw.githubusercontent.com/Valdemar-Yu/cc-gpt-plbbl/main/uninstall.sh | bash
```

config 目录会改名成 `.backup` 保留(session / memory 不丢),`~/.claude` 和官方 claude 不受影响。

## 依赖与边界

- 依赖 claudish(npm)做协议翻译。本项目不重造翻译层,只封装最佳实践 + 踩坑库。
- 面向「只有 OpenAI 协议」的第三方 GPT 中转。若你的中转支持 Anthropic 协议(`/v1/messages`),直接用 CC Switch 指过去即可,不需要本项目。

## 免责

第三方 GPT 中转的合规性、稳定性、计费由服务方和你自行负责。本项目只是配置工具,不提供模型服务,也不对中转行为负责。

## License

MIT
