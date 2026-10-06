#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-all-baton-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || { cat "$1" >&2; fail "$1 缺少: $2"; }; }
assert_not_contains() { ! grep -F -- "$2" "$1" >/dev/null || fail "$1 不应包含: $2"; }
assert_eq() { [ "$1" = "$2" ] || fail "期望 '$2'，实际 '$1'"; }
assert_link_target() {
  [ -L "$1" ] || fail "不是软链: $1"
  [ "$(cd -P "$(dirname "$1")" && pwd)/$(readlink "$1")" = "$2" ] || {
    [ "$(python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)" = "$(python3 - "$2" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)" ] || fail "软链目标不符: $1"
  }
}

make_fake_tools() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '9.9.9 (Claude Code)\n'; exit 0; fi
printf 'FAKE_CLAUDE'
printf ' <%s>' "$@"
printf '\n'
SH
  cat > "$bindir/claudish" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '7.12.0\n'; exit 0; fi
printf 'FAKE_CLAUDISH'
printf ' <%s>' "$@"
printf ' STATUSLINE=%s' "${CLAUDISH_STATUSLINE_COMMAND:-}"
printf '\n'
SH
  cat > "$bindir/codex" <<'SH'
#!/usr/bin/env bash
printf 'codex 0.0-test\n'
SH
  chmod +x "$bindir/claude" "$bindir/claudish" "$bindir/codex"
}

run_install() {
  local home="$1" prefix="$2" bindir="$3" codex_mode="${4:-yes}"
  local path="$TMP/tools:$PATH"
  [ "$codex_mode" = no ] && path="$TMP/no-codex:/usr/bin:/bin"
  HOME="$home" PATH="$path" CCGP_PREFIX="$prefix" CCGP_BINDIR="$bindir" \
    CCGP_CONFIG_FILE="$home/.config/claude-all/config" CLAUDE_ALL_HOME="$home/.claude-all" \
    CCGP_CONFIG_DIR="$home/.claude-plbbl" CCGP_TOKEN=test-token CCGP_SKIP_PROBE=1 \
    CCGP_STATUSLINE=no CCGP_BATON=yes bash "$ROOT/install.sh"
}

mkdir -p "$TMP/tools" "$TMP/no-codex"
make_fake_tools "$TMP/tools"
for _tool in claude claudish; do ln -s "$TMP/tools/$_tool" "$TMP/no-codex/$_tool"; done
ln -s "$(command -v python3)" "$TMP/no-codex/python3"
ln -s "$(command -v curl)" "$TMP/no-codex/curl"

# Sync compares only clean git-tracked upstream files and ignores a generated __pycache__.
UPSTREAM_COPY="$TMP/upstream-copy"
cp -R /Users/zhizhiyu/yuzz/Baton "$UPSTREAM_COPY"
mkdir -p "$UPSTREAM_COPY/skills/baton/scripts/__pycache__"
printf '%s\n' ignored > "$UPSTREAM_COPY/skills/baton/scripts/__pycache__/ignored.pyc"
"$ROOT/scripts/sync-baton.sh" --check "$UPSTREAM_COPY" > "$TMP/sync-clean.out" 2>&1
printf '%s\n' dirty >> "$UPSTREAM_COPY/skills/baton/SKILL.md"
if "$ROOT/scripts/sync-baton.sh" --check "$UPSTREAM_COPY" > "$TMP/sync-dirty.out" 2>&1; then
  fail '上游有未提交改动时 sync --check 不应通过'
fi
assert_contains "$TMP/sync-dirty.out" '未提交改动'

