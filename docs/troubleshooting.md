# 排错

按症状查。每条:症状 → 根因 → 解法。

## 403 This group does not allow /v1/messages dispatch

**根因**:Claude Code 直连了中转的 Anthropic 端点。中转是纯 OpenAI 协议,禁用了 `/v1/messages`。通常是 `CLAUDE_CONFIG_DIR` 指向了被污染的 `~/.claude`(其 settings.json 的 `ANTHROPIC_BASE_URL` 覆盖了 claudish 代理)。

**解法**:用 cc-gpt-plbbl 启动(它锁独立 config 目录),别直接敲 `claude`。检查 `~/.claude-ccgpt/settings.json` 不含 `ANTHROPIC_*`。

## ⚠️ Tool call "Bash" failed: missing required parameters: command

**根因**:claudish 的 `litellm` provider 工具调用翻译偶发残缺(跨模型都中招)。claudish 把后端返回的 tool call 解析出缺参数,作为文本报给你——会话没崩,但那次工具调用没执行。

**解法**:换 `oai` provider。配置 `provider=oai`、model 用 `oai@...` 前缀(cc-gpt-plbbl 默认就是 oai)。万一 oai 也偶发(极小概率),重发一次 prompt 通常就好。

## ~/.claude/.claude.json 被冲成 389 字节(账户态丢失)

**根因**:把 `CLAUDE_CONFIG_DIR` 锁到官方 `~/.claude`,且该目录 settings.json 与 claudish 冲突时,Claude Code 启动可能重置 `.claude.json`。

**解法**:cc-gpt-plbbl 用独立目录规避;install 时自动 backup `~/.claude/.claude.json` 到 `.claude.json.ccgpt-bak.<ts>`。已发生的话,从 `~/.claude/backups/` 找最大的 backup 恢复:

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
