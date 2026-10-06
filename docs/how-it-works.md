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

### 三种模型角色如何路由

`claude-all add` 保存主模型、subagent、Agent Team teammate 三个默认值。Claude Code 侧分别请求 `opus`、`sonnet`、`haiku`：

- Anthropic 直连把三个 alias 映射到服务端实际 model ID；
- OpenAI 中转把三个请求交给 claudish 的 `model-opus`、`model-sonnet`、`model-haiku`；
- profile 通过本次 `--settings` 设置 `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` 和 `teammateDefaultModel=haiku`，不修改用户全局 settings。

不能把 claudish 的单一 `--model` 当作主模型默认值：explicit primary 会覆盖角色判断，让主会话、subagent 和 teammate 全部落到同一后端。claudish 7.12.1 的 `model-subagent` 参数也没有接入实际请求路由，所以新版不使用它。

### Models API 与密钥

向导从 `<base>/v1/models`（base 已以 `/v1` 结尾时用 `<base>/models`）读取 `data[].id`，Anthropic 列表支持 `after_id` 分页。API key 通过 curl stdin header 传递，不进入进程 argv、日志或临时文件。列表调用失败不会阻塞配置，改为手动输入 model ID。

### Statusline 如何跨三种 launch 生效

`direct` profile 从对应 `$CLAUDE_CONFIG_DIR/settings.json` 读取统一脚本。`cmd` profile 由外部 wrapper 自己的 config 目录读取；安装时可用 `CCGP_STATUSLINE_GLOBAL=1` 同时配置 `~/.claude` 和 `~/.claude-glm`。`claudish` 会生成临时 `--settings` 并覆盖用户 statusLine，所以 claude-all 给 claudish 加一个幂等 patch，使 `CLAUDISH_STATUSLINE_COMMAND` 和 `CLAUDISH_STATUSLINE_REFRESH` 能替换它的内置命令。

账号池口令不经过 profile env，也不写进 settings。macOS 上由状态栏进程按配置的 service 从 Keychain 读取，只用于 HTTPS Cookie。

### Baton 的安装和跨环境链接

安装器把上游 Baton 的 `skills/baton/`、`council/` 和安装脚本复制到 `$PREFIX/baton`。检测到 Codex CLI 时，默认 `CCGP_BATON=auto` 安装；`CCGP_BATON=yes` 强制安装，`CCGP_BATON=no` 跳过。Baton 自己的安装逻辑负责创建 `~/.claude/skills/baton` 和 `~/.local/bin/baton`，claude-all 只在自己的 manifest 中记录由自己创建的链接。

`~/.claude-all`、`CCGP_CONFIG_DIR` 默认的 `~/.claude-plbbl` 和 profile 中声明的 `CLAUDE_CONFIG_DIR` 都只建立 `skills/baton` 到 `~/.claude/skills/baton` 的软链，council 已安装时同理。这样每个受管环境通过同一个全局入口看到实际使用的 Baton，用户已有普通目录、软链和外部 wrapper 不会被替换。每次 direct 或 claudish profile 启动时会再次幂等补链，覆盖后来新增的 profile。

`claude-all baton` 只使用官方 `claude.env` profile，并显式传 `--model opus`。它快速检查 Baton CLI、Codex CLI 和官方 profile，不启动耗时 doctor。菜单检测到可用 Baton 时追加同一个入口。doctor 把 Baton 当可选组件，报告 CLI 来源、Codex 和各受管 config 的链接，缺失不会改变原有失败计数。

claudish 的临时 `--settings` 优先级高于项目 `.claude/settings.local.json`，因此 claudish profile 的 `CLAUDISH_STATUSLINE_COMMAND` 指向 claude-all 的分发器。分发器只把项目 settings 当作 Baton 开关，解析后确认脚本 realpath 是全局或 vendored Baton，再以 `shell=False` 执行固定参数；解析失败或普通项目都回退原 claude-all statusline。direct 由项目级 Baton wrapper 直接追加一行 Codex 额度，`baton init --no-statusline` 不会追加。

卸载器只删除 manifest 里仍与记录相符的 claude-all 软链和 vendored 安装，不删除用户自装 Baton、council 或项目 `.baton` 文件。项目级 statusline 属于 Baton 自己的状态，需在项目目录运行 `baton statusline uninstall` 后再卸载 claude-all。vendor 来源和上游 commit 记录在 `baton/UPSTREAM`，`scripts/sync-baton.sh --check <Baton checkout>` 只比较上游 Git 跟踪文件。