# Normal install, re-run idempotently, and all managed config links share one skill.
HOME1="$TMP/home-normal"; PREFIX1="$TMP/prefix-normal"; BIN1="$TMP/bin-normal"
mkdir -p "$HOME1"
run_install "$HOME1" "$PREFIX1" "$BIN1" > "$TMP/install-normal-1.out" 2>&1
[ -d "$PREFIX1/baton" ] || fail '正常安装没有复制 PREFIX/baton'
assert_contains "$TMP/install-normal-1.out" 'baton/install.sh --council'
assert_link_target "$HOME1/.claude/skills/baton" "$(python3 - "$PREFIX1/baton/skills/baton" - <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
assert_link_target "$HOME1/.local/bin/baton" "$(python3 - "$PREFIX1/baton/skills/baton/bin/baton" - <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
assert_link_target "$HOME1/.claude-all/skills/baton" "$(python3 - "$HOME1/.claude/skills/baton" - <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
assert_link_target "$HOME1/.claude-plbbl/skills/baton" "$(python3 - "$HOME1/.claude/skills/baton" - <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
assert_eq "$(readlink "$HOME1/.claude-all/skills/baton")" "$HOME1/.claude/skills/baton"
assert_eq "$(readlink "$HOME1/.claude-plbbl/skills/baton")" "$HOME1/.claude/skills/baton"
[ -s "$PREFIX1/baton-links" ] || fail '没有写 Baton 链接清单'

# The claudish wrapper receives the dispatcher command, while direct profiles keep the original.
HOME="$HOME1" PATH="$TMP/tools:$BIN1:/usr/bin:/bin" CCGP_CONFIG_FILE="$HOME1/.config/claude-all/config" \
  CCGP_TOKEN=test-token CCGP_STATUSLINE=yes CCGP_CONFIG_DIR="$HOME1/.claude-plbbl" \
  "$BIN1/cc-gpt-plbbl" --test > "$TMP/cc-gpt-statusline.out" 2>&1
assert_contains "$TMP/cc-gpt-statusline.out" 'statusline/dispatch.py'
cat > "$HOME1/.claude-all/profiles/claudish-test.env" <<'EOF'
CLAUDE_ALL_LAUNCH=claudish
CLAUDE_ALL_MODEL=oai@test-model
CLAUDE_ALL_STATUSLINE=yes
OPENAI_BASE_URL=https://relay.example/v1
OPENAI_API_KEY=test-token
EOF
HOME="$HOME1" PATH="$TMP/tools:$BIN1:/usr/bin:/bin" CLAUDE_ALL_PROFILES_DIR="$HOME1/.claude-all/profiles" \
  CLAUDE_ALL_RUNTIME_DIR="$PREFIX1/runtime/bin" "$PREFIX1/bin/claude-all" claudish-test --test > "$TMP/claude-all-statusline.out" 2>&1
assert_contains "$TMP/claude-all-statusline.out" 'statusline/dispatch.py'
cp "$PREFIX1/baton-links" "$TMP/manifest.before"
run_install "$HOME1" "$PREFIX1" "$BIN1" > "$TMP/install-normal-2.out" 2>&1
cmp -s "$TMP/manifest.before" "$PREFIX1/baton-links" || fail '第二次安装改变了 Baton 链接清单'
ln -sfn "$TMP/other-skill" "$HOME1/.claude-all/skills/baton"
run_install "$HOME1" "$PREFIX1" "$BIN1" > "$TMP/install-normal-repair.out" 2>&1
assert_eq "$(readlink "$HOME1/.claude-all/skills/baton")" "$HOME1/.claude/skills/baton"

# Profile config paths expand ~/x, $HOME/x and ${HOME}/x without sourcing profile code.
HOME="$HOME1" CLAUDE_ALL_BATON_PREFIX="$PREFIX1" bash -c '
  set -e
  source "$1/lib/baton.sh"
  _claude_all_baton_init
  test "$(_baton_expand_config_dir "~/x")" = "$HOME/x"
  test "$(_baton_expand_config_dir "\$HOME/x")" = "$HOME/x"
  test "$(_baton_expand_config_dir "\${HOME}/x")" = "$HOME/x"
