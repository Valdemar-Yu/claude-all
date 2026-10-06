# 排错

按症状查。每条:症状 → 根因 → 解法。

## 所有环境同时无法启动 / `claude: command not found` / `Killed: 9`

**根因**:五个 profile 最终都依赖同一份 Claude Code。npm 更新若在原生二进制下载、解包或原子 rename 阶段中断，可能留下 `.claude-随机串` / `.claude-code-随机串`，删掉正式 `claude` 入口，或留下被截断、无有效签名的 Mach-O；macOS 执行后通常是 `Killed: 9`。这不是某个 provider 的 token 或协议问题。

**诊断**:

```bash
claude --version
claude-all doctor
npm list -g --depth=0 @anthropic-ai/claude-code
```

健康状态必须让 `claude --version` 打印版本。macOS 还可用 `codesign -dv --verbose=2 "$(command -v claude)"` 核对签名。只看到命令文件存在不代表二进制健康。

**修复**:

```bash
npm install -g @anthropic-ai/claude-code@stable
claude --version
./install.sh
claude-all doctor
```

若 npm 报 `ENOTEMPTY ... rename ... .claude-code-随机串`，说明上一次更新的 staging/backup 目录仍在；先确认其中不含用户数据并移走冲突目录，再重装。不要把随机隐藏入口直接当长期 `claude` 使用。安装器只会用通过版本检查的 CLI 原子刷新隔离 runtime，坏更新不会覆盖上一个健康版本。

## 403 This group does not allow /v1/messages dispatch

**根因**:Claude Code 直连了中转的 Anthropic 端点。中转是纯 OpenAI 协议,禁用了 `/v1/messages`。通常是 `CLAUDE_CONFIG_DIR` 指向了被污染的 `~/.claude`(其 settings.json 的 `ANTHROPIC_BASE_URL` 覆盖了 claudish 代理)。

**解法**:用 cc-gpt-plbbl 启动(它锁独立 config 目录),别直接敲 `claude`。检查 `~/.claude-plbbl/settings.json` 不含 `ANTHROPIC_*`。

## ⚠ Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY set

**根因**:claudish 启动 Claude Code 时会同时注入两个占位变量(`ANTHROPIC_API_KEY` 防 API key 弹窗、`ANTHROPIC_AUTH_TOKEN` 防 login 界面),真实认证由 claudish 本地代理完成。新版 Claude Code 检测到双变量就警告。无害,但吵。

**解法**:认证占位符 patch 是显式 opt-in。重跑安装器时设置 `CCGP_PATCH_CLAUDISH=1`，或直接运行：

```
bash ~/.local/share/claude-all/lib/patch-claudish.sh --auth
```

原文件备份在 claudish 包内 `dist/index.js.claude-all-bak`,要还原直接 `cp` 覆盖。

## ⚠️ Tool call "Bash" failed: missing required parameters: command

**根因**:claudish 的 `litellm` provider 工具调用翻译偶发残缺(跨模型都中招)。claudish 把后端返回的 tool call 解析出缺参数,作为文本报给你——会话没崩,但那次工具调用没执行。

**解法**:换 `oai` provider。配置 `provider=oai`、model 用 `oai@...` 前缀(cc-gpt-plbbl 默认就是 oai)。万一 oai 也偶发(极小概率),重发一次 prompt 通常就好。

## ~/.claude/.claude.json 被冲成 389 字节(账户态丢失)

**根因**:把 `CLAUDE_CONFIG_DIR` 锁到官方 `~/.claude`,且该目录 settings.json 与 claudish 冲突时,Claude Code 启动可能重置 `.claude.json`。

**解法**:cc-gpt-plbbl 用独立目录规避;install 时自动 backup `~/.claude/.claude.json` 到 `.claude.json.claude-all-bak.<ts>`。已发生的话,从 `~/.claude/backups/` 找最大的 backup 恢复:

```
ls -lt ~/.claude/backups/.claude.json.backup.*   # 找最大的
cp ~/.claude/backups/.claude.json.backup.<最大那个> ~/.claude/.claude.json
```

## line N: MODEL_ARGS[@]: unbound variable

**根因**:macOS 自带 bash 3.2 在 `set -u` 下展开空数组 `"${arr[@]}"` 报 unbound。

**解法**:cc-gpt-plbbl 的 exec 行已用 `${arr[@]+"${arr[@]}"}` 规避。fork 后改脚本要保留这个写法。

## 进不去 / 闪退

- `claude` / `claudish` 没装 → install 时会检查并提示。
- `~/.local/bin` 不在 PATH → install 会提示,按提示加。
- token 没配好 → `cc-gpt-plbbl` 报「没解析到 token」,按提示配 `token=` 或 `token_cmd=`。

