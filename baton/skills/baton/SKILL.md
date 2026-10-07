---
name: baton
description: >-
  可配置的 conductor/judge/executor multi-agent 编码工作流。默认 Claude Opus 指挥、conductor 自裁决、Codex GPT-6.1-Sol 执行；也支持
  DeepSeek/Kimi/GLM 等 claude-all profile、Claude executor 和 council.skill 合议。负责写简报、后台运行执行者、处理决策与审阅、监管和最终验收。
  触发：/baton、multi-agent、让执行者改代码、配置 conductor/judge/executor。
---

# Baton：conductor、judge、executor

你是 conductor：定方案、写简报、发消息和监管。judge 可以是 conductor 自己，也可以在每个阶段调用 [council.skill](https://github.com/ParadoxZW/council.skill)；executor 通过 `roles.executor.adapter` 选择 Codex 或 headless Claude。默认配置仍是 Codex `gpt-6.1-sol`、`xhigh`、默认 service tier、关闭 fast mode。这些参数在 `${CLAUDE_SKILL_DIR}/config.json`，项目可在 `.baton/config.json` 覆盖。主会话不要求是 Opus；doctor/启动输出显示配置的 conductor 身份。

命令行工具是 `baton`（`${CLAUDE_SKILL_DIR}/bin/baton`，`install.sh` 会链接到 `~/.local/bin/baton`）。在目标项目目录下运行。`baton doctor` 提示 PATH 上的 baton 不是本 skill 的时，改用 `${CLAUDE_SKILL_DIR}/bin/baton`。

## 启动

1. 自检：`baton doctor`。有 FAIL 先解决；确认 conductor、judge 三阶段和 executor adapter 与任务一致。
2. 初始化：`baton init`（可重复执行）。它配置项目 statusline；Codex executor 显示第二行额度，Claude executor 只保留原 statusline。项目有测试命令就写进 `.baton/config.json` 的 `supervision.test_command`，Claude 默认工具白名单会从它生成。任务需要联网时按适配器配置网络和工具权限，并告诉用户。
3. 写简报：先读必要的代码弄清现状，再 `baton new <task>`，填满 `.baton/tasks/<task>/brief.md` 每一节，不留「（待填）」。验收标准要能检查，范围写清允许和禁止修改的路径。需求有歧义先问用户。把简报要点用两三句告诉用户。
4. 启动：`baton start <task>`。
5. 守候：用 Bash 的 `run_in_background: true` 运行 `baton wait <task>`，然后结束本回合，告诉用户执行者已开始、下一次监管大约在什么时候。不要在前台 sleep 轮询；`wait` 结束时你会被唤醒。

## 事件处理

`baton wait` 在三种情况下返回：本轮结束、距上次监管满 30 分钟、额度首次低于阈值。返回内容以 `BATON::EVENT <类型>` 开头：

| 事件 | 处理 |
|---|---|
| `TICK` | 监管检查，按 `references/supervision.md` |
| `REPORT` | 审阅大修改汇报，按 `references/review.md` |
| `DECISION` | 处理决策请求，按 `references/decision.md` |
| `DONE` | 最终验收，按 `references/review.md` 末节 |
| `BLOCKED` | 看缺什么；能解决就解决后 `baton resume`，涉及权限、网络、费用先问用户 |
| `FAILED` | 看 stderr 末尾判断原因（额度耗尽、网络、参数），修正后 `baton resume` 重试 |
| `STOPPED` | 你主动停止的，写好指令后 `baton resume` |
| `PAUSED_UNSUPERVISED` | 超过 70 分钟无人监管，执行者已被自动暂停；先做一次监管检查再 `resume` |
| `QUOTA_LOW` | 立即提醒用户（剩余百分比、重置时间、可用重置券），然后继续后台 `wait`；用户没说停就不停 |
| `IDLE` | 当前没有运行中的轮次 |

处理完后，只要有轮次在运行（或你刚 `resume`/`steer` 过），就重新后台 `baton wait <task>`。没有 `wait` 在跑就没有监管。决策、REPORT、DONE 三个阶段分别读取 `roles.judge.stages.decision/review/final`；值为 `council` 时按 references/decision.md 或 review.md 调用 council.skill，值为 `conductor` 时由主会话直接裁决。

`resume`、`steer`、`stop` 发现上一轮已经自己结束、而事件还没被报告过时，会先打印那个事件（`resume`/`steer` 以退出码 4 停下）。这时先按事件处理，处理完再执行同一条命令。

## 规则

- 任何命令输出含 `BATON::QUOTA_LOW` 时，当回合回复里提醒用户 Codex 额度低于 5%。
- 发给执行者的每条消息（决策、审阅、纠偏）都先写成文件放在 `.baton/` 下，再 `baton resume <task> <文件> --kind <类型>`，便于追溯。
- 不亲手修改执行者负责的代码，问题通过 `resume` / `steer` 交给执行者改；用户明确要求时例外。
- 不 `git commit` / `push`，除非用户要求。回滚（`baton rollback`）只在用户同意后执行；它只改工作区文件，HEAD、分支和暂存区不变，执行前先把当前状态存成回滚点，并把要改写或删除的文件原样备份到 `.baton/rollback-backup/`；子模块内部不在回滚范围内。
- 一个项目同一时间只跑一个任务的一轮。
- 用户要离开时提醒：执行者在独立进程里继续跑，但关闭本会话后没人监管，超过 70 分钟无监管会自动暂停。
- 给用户的进度汇报保持简短：事件、结论、下一步。

常用配置：

```bash
baton setup --preset default             # 默认 Claude Opus + conductor judge + Codex
baton setup --preset deepseek-council    # DeepSeek conductor + council judge + Codex
baton setup --preset kimi-claude          # Kimi conductor + claude-all GLM executor
```

Claude executor 没有 Codex 的 OS 沙箱。默认 `permission_mode=acceptEdits`，`allowed_tools` 缺省时按 `supervision.test_command` 生成并排除网络安装命令；`bypassPermissions` 只有显式配置才会加入命令。普通 `claude` executor 清理继承的第三方环境变量，`inherit_env=true` 才保留；`claude-all` executor 交给 claude-all 自己隔离。

## 命令速查

| 命令 | 作用 |
|---|---|
| `baton doctor` | 环境自检：conductor、judge、executor、Claude 工具白名单、council、git；只有 Codex executor 查额度 |
| `baton setup [--preset ...]` | 配置三角色；TTY 会列出 claude-all profile 名与 label |
| `baton init [--no-statusline]` | 创建 `.baton/`，按 executor adapter 配置项目 statusline |
| `baton statusline install/uninstall/status` | 单独安装、撤销、查看项目 statusline；settings.local.json 被 git 跟踪时默认不改，需 `--force` |
| `baton new <task>` | 生成简报模板 |
| `baton start <task>` | 首轮：按 adapter 启动 executor，建回滚点，后台运行 |
| `baton resume <task> <file> --kind 决策/审阅/纠偏` | 带消息续跑：Codex `exec resume` 或 Claude `--resume` |
| `baton wait <task>` | 阻塞到下一个事件（必须后台运行） |
| `baton status <task>` | 监管快照 |
| `baton supervised <task> --verdict on_track/drifting/breaking --note ...` | 记录监管结论、建回滚点、重置 30 分钟计时 |
| `baton steer <task> <file>` | 停止当前轮并带纠偏消息续跑 |
| `baton stop <task>` | 中断当前轮 |
| `baton diff <task> --since base/leg/tick/report [--stat]` | 相对任务起点 / 本轮起点 / 上次监管 / 上次汇报的改动 |
| `baton refs <task>` / `baton rollback <task> <ref> --yes` | 列出回滚点 / 把工作区文件恢复到回滚点 |
| `baton quota [--refresh]` | Codex 额度（app-server 实时读取，不消耗 token） |

## 项目内文件

```
.baton/
  config.json            项目级配置覆盖
  log.md                 执行者的修改日志（每次小修改一条，大修改指向汇报）
  supervision.md         你的 30 分钟监管记录
  tasks/<task>/brief.md  任务简报；state.json 为运行状态；steer-*.md 纠偏消息
  reports/R<NNN>-*.html  执行者的大修改汇报
  reviews/R<NNN>-review.md、<task>-final.md   你的审阅
  decisions/D<NNN>-*.md  决策请求，末尾「指挥决定」由你填写
  runs/<task>/leg-NNN.*  每轮的 prompt、Codex 事件流、最终输出、stderr（已 gitignore）
  rollback-backup/       回滚前被改写或删除的文件原样备份（已 gitignore）
  statusline-saved.json  安装 statusline 前项目原有的 statusLine，供撤销时恢复
.claude/settings.local.json   项目 statusline（本机文件，已写入 .git/info/exclude）
```

回滚点是 git ref：`refs/baton/<task>/{base,leg-NNN-start,leg-NNN-end,tick-*}`，不影响分支和暂存区。