' _ "$ROOT"
mkdir -p "$HOME1/custom-tilde" "$HOME1/custom-dollar" "$HOME1/custom-braced"
cat > "$HOME1/.claude-all/profiles/tilde-path.env" <<'EOF'
CLAUDE_CONFIG_DIR="~/custom-tilde"
EOF
cat > "$HOME1/.claude-all/profiles/dollar-path.env" <<'EOF'
CLAUDE_CONFIG_DIR='$HOME/custom-dollar'
EOF
cat > "$HOME1/.claude-all/profiles/braced-path.env" <<'EOF'
CLAUDE_CONFIG_DIR='${HOME}/custom-braced'
EOF
run_install "$HOME1" "$PREFIX1" "$BIN1" > "$TMP/install-normal-3.out" 2>&1
for _dir in custom-tilde custom-dollar custom-braced; do
  assert_link_target "$HOME1/$_dir/skills/baton" "$HOME1/.claude/skills/baton"
done

# Keep a core-only installation for missing Baton/doctor checks below.
HOME_NO="$TMP/home-no"; PREFIX_NO="$TMP/prefix-no"; BIN_NO="$TMP/bin-no"
mkdir -p "$HOME_NO"
HOME="$HOME_NO" PATH="$TMP/tools:$PATH" CCGP_PREFIX="$PREFIX_NO" CCGP_BINDIR="$BIN_NO" \
  CCGP_CONFIG_FILE="$HOME_NO/.config/claude-all/config" CLAUDE_ALL_HOME="$HOME_NO/.claude-all" \
  CCGP_CONFIG_DIR="$HOME_NO/.claude-plbbl" CCGP_TOKEN=test-token CCGP_SKIP_PROBE=1 \
  CCGP_STATUSLINE=no CCGP_BATON=no bash "$ROOT/install.sh" > "$TMP/install-no.out" 2>&1
[ ! -e "$PREFIX_NO/baton" ] || fail 'CCGP_BATON=no 仍复制了 Baton'
[ ! -e "$HOME_NO/.claude-all/skills/baton" ] || fail 'CCGP_BATON=no 仍创建 config 链接'
assert_contains "$TMP/install-no.out" 'CCGP_BATON=no'

# claude-all baton uses the official profile, forces Opus, and turns a task into the first message.
HOME="$HOME1" PATH="$TMP/tools:$BIN1:/usr/bin:/bin" CLAUDE_ALL_PROFILES_DIR="$HOME1/.claude-all/profiles" \
  CLAUDE_ALL_RUNTIME_DIR="$PREFIX1/runtime/bin" "$PREFIX1/bin/claude-all" baton '示例任务' > "$TMP/baton-start.out" 2>&1
assert_contains "$TMP/baton-start.out" 'FAKE_CLAUDE'
assert_contains "$TMP/baton-start.out" '<--model> <opus>'
assert_contains "$TMP/baton-start.out" '</baton 示例任务>'

# The menu exposes Baton as one item after profiles and selecting it follows the same path.
_profile_count="$(find "$HOME1/.claude-all/profiles" -maxdepth 1 -type f -name '*.env' | wc -l | tr -d ' ')"
printf '%s\n' "$((_profile_count + 1))" | HOME="$HOME1" PATH="$TMP/tools:$BIN1:/usr/bin:/bin" \
  CLAUDE_ALL_PROFILES_DIR="$HOME1/.claude-all/profiles" CLAUDE_ALL_RUNTIME_DIR="$PREFIX1/runtime/bin" \
  "$PREFIX1/bin/claude-all" > "$TMP/baton-menu.out" 2>&1
assert_contains "$TMP/baton-menu.out" 'Baton（Opus 指挥 · Codex 执行）'
assert_contains "$TMP/baton-menu.out" '<--model> <opus>'

# Launching a new managed direct profile repairs its config link on demand.
cat > "$HOME1/.claude-all/profiles/new-managed.env" <<EOF_PROFILE
CLAUDE_ALL_LAUNCH=direct
CLAUDE_CONFIG_DIR="$HOME1/new-managed"
EOF_PROFILE
HOME="$HOME1" PATH="$TMP/tools:$BIN1:/usr/bin:/bin" CLAUDE_ALL_PROFILES_DIR="$HOME1/.claude-all/profiles" \
  CLAUDE_ALL_RUNTIME_DIR="$PREFIX1/runtime/bin" "$PREFIX1/bin/claude-all" new-managed --test > "$TMP/new-managed.out" 2>&1