## 配了不同 subagent/team 模型，实际仍都走主模型

**根因**:旧 profile 给 claudish 传单一 `--model`，它会成为所有请求的 explicit primary；或者手动使用了 claudish 7.12.1 尚未接入实际路由的 `--model-subagent`。

**解法**:重跑 `claude-all add` 生成 schema 2 profile。dry-run 应显示 `--model-opus`、`--model-sonnet`、`--model-haiku` 三条映射，且不应出现单一 `claudish --model <主模型>`。

## add 读不到模型列表

**根因**:中转没实现标准 `/v1/models`，base URL 路径不匹配，或 token 无权访问 Models API。Models API 可用也不代表返回的每个模型都能推理。

**解法**:向导会保留具体 HTTP/JSON 原因并自动进入手动模型 ID 输入。手动值以服务方文档和一次真实请求为准；不要因为模型出现在列表里就视为已验证。

## claudish 会话看不到统一 Statusline

**根因**:claudish 升级覆盖了 npm 包内的兼容 patch，临时 `--settings` 又恢复为内置状态栏。

**解法**:

```
bash ~/.local/share/claude-all/lib/patch-claudish.sh --statusline-only
```

然后重新启动会话。若是 direct/cmd profile，检查其 `$CLAUDE_CONFIG_DIR/settings.json` 的 `statusLine.command` 是否指向 `~/.local/share/claude-all/statusline/statusline.py`。

## `claude` 官方环境提示 Not logged in

**根因**:`claude` 内置 profile 现在使用隔离的 `~/.claude-all`，防止 `~/.claude/settings.json` 中的 CC Switch `ANTHROPIC_*` 把官方请求改发到第三方端点。macOS 的 OAuth 凭据由 Claude Code 保存在 Keychain；如果这台机器没有可用的官方登录态，隔离环境会明确提示登录。

**解法**:运行 `claude-all claude` 后执行 `/login`。这是一次交互式 OAuth 登录，claude-all 不读取、复制或提交凭据。不要为了绕过登录把 CC Switch 的第三方 token 写回官方 profile。

## Baton 没有出现在菜单 / `claude-all baton` 提示未安装

**根因**:`CCGP_BATON=auto` 只在安装器检测到 `codex` CLI 时安装 Baton。Baton 还需要官方 Claude 订阅和已经登录的 Codex CLI。

**诊断**:

```bash
command -v codex
codex --version
claude-all doctor
```

doctor 的 Baton 段会显示 CLI 路径和来源、Codex 是否可用以及受管 config 的 `skills/baton` 链接。Baton 是可选组件，缺失只会给出 WARN，不会让其他 profile 的 doctor 失败。

**修复**:

```bash
CCGP_BATON=yes ./install.sh
claude-all baton "检查当前任务"
```

`claude-all baton` 只使用官方 profile，并传 `--model opus`。缺少官方 `claude.env` 时重新运行 `./install.sh`，缺少 Codex 时先登录 Codex。若安装时不需要 Baton，设置 `CCGP_BATON=no`。

## Baton 项目看不到 Codex 额度行

**根因**:项目没有运行 `baton init`，或项目运行了 `baton init --no-statusline`。claudish 还会用临时 `--settings` 覆盖项目 statusline，claude-all 需要通过自己的分发器确认项目级 Baton 设置。

**诊断**:

```bash
baton doctor
claude-all doctor
```

如果项目确实需要额度行，在项目根目录运行 `baton init` 后重开会话。分发器只接受 realpath 指向全局或 vendored Baton 的固定脚本命令，普通项目、解析失败或不受信任的同名脚本都会回退原 claude-all statusline。

**撤销**:

```bash
baton statusline uninstall
```

项目级 statusline 由 Baton 管理，先撤销它再运行 claude-all 的 `./uninstall.sh`。卸载器会保留用户自装的 Baton、council、普通目录和清单外软链。

## 需要同步上游 Baton

vendor 版本的仓库、commit 和补丁清单在 `baton/UPSTREAM`。给同步脚本一个本地 Baton checkout，它只读 Git 跟踪文件，工作区有未提交改动会拒绝同步：

```bash
scripts/sync-baton.sh --check /path/to/Baton
```

确认差异后再去掉 `--check` 写入 vendor。同步不会联网安装第三方 council.skill；若本机还没有 council，安装输出会提示运行 `~/.local/share/claude-all/baton/install.sh --council`，自定义 `CCGP_PREFIX` 时把前缀替换成对应目录。这一步会联网 clone 第三方仓库。
