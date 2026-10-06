# claude-all

> 一个菜单管多个 Claude Code 后端；Baton 让官方 Claude 用 Opus 指挥、Codex 执行任务。每路后端独立隔离,session 与 memory 共享。
>
> **EN** — One menu for multiple Claude Code backends, plus Baton with official Claude Opus directing Codex execution. Each backend runs in its own isolated config; sessions and memory stay shared. Install: `curl -fsSL https://raw.githubusercontent.com/Valdemar-Yu/claude-all/main/install.sh | bash`

[安装](#安装) · [用法](#用法) · [Baton](#baton) · [隔离原理](#环境隔离原理) · [Statusline](#statusline) · [样例:接 plbbl](#样例接-plbbl-这类-openai-中转) · [排错](docs/troubleshooting.md)

## 解决什么问题

手上有好几路 Claude Code 后端:官方订阅、z.ai GLM、plbbl、DeepSeek、Kimi Coding Plan。每路的后端地址、协议、凭据都不一样,而 Claude Code 启动时只认一套环境变量和一个配置目录。直接混用会互相打架:

- 官方 `~/.claude` 常被 CC Switch 之类工具写入 `ANTHROPIC_BASE_URL`,切到别的后端时没清干净,请求发去错的地址
- 不同后端的 `.claude.json` 账户态、settings 互相覆盖
- OpenAI 协议的中转(plbbl)不兼容 Anthropic `/v1/messages`,直连就是 403

claude-all 给每路后端一个 **profile**(一个 env 文件),用方向键菜单切换。切换时先清掉上一路的残留变量,再载入新路的,后端之间彻底隔离;但 `projects`(session / memory)用 symlink 指向同一份,所以隔离不等于割裂——任何一路都能 resume 别处的对话。

## 它做什么

- 方向键菜单选后端,选中即进入对应 Claude Code 环境
- 三种 profile 类型覆盖所有后端形态:`cmd`(聚合现成启动命令)、`direct`(Anthropic 兼容 API 直连)、`claudish`(OpenAI 协议经 claudish 翻译)
- Add 向导交互式加新 API,凭据写进 600 权限的 env 文件
- 默认共享官方 `~/.claude/projects`,可 resume 历史 session
- 把踩过的坑封进库:claudish `oai` provider 绕开工具调用残缺、`.claude.json` 自动备份、CC Switch 污染防护
- 安装时把通过 `claude --version` 的 CLI 固化为隔离 runtime；全局 Claude 更新损坏时，五个环境仍使用上一个健康版本
- 安装时可选带上 Baton，让官方 Claude Opus 负责指挥，Codex CLI 负责执行

当前保留的环境及模板：

| profile | 协议/入口 | 模板 |
|---|---|---|
| `claude-plbbl` | OpenAI → claudish | [`profiles/claudish.env.example`](profiles/claudish.env.example) |
| `claude-glm` | Anthropic 兼容 | [`profiles/glm.env.example`](profiles/glm.env.example) |
| `claude` | 官方 Claude（隔离 CC Switch settings） | [`profiles/official.env.example`](profiles/official.env.example) |
| `deepseek` | OpenAI → claudish | [`profiles/deepseek.env.example`](profiles/deepseek.env.example) |
| `kimi-cc` | Anthropic 兼容 | [`profiles/kimi-cc.env.example`](profiles/kimi-cc.env.example) |

## 环境隔离原理

Claude Code 的全部运行状态都挂在 `$CLAUDE_CONFIG_DIR` 指向的目录下:`settings.json`、`.claude.json`(账户态)、`projects/`(每个工作目录的 session 与 memory)、`history.jsonl`。隔离的关键就是给不同后端不同的 config 目录,并在切换时清干净环境变量。

**一个 profile 就是一个 env 文件。** `~/.claude-all/profiles/<name>.env` 每个文件描述一路后端。claude-all 启动前做两件事:先 `unset` 掉 shell 里所有 `ANTHROPIC_*` / `CLAUDE_*` / `OPENAI_*` / `LITELLM_*` 和 `CLAUDE_CONFIG_DIR` 残留,让上一路留下的变量不串进来;再 `set -a; source <profile>.env` 把这一路的变量导出。这是隔离的第一道闸。

**三种 launch 路径。** source 完之后,按 profile 的 `CLAUDE_ALL_LAUNCH` 字段分三种方式进入 Claude Code:

| launch 类型 | 适用后端 | claude-all 做什么 |
|---|---|---|
| `cmd` | 已有自带隔离的 wrapper(claude / claude-glm / cc-gpt-plbbl) | 直接 exec 该 wrapper,隔离由 wrapper 自己负责 |
| `direct` | Anthropic 兼容 API(有 `/v1/messages`,如 z.ai) | 设 `CLAUDE_CONFIG_DIR=~/.claude-all` + `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN`,exec claude |
| `claudish` | 仅 OpenAI 协议的中转(plbbl 等) | 设 config 目录 + `OPENAI_*`,exec claudish 做协议翻译 |

`cmd` 类型适合那些你已经有独立 wrapper 的后端——claude-all 只负责"选哪个",不重复造隔离;`direct` / `claudish` 类型则由 claude-all 自己用 `~/.claude-all` 当 config 目录来隔离,凭据直接写在 profile 里。

**目录分工。** 几个路径各司其职,搞清楚就不乱:

| 路径 | 作用 |
|---|---|
| `~/.claude-all/` | claude-all 自己的 config 目录,也是 direct/claudish profile 的 `CLAUDE_CONFIG_DIR`;内含 `profiles/`、共享的 `projects` symlink |
| `~/.claude-all/profiles/*.env` | 每路后端一个 profile,600 权限 |
| `~/.local/share/claude-all/` | 安装产物,放 `bin/`、`lib/` |
| `~/.config/claude-all/config` | plbbl 单实例的参数(base_url / model / token),见样例小节 |

**为什么共享 projects 而不各自一份。** 完全隔离会让每路后端的 session 各自为政,resume 不回来。`~/.claude-all/projects` symlink 到 `~/.claude/projects`,所有后端读写同一份 session 文件,任何一路 `-r` 都能接着别处的对话。想要物理隔离就设 `share_projects=no`。

更细的协议翻译、为什么用 `oai` 不用 `litellm`、token 优先级见 [工作原理](docs/how-it-works.md)。

## 前置

- Claude Code CLI
- 官方 Claude 订阅，以及已经登录的 Codex CLI（Baton 模式需要）
- Python 3 + curl：模型列表发现、JSON 解析和安全 profile 写入
- Node.js + claudish:`npm i -g claudish`（>= 7.12），仅 OpenAI 协议 profile 需要
- macOS 或 Linux

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/Valdemar-Yu/claude-all/main/install.sh | bash
```

install 会验证当前 Claude CLI，原子写入 `~/.local/share/claude-all/runtime/bin/claude`，为官方 Claude 生成隔离 CC Switch 的 `direct` profile，并为 claude-glm / claude-plbbl 生成 `cmd` profile；已有的 deepseek、kimi-cc 等用户 profile 不覆盖。检测到 `codex` 时默认安装 Baton；没有 Codex 时跳过并提示，强制安装可设 `CCGP_BATON=yes`，关闭可设 `CCGP_BATON=no`。plbbl 单实例的参数交互式填（plbbl 用户回车用默认）。或先 clone 再 `./install.sh`。

### Claude 更新防护

近期 Claude Code 的 npm 包使用平台原生二进制和 `postinstall`。如果后台/手动 npm 更新在下载或解包时中断，可能同时留下三个症状：全局 `claude` 入口消失、npm bin 目录出现 `.claude-随机串`、平台二进制被截断且在 macOS 上以 `Killed: 9` 退出。所有 profile 最终都依赖 Claude Code，所以旧版 claude-all 会一起失效。

安装器现在会实际执行 `claude --version`，而不只检查命令名是否存在；验证通过后用硬链接（失败时复制）保留一个隔离 runtime，并用临时文件 + rename 原子刷新。所有 `direct`、`claudish` 和内置 `cmd` 路径启动前都会优先使用该 runtime。claude-all 默认设置 `DISABLE_AUTOUPDATER=1`；如确实需要在会话里允许后台更新，可显式设 `CLAUDE_ALL_ALLOW_AUTOUPDATE=1`。

推荐手动更新并验证：

```bash
npm install -g @anthropic-ai/claude-code@stable
claude --version
./install.sh                  # 验证并原子刷新隔离 runtime
claude-all doctor             # 检查 runtime、claudish 和全部 profile
```

若全局更新失败，已安装的隔离 runtime 不会被覆盖；修好全局 Claude 后重新运行安装器即可。

非交互(脚本 / CI):

```bash
curl -fsSL https://raw.githubusercontent.com/Valdemar-Yu/claude-all/main/install.sh \
  | CCGP_BASE_URL=https://plbbl.com/t/your-group CCGP_TOKEN=sk-xxx bash
```

## 用法

```bash
claude-all                  # 环境菜单；claude-plbbl 固定在第一项
claude-all list             # 列出全部 profile
claude-all doctor           # 检查 runtime、依赖和全部 profile
claude-all add              # 输入 base URL/key 后发现模型并配置三个角色
claude-all claude-plbbl -i  # 跳过菜单直接启动，参数透传
claude-all baton "实现一个任务"  # 官方 Claude Opus 指挥 Baton，Codex 执行
```

`add` 会读取该连接的 Models API，显示 `data[].id` 多选菜单，然后分别选择默认主模型、subagent 模型和 Agent Team teammate 模型。一个 API 仍只占一个环境菜单项；profile 保留多个候选主模型时，启动后会出现二级模型菜单，默认模型直接回车即可。Models API 列表只表示服务端声明模型存在，不代表 claude-all 已逐个发送推理请求。列表接口不可用时可手动输入模型 ID。

Anthropic 协议生成 `direct` profile；OpenAI 协议生成 `claudish` profile。删一个后端就是 `rm ~/.claude-all/profiles/<name>.env`。模板见 [`profiles/`](profiles/)。菜单交互思路借鉴 [WaldronZ/scripts](https://github.com/WaldronZ/scripts)。

## Baton

### Opus 指挥、Codex 执行

Baton 是同作者的开源协作工具。`claude-all baton "任务描述"` 用官方 Claude profile 启动并固定 `--model opus`，首条消息是 `/baton 任务描述`，再由 Baton 调度 Codex CLI 执行。不带任务运行 `claude-all baton` 时只启动 Opus 会话，随后在会话里输入 `/baton <任务描述>`；安装器只检测 PATH 上是否有 `codex` 命令，真正执行任务前需要已经登录的 Codex CLI。官方 profile 首次启动若提示未登录，请在会话里运行 `/login`。

安装器把上游 Baton vendor 到 `~/.local/share/claude-all/baton`，并优先复用它的安装脚本。默认 `CCGP_BATON=auto` 只在检测到 `codex` 时安装，`CCGP_BATON=yes` 强制安装，`CCGP_BATON=no` 完全跳过。Baton skill 的全局入口是 `~/.claude/skills/baton`，claude-all 管理的 `~/.claude-all`、`~/.claude-plbbl` 和 profile 声明的 config 目录只链接这个入口，所以各环境看到的是同一份 skill；用户已有的同名文件或目录会保留。菜单里的 Baton 项会追加在现有 profile 后面，`claude-plbbl` 仍是第一项。

项目运行 `baton init` 后，direct 环境直接使用项目级 Baton statusline。claudish 会用临时 `--settings` 覆盖项目设置，claude-all 因此把 claudish 的 statusline 命令交给分发入口，确认项目的设置确实指向受信任 Baton 脚本后再渲染 Codex 额度；普通项目和 `baton init --no-statusline` 项目只显示原有 statusline。分发器不执行项目设置里的命令字符串，只运行确认过的全局或 vendored Baton 脚本；额度数据来自 Baton 的缓存。

卸载 claude-all 只删除自己清单记录的 Baton 链接和 vendored 安装，用户自装的 Baton、council 以及项目里的 Baton 配置保留。项目若要移除自己的额度行，先在项目目录运行 `baton statusline uninstall`，再运行 `./uninstall.sh`。上游关系保持 vendor 边界，源 checkout 可用下面的命令同步并检查跟踪文件：

```bash
scripts/sync-baton.sh --check /path/to/Baton
```

上游仓库是 [Valdemar-Yu/Baton](https://github.com/Valdemar-Yu/Baton)，当前 commit 和补丁清单见 [`baton/UPSTREAM`](baton/UPSTREAM)。

## Agent 与 Agent Team 模型

新版 profile 用 Claude 的三个标准角色做稳定路由：`opus` 对应本次主模型，`sonnet` 对应默认 subagent，`haiku` 对应新建 Agent Team teammate。OpenAI 中转由 claudish 的 `model-opus/model-sonnet/model-haiku` 映射到实际 GPT 模型；不会传一个全局 explicit model，把所有请求压到同一后端。

这些值是默认值：custom agent 的 `model:` frontmatter、Agent tool 单次 model 参数和 leader 创建 teammate 时的 override 仍可覆盖。当前 claudish 7.12.1 的 `model-subagent` 虽然出现在 help/config 中，但实际请求路由没有接线，因此 claude-all 不依赖它。

## Statusline

claude-all 内置统一 Statusline，合并了 [`cc-statusline`](https://github.com/Valdemar-Yu/cc-statusline) 的 Claude 官方、Kimi Coding Plan、Z.ai GLM Coding Plan 配额，并支持可配置的 PLBBL 账号池周额度。

```text
🤖 gpt-5.6-sol ⚡xhigh  🧠 ██░░░░░░ 20% (80k/400k)  📅 周余 95% ↻6d10h  🕐 26-07-22 15:33
```

上下文最大值按当前模型和中转路由的有效上限显示；PLBBL 下 GPT-5.6 按 400k，GPT-5.4 按 1M。账号池额度会把多个账号的剩余额度归一化为 0–100%，并显示最近一次额度重置倒计时。账号池 URL 和 macOS Keychain service 从本地配置读取；仓库不保存访问口令、Cookie、账号或 token。主安装器配置 claude-all 管理的 config 目录；如需同时写入官方 Claude 和外部 GLM wrapper 的 settings：

```bash
CCGP_STATUSLINE_GLOBAL=1 CCGP_SKIP_PROBE=1 ./install.sh
```

完整字段、独立安装、缓存安全和 claudish 覆盖机制见 [`statusline/README.md`](statusline/README.md)。

## 样例:接 plbbl 这类 OpenAI 中转

plbbl 是 `claudish` 类型 profile 的典型代表——它只有 OpenAI 协议(`/v1/chat/completions`),禁用了 Anthropic `/v1/messages`,必须经 claudish 做协议翻译。这一节以它为例,展示最复杂的一类后端怎么接。同类的 OpenAI 协议中转照搬即可。

安装时填 plbbl 的 base_url 和 token 后,`cc-gpt-plbbl` wrapper 和 claude-all 里的 `claude-plbbl` profile 都可用:

```bash
cc-gpt-plbbl -i                                  # 交互(默认 gpt-5.6-sol + xhigh)
cc-gpt-plbbl "写个快排"                            # 单次
cc-gpt-plbbl -r                                  # resume 历史
cc-gpt-plbbl -i --model oai@gpt-5.3-codex-spark  # 切模型(更快)
cc-gpt-plbbl -i --effort high                    # 降档(xhigh 太慢时)
```

plbbl 单实例锁独立的 `CLAUDE_CONFIG_DIR=~/.claude-plbbl`,settings.json 保持干净(无 `ANTHROPIC_*`),claudish 的本地翻译代理才不被 CC Switch 写入的 base_url 覆盖。凭据解析优先级:env `$CCGP_TOKEN` > 配置 `token=` > `token_cmd=`(接密码管理器,token 不落盘)> CC Switch db 按 base_url 匹配。

plbbl 单实例的配置在 `~/.config/claude-all/config`(模板 [`templates/config.example`](templates/config.example)):

```
base_url=https://plbbl.com/t/<group>
model=oai@gpt-5.6-sol
effort=xhigh
provider=oai
share_projects=yes
statusline=yes
# pool_usage_url=https://pool.example.com/api/codex/accounts
# pool_keychain_service=pool.example.com statusline
pool_cookie_name=chatgpt_code_access
token=sk-xxx            # 或 token_cmd=op read 'op://Vault/plbbl/token'
```

为什么默认用 claudish 的 `oai` provider 而不是 `litellm`:`litellm` 通用层工具调用翻译偶发残缺,报 `missing required parameters`;`oai` 是一等公民 provider,稳定。完整模型矩阵和同类中转配置见 [已测模型](docs/providers.md),踩坑见 [排错](docs/troubleshooting.md)。

## 卸载

```bash
./uninstall.sh          # clone 仓库后,或:
curl -fsSL https://raw.githubusercontent.com/Valdemar-Yu/claude-all/main/uninstall.sh | bash
```

config 目录改名成 `.backup` 保留(session / memory 不丢),`~/.claude` 和官方 claude 不受影响。

## 依赖与边界

- claudish(npm)做协议翻译,只 claudish 类型 profile 需要。本项目不重造翻译层,封装最佳实践 + 踩坑库。
- 面向多后端并存的场景。若你只用一个 Anthropic 兼容后端,CC Switch 指过去即可,不需要本项目。

## 免责

第三方中转的合规性、稳定性、计费由服务方和你自行负责。本项目只是配置与隔离工具,不提供模型服务,也不对中转行为负责。

## License

MIT