assert_eq "$(readlink "$HOME1/new-managed/skills/baton")" "$HOME1/.claude/skills/baton"

# Quick checks fail clearly for a missing Baton, missing codex, missing official profile, and an arbitrary PATH command.
if HOME="$HOME_NO" PATH="$TMP/tools:/usr/bin:/bin" CLAUDE_ALL_PROFILES_DIR="$HOME_NO/.claude-all/profiles" \
  CLAUDE_ALL_RUNTIME_DIR="$PREFIX_NO/runtime/bin" "$PREFIX_NO/bin/claude-all" baton > "$TMP/baton-missing.out" 2>&1; then
  fail '缺少 Baton 时 claude-all baton 不应成功'
fi
assert_contains "$TMP/baton-missing.out" '没有可执行的 Baton'
if HOME="$HOME1" PATH="$TMP/no-codex:/usr/bin:/bin" CLAUDE_ALL_PROFILES_DIR="$HOME1/.claude-all/profiles" \
  CLAUDE_ALL_RUNTIME_DIR="$PREFIX1/runtime/bin" "$PREFIX1/bin/claude-all" baton > "$TMP/baton-no-codex.out" 2>&1; then
  fail '缺少 codex 时 claude-all baton 不应成功'
fi
assert_contains "$TMP/baton-no-codex.out" 'codex CLI'
mkdir -p "$TMP/empty-profiles"
if HOME="$HOME1" PATH="$TMP/tools:/usr/bin:/bin" CLAUDE_ALL_PROFILES_DIR="$TMP/empty-profiles" \
  CLAUDE_ALL_RUNTIME_DIR="$PREFIX1/runtime/bin" "$PREFIX1/bin/claude-all" baton > "$TMP/baton-no-official.out" 2>&1; then
  fail '缺少官方 profile 时 claude-all baton 不应成功'
fi
assert_contains "$TMP/baton-no-official.out" '官方 Claude profile'
cat > "$TMP/tools/baton" <<'SH'
#!/usr/bin/env bash
echo arbitrary-baton
SH
chmod +x "$TMP/tools/baton"
if HOME="$HOME_NO" PATH="$TMP/tools:/usr/bin:/bin" CLAUDE_ALL_PROFILES_DIR="$HOME_NO/.claude-all/profiles" \
  CLAUDE_ALL_RUNTIME_DIR="$PREFIX_NO/runtime/bin" "$PREFIX_NO/bin/claude-all" baton > "$TMP/baton-invalid-path.out" 2>&1; then
  fail 'PATH 上任意 baton 程序不应通过快速检查'
fi
assert_contains "$TMP/baton-invalid-path.out" '不是 Baton'

# doctor reports Baton details but remains optional when it is absent.
HOME="$HOME1" PATH="$TMP/tools:$BIN1:/usr/bin:/bin" CLAUDE_ALL_HOME="$HOME1/.claude-all" \
  CCGP_CONFIG_DIR="$HOME1/.claude-plbbl" CLAUDE_ALL_PROFILES_DIR="$HOME1/.claude-all/profiles" \
  CLAUDE_ALL_RUNTIME_DIR="$PREFIX1/runtime/bin" "$PREFIX1/bin/claude-all" doctor > "$TMP/doctor-baton.out" 2>&1
assert_contains "$TMP/doctor-baton.out" 'Baton CLI: OK — vendored'
assert_contains "$TMP/doctor-baton.out" 'Baton Codex CLI: OK'
assert_contains "$TMP/doctor-baton.out" 'Baton skill link: OK'
assert_contains "$TMP/doctor-baton.out" 'custom-tilde'
HOME="$HOME_NO" PATH="$TMP/no-codex:/usr/bin:/bin" CLAUDE_ALL_HOME="$HOME_NO/.claude-all" \
  CCGP_CONFIG_DIR="$HOME_NO/.claude-plbbl" CLAUDE_ALL_PROFILES_DIR="$HOME_NO/.claude-all/profiles" \
  CLAUDE_ALL_RUNTIME_DIR="$PREFIX_NO/runtime/bin" "$PREFIX_NO/bin/claude-all" doctor > "$TMP/doctor-no-baton.out" 2>&1
assert_contains "$TMP/doctor-no-baton.out" 'Baton CLI: WARN'

# Statusline rendering: direct uses Baton's project wrapper; claudish dispatches to
# the same wrapper only when settings.local.json selects it. The quota cache is mocked.
STATUS_HOME="$TMP/home-status"; STATUS_PROJECT="$STATUS_HOME/project"; STATUS_NO="$STATUS_HOME/no-statusline"
STATUS_CACHE="$STATUS_HOME/cache"; STATUS_PREFIX="$PREFIX1"
mkdir -p "$STATUS_HOME/.claude-all" "$STATUS_PROJECT/.claude" "$STATUS_PROJECT/.baton" \
  "$STATUS_NO/.baton" "$STATUS_CACHE"
cat > "$TMP/fake-base-statusline" <<'SH'
#!/usr/bin/env bash
printf 'claude-all base\n'
SH
chmod +x "$TMP/fake-base-statusline"
python3 - "$STATUS_HOME/.claude-all/settings.json" "$TMP/fake-base-statusline" <<'PY'
import json, sys
path, command = sys.argv[1:]
with open(path, "w") as f:
    json.dump({"statusLine": {"type": "command", "command": command}}, f)
PY
python3 - "$STATUS_CACHE/codex-quota.json" <<'PY'
import json, sys, time
now = time.time()
with open(sys.argv[1], "w") as f:
    json.dump({"source": "mock", "fetched_at": now, "observed_at": now,
               "windows": [{"label": "5h", "remaining": 80, "resets_at": now + 3600}],
               "credits": {}}, f)
PY
python3 - "$STATUS_PROJECT/.claude/settings.local.json" "$STATUS_PREFIX/baton/skills/baton/scripts/statusline.py" <<'PY'
import json, sys
path, script = sys.argv[1:]
with open(path, "w") as f:
    json.dump({"statusLine": {"type": "command", "command": "python3 " + script + " --baton-statusline"}}, f)
PY
printf '%s\n' '{"workspace":{"project_dir":"'"$STATUS_PROJECT"'"}}' > "$TMP/status-session.json"
HOME="$STATUS_HOME" CLAUDE_CONFIG_DIR="$STATUS_HOME/.claude-all" BATON_CACHE_DIR="$STATUS_CACHE" \
  python3 "$STATUS_PREFIX/baton/skills/baton/scripts/statusline.py" --baton-statusline \
  < "$TMP/status-session.json" > "$TMP/status-direct.out"
HOME="$STATUS_HOME" CLAUDE_CONFIG_DIR="$STATUS_HOME/.claude-all" BATON_CACHE_DIR="$STATUS_CACHE" \
  python3 "$STATUS_PREFIX/statusline/dispatch.py" < "$TMP/status-session.json" > "$TMP/status-claudish.out"
assert_eq "$(grep -c 'Codex ' "$TMP/status-direct.out" || true)" 1
assert_eq "$(grep -c 'Codex ' "$TMP/status-claudish.out" || true)" 1
assert_contains "$TMP/status-direct.out" 'claude-all base'
assert_contains "$TMP/status-claudish.out" 'claude-all base'

printf '%s\n' '{"workspace":{"project_dir":"'"$STATUS_HOME"'/plain"}}' > "$TMP/status-plain-session.json"
mkdir -p "$STATUS_HOME/plain"
HOME="$STATUS_HOME" CLAUDE_CONFIG_DIR="$STATUS_HOME/.claude-all" BATON_CACHE_DIR="$STATUS_CACHE" \
  python3 "$STATUS_PREFIX/statusline/dispatch.py" < "$TMP/status-plain-session.json" > "$TMP/status-plain.out"
assert_eq "$(grep -c 'Codex ' "$TMP/status-plain.out" || true)" 0
printf '%s\n' '{"workspace":{"project_dir":"'"$STATUS_NO"'"}}' > "$TMP/status-no-session.json"
HOME="$STATUS_HOME" CLAUDE_CONFIG_DIR="$STATUS_HOME/.claude-all" BATON_CACHE_DIR="$STATUS_CACHE" \
  python3 "$STATUS_PREFIX/statusline/dispatch.py" < "$TMP/status-no-session.json" > "$TMP/status-no.out"
assert_eq "$(grep -c 'Codex ' "$TMP/status-no.out" || true)" 0

# Project settings are only a Baton switch: command strings and untrusted same-name
# scripts are never executed by the claudish dispatcher.
STATUS_EVIL="$STATUS_HOME/evil"; STATUS_MARK="$STATUS_HOME/evil-mark"
mkdir -p "$STATUS_EVIL/.claude"
python3 - "$STATUS_EVIL/.claude/settings.local.json" "$STATUS_MARK" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({"statusLine": {"type": "command",
                               "command": "touch " + sys.argv[2] + " # skills/baton/scripts/statusline.py"}}, f)
PY
printf '%s\n' '{"workspace":{"project_dir":"'"$STATUS_EVIL"'"}}' > "$TMP/status-evil-session.json"
HOME="$STATUS_HOME" CLAUDE_CONFIG_DIR="$STATUS_HOME/.claude-all" BATON_CACHE_DIR="$STATUS_CACHE" \
  python3 "$STATUS_PREFIX/statusline/dispatch.py" < "$TMP/status-evil-session.json" > "$TMP/status-evil.out"
[ ! -e "$STATUS_MARK" ] || fail '恶意 statusLine 命令被 dispatcher 执行'
assert_contains "$TMP/status-evil.out" 'Claude'
UNTRUSTED="$STATUS_HOME/untrusted/skills/baton/scripts"; UNTRUSTED_MARK="$STATUS_HOME/untrusted-mark"
mkdir -p "$UNTRUSTED"
cat > "$UNTRUSTED/statusline.py" <<SH
#!/usr/bin/env python3
open('$UNTRUSTED_MARK', 'w').write('executed')
print('untrusted')
SH
chmod +x "$UNTRUSTED/statusline.py"
python3 - "$STATUS_EVIL/.claude/settings.local.json" "$UNTRUSTED/statusline.py" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({"statusLine": {"type": "command", "command": "python3 " + sys.argv[2] + " --baton-statusline"}}, f)
PY
HOME="$STATUS_HOME" CLAUDE_CONFIG_DIR="$STATUS_HOME/.claude-all" BATON_CACHE_DIR="$STATUS_CACHE" \
  python3 "$STATUS_PREFIX/statusline/dispatch.py" < "$TMP/status-evil-session.json" > "$TMP/status-untrusted.out"
[ ! -e "$UNTRUSTED_MARK" ] || fail '不受信任的同名 statusline.py 被执行'
assert_contains "$TMP/status-untrusted.out" 'Claude'

# auto mode keeps the core install usable when the optional Baton location fails.
HOME_FAIL="$TMP/home-fail"; PREFIX_FAIL="$TMP/prefix-fail"; BIN_FAIL="$TMP/bin-fail"
mkdir -p "$HOME_FAIL/.claude"
chmod 500 "$HOME_FAIL/.claude"
HOME="$HOME_FAIL" PATH="$TMP/tools:$PATH" CCGP_PREFIX="$PREFIX_FAIL" CCGP_BINDIR="$BIN_FAIL" \
  CCGP_CONFIG_FILE="$HOME_FAIL/.config/claude-all/config" CLAUDE_ALL_HOME="$HOME_FAIL/.claude-all" \
  CCGP_CONFIG_DIR="$HOME_FAIL/.claude-plbbl" CCGP_TOKEN=test-token CCGP_SKIP_PROBE=1 \
  CCGP_STATUSLINE=no bash "$ROOT/install.sh" > "$TMP/install-fail-auto.out" 2>&1 || fail 'auto 模式 Baton 失败时不应阻断核心安装'
[ -f "$HOME_FAIL/.config/claude-all/config" ] || fail 'auto 模式 Baton 失败时没有写核心 config'
assert_contains "$TMP/install-fail-auto.out" 'Baton 未就绪'
if HOME="$HOME_FAIL" PATH="$TMP/tools:$PATH" CCGP_PREFIX="$PREFIX_FAIL" CCGP_BINDIR="$BIN_FAIL" \
  CCGP_CONFIG_FILE="$HOME_FAIL/.config/claude-all/config" CLAUDE_ALL_HOME="$HOME_FAIL/.claude-all" \
  CCGP_CONFIG_DIR="$HOME_FAIL/.claude-plbbl" CCGP_TOKEN=test-token CCGP_SKIP_PROBE=1 \
  CCGP_STATUSLINE=no CCGP_BATON=yes bash "$ROOT/install.sh" > "$TMP/install-fail-yes.out" 2>&1; then
  fail '显式 CCGP_BATON=yes 时 Baton 失败应阻断安装'
fi
assert_contains "$TMP/install-fail-yes.out" 'Baton 安装失败'

# No codex in auto mode skips Baton and explains how to opt in.
HOME_AUTO="$TMP/home-auto"; PREFIX_AUTO="$TMP/prefix-auto"; BIN_AUTO="$TMP/bin-auto"
mkdir -p "$HOME_AUTO"
HOME="$HOME_AUTO" PATH="$TMP/no-codex:/usr/bin:/bin" CCGP_PREFIX="$PREFIX_AUTO" CCGP_BINDIR="$BIN_AUTO" \
  CCGP_CONFIG_FILE="$HOME_AUTO/.config/claude-all/config" CLAUDE_ALL_HOME="$HOME_AUTO/.claude-all" \
  CCGP_CONFIG_DIR="$HOME_AUTO/.claude-plbbl" CCGP_TOKEN=test-token CCGP_SKIP_PROBE=1 \
  CCGP_STATUSLINE=no bash "$ROOT/install.sh" > "$TMP/install-auto.out" 2>&1
[ ! -e "$PREFIX_AUTO/baton" ] || fail '没有 codex 时 auto 仍复制了 Baton'
assert_contains "$TMP/install-auto.out" '跳过 Baton'

# Existing user Baton skill/CLI are preserved and managed config links point there.
HOME_USER="$TMP/home-user"; PREFIX_USER="$TMP/prefix-user"; BIN_USER="$TMP/bin-user"
USER_BATON="$TMP/user-baton"
mkdir -p "$HOME_USER/.claude/skills" "$HOME_USER/.local/bin" "$USER_BATON/skills/baton/bin"
printf '%s\n' user > "$USER_BATON/skills/baton/SKILL.md"
printf '%s\n' '#!/usr/bin/env bash' > "$USER_BATON/skills/baton/bin/baton"
chmod +x "$USER_BATON/skills/baton/bin/baton"
ln -s "$USER_BATON/skills/baton" "$HOME_USER/.claude/skills/baton"
ln -s "$USER_BATON/skills/baton/bin/baton" "$HOME_USER/.local/bin/baton"
run_install "$HOME_USER" "$PREFIX_USER" "$BIN_USER" > "$TMP/install-user.out" 2>&1
assert_link_target "$HOME_USER/.claude/skills/baton" "$(python3 - "$USER_BATON/skills/baton" - <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
assert_link_target "$HOME_USER/.local/bin/baton" "$(python3 - "$USER_BATON/skills/baton/bin/baton" - <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
assert_link_target "$HOME_USER/.claude-all/skills/baton" "$(python3 - "$USER_BATON/skills/baton" - <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
assert_contains "$TMP/install-user.out" 'Baton：skill 与受管 config 链接已就绪'

# A pre-existing ordinary config directory is kept byte-for-byte.
HOME_DIR="$TMP/home-dir"; PREFIX_DIR="$TMP/prefix-dir"; BIN_DIR="$TMP/bin-dir"
mkdir -p "$HOME_DIR/.claude-plbbl/skills/baton" "$HOME_DIR"
printf '%s\n' keep > "$HOME_DIR/.claude-plbbl/skills/baton/marker"
run_install "$HOME_DIR" "$PREFIX_DIR" "$BIN_DIR" > "$TMP/install-dir.out" 2>&1
[ -f "$HOME_DIR/.claude-plbbl/skills/baton/marker" ] || fail '预置普通 skills/baton 目录被覆盖'
[ ! -L "$HOME_DIR/.claude-plbbl/skills/baton" ] || fail '预置普通 skills/baton 目录变成软链'

# Only manifest-owned links are removed by uninstall; the user skill survives.
HOME_UN="$TMP/home-uninstall"
mkdir -p "$HOME_UN"
HOME="$HOME_UN" PATH="$TMP/tools:$PATH" CCGP_TOKEN=test-token CCGP_SKIP_PROBE=1 \
  CCGP_STATUSLINE=no CCGP_BATON=yes bash "$ROOT/install.sh" > "$TMP/install-uninstall.out" 2>&1
# Make the vendored target dangling; the manifest still has the exact readlink target.
mv "$HOME_UN/.local/share/claude-all/baton" "$TMP/vendored-target-removed"
HOME="$HOME_UN" PATH="$TMP/tools:$PATH" bash "$ROOT/uninstall.sh" > "$TMP/uninstall.out" 2>&1
[ ! -e "$HOME_UN/.claude-all/skills/baton" ] || fail '卸载未删除 claude-all config Baton 链接'
[ ! -e "$HOME_UN/.claude-plbbl/skills/baton" ] || fail '卸载未删除 plbbl config Baton 链接'
[ ! -e "$HOME_UN/.claude/skills/baton" ] || fail '卸载未删除 vendored 全局 Baton 链接'
[ ! -e "$HOME_UN/.local/bin/baton" ] || fail '卸载未删除 vendored Baton CLI 链接'
[ -d "$HOME_UN/.claude-plbbl.backup."* ] || fail '卸载未保留 plbbl 配置备份'

# User-installed global links survive; claude-all-owned config links and only those links are removed.
HOME_USER_UN="$TMP/home-user-uninstall"; USER_BATON_UN="$TMP/user-baton-uninstall"
mkdir -p "$HOME_USER_UN/.claude/skills" "$HOME_USER_UN/.local/bin" "$HOME_USER_UN/.claude-all/skills" \
  "$HOME_USER_UN/.claude-plbbl/skills" "$USER_BATON_UN/skills/baton/bin"
printf '%s\n' user > "$USER_BATON_UN/skills/baton/marker"
printf '%s\n' '#!/usr/bin/env bash' > "$USER_BATON_UN/skills/baton/bin/baton"
chmod +x "$USER_BATON_UN/skills/baton/bin/baton"
ln -s "$USER_BATON_UN/skills/baton" "$HOME_USER_UN/.claude/skills/baton"
ln -s "$USER_BATON_UN/skills/baton/bin/baton" "$HOME_USER_UN/.local/bin/baton"
ln -s "$USER_BATON_UN/skills/baton" "$HOME_USER_UN/.claude-all/skills/baton"
HOME="$HOME_USER_UN" PATH="$TMP/tools:$PATH" CCGP_TOKEN=test-token CCGP_SKIP_PROBE=1 \
  CCGP_STATUSLINE=no CCGP_BATON=yes bash "$ROOT/install.sh" > "$TMP/install-user-uninstall.out" 2>&1
HOME="$HOME_USER_UN" PATH="$TMP/tools:$PATH" bash "$ROOT/uninstall.sh" > "$TMP/uninstall-user.out" 2>&1
assert_link_target "$HOME_USER_UN/.claude/skills/baton" "$USER_BATON_UN/skills/baton"
assert_link_target "$HOME_USER_UN/.local/bin/baton" "$USER_BATON_UN/skills/baton/bin/baton"
assert_link_target "$HOME_USER_UN/.claude-all/skills/baton" "$USER_BATON_UN/skills/baton"
[ ! -e "$HOME_USER_UN/.claude-plbbl/skills/baton" ] || fail '卸载未删除 claude-all 建的用户来源 config 链接'

printf 'PASS: Baton vendor/install/link/manifest/uninstall tests\n'
