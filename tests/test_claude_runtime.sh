#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-all-runtime-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/good-bin" "$TMP/bad-bin" "$TMP/home/.claude-all/profiles"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 缺少: $2"; }
assert_eq() { [ "$1" = "$2" ] || fail "期望 '$2'，实际 '$1'"; }

cat > "$TMP/good-bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then
  printf '9.9.9 (Claude Code)\n'
  exit 0
fi
printf 'CLAUDE_OK DISABLE_AUTOUPDATER=%s ARGS=' "${DISABLE_AUTOUPDATER:-}"
printf ' <%s>' "$@"
printf '\n'
SH
chmod +x "$TMP/good-bin/claude"

cat > "$TMP/bad-bin/claude" <<'SH'
#!/usr/bin/env bash
exit 137
SH
chmod +x "$TMP/bad-bin/claude"

# shellcheck source=/dev/null
source "$ROOT/lib/claude-cli.sh"

assert_eq "$(_claude_all_claude_version "$TMP/good-bin/claude")" '9.9.9 (Claude Code)'
if _claude_all_claude_version "$TMP/bad-bin/claude" >/dev/null 2>&1; then
  fail '损坏的 Claude CLI 不应通过健康检查'
fi
if _claude_all_claude_version "$TMP/missing" >/dev/null 2>&1; then
  fail '缺失的 Claude CLI 不应通过健康检查'
fi

RUNTIME="$TMP/runtime/bin"
_claude_all_install_runtime "$TMP/good-bin/claude" "$RUNTIME" >/dev/null
[ -x "$RUNTIME/claude" ] || fail '没有安装隔离 Claude runtime'
assert_eq "$(_claude_all_claude_version "$RUNTIME/claude")" '9.9.9 (Claude Code)'

# 更新源损坏时，必须保留上一个健康 runtime。
if _claude_all_install_runtime "$TMP/bad-bin/claude" "$RUNTIME" >/dev/null 2>&1; then
  fail '损坏的更新源不应覆盖 runtime'
fi
assert_eq "$(_claude_all_claude_version "$RUNTIME/claude")" '9.9.9 (Claude Code)'

PATH="$TMP/bad-bin:/usr/bin:/bin"
CLAUDE_ALL_RUNTIME_DIR="$RUNTIME"
_claude_all_activate_runtime "$RUNTIME"
assert_eq "$(claude --version)" '9.9.9 (Claude Code)'
assert_eq "${DISABLE_AUTOUPDATER:-}" '1'
assert_eq "${CLAUDE_PATH:-}" "$(_claude_all_realpath "$RUNTIME/claude")"
assert_eq "$(_claude_all_resolve_claude "$RUNTIME")" "$(_claude_all_realpath "$RUNTIME/claude")"

# 三种 launch 路径必须都使用隔离 runtime；覆盖五个保留环境。
cat > "$TMP/good-bin/claudish" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
claude --version >/dev/null
printf 'CLAUDISH_OK CLAUDE_PATH=%s ARGS=' "${CLAUDE_PATH:-}"
printf ' <%s>' "$@"
printf '\n'
SH
chmod +x "$TMP/good-bin/claudish"
cat > "$TMP/good-bin/claude-glm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec claude "$@"
SH
chmod +x "$TMP/good-bin/claude-glm"

cat > "$TMP/home/.claude-all/profiles/claude.env" <<'EOF'
CLAUDE_ALL_LAUNCH=cmd
CLAUDE_ALL_CMD=claude
EOF
cat > "$TMP/home/.claude-all/profiles/claude-glm.env" <<'EOF'
CLAUDE_ALL_LAUNCH=cmd
CLAUDE_ALL_CMD=claude-glm
EOF
cat > "$TMP/home/.claude-all/profiles/claude-plbbl.env" <<'EOF'
CLAUDE_ALL_LAUNCH=claudish
CLAUDE_ALL_MODEL=oai@gpt-test
OPENAI_BASE_URL=https://relay.example/v1
OPENAI_API_KEY=TEST_SECRET
EOF
cat > "$TMP/home/.claude-all/profiles/deepseek.env" <<'EOF'
CLAUDE_ALL_LAUNCH=claudish
CLAUDE_ALL_MODEL=oai@deepseek-test
OPENAI_BASE_URL=https://api.deepseek.example/v1
OPENAI_API_KEY=TEST_SECRET
EOF
cat > "$TMP/home/.claude-all/profiles/kimi-cc.env" <<'EOF'
CLAUDE_ALL_LAUNCH=direct
ANTHROPIC_BASE_URL=https://api.kimi.example/coding/
ANTHROPIC_AUTH_TOKEN=TEST_SECRET
ANTHROPIC_MODEL=kimi-test
EOF

COMMON_PATH="$TMP/good-bin:$TMP/bad-bin:/usr/bin:/bin"
for profile in claude claude-glm kimi-cc; do
  env HOME="$TMP/home" PATH="$COMMON_PATH" CLAUDE_ALL_RUNTIME_DIR="$RUNTIME" \
    CLAUDE_ALL_PROFILES_DIR="$TMP/home/.claude-all/profiles" \
    "$ROOT/bin/claude-all" "$profile" --test "$profile" > "$TMP/$profile.out"
  assert_contains "$TMP/$profile.out" 'CLAUDE_OK DISABLE_AUTOUPDATER=1'
done
for profile in claude-plbbl deepseek; do
  env HOME="$TMP/home" PATH="$COMMON_PATH" CLAUDE_ALL_RUNTIME_DIR="$RUNTIME" \
    CLAUDE_ALL_PROFILES_DIR="$TMP/home/.claude-all/profiles" \
    "$ROOT/bin/claude-all" "$profile" --test "$profile" > "$TMP/$profile.out"
  assert_contains "$TMP/$profile.out" 'CLAUDISH_OK'
done

env HOME="$TMP/home" PATH="$COMMON_PATH" CLAUDE_ALL_RUNTIME_DIR="$RUNTIME" \
  CLAUDE_ALL_PROFILES_DIR="$TMP/home/.claude-all/profiles" \
  "$ROOT/bin/claude-all" doctor > "$TMP/doctor-ok.out"
assert_contains "$TMP/doctor-ok.out" 'Claude runtime: OK'
assert_contains "$TMP/doctor-ok.out" 'Global Claude CLI: OK'
assert_contains "$TMP/doctor-ok.out" '5 profile(s): OK'

if env HOME="$TMP/home" PATH="$COMMON_PATH" CLAUDE_ALL_RUNTIME_DIR="$TMP/missing-runtime" \
  CLAUDE_ALL_PROFILES_DIR="$TMP/home/.claude-all/profiles" \
  "$ROOT/bin/claude-all" doctor > "$TMP/doctor-fallback.out" 2>&1; then
  fail 'doctor 不应把全局 Claude 回退误报成隔离 runtime 健康'
fi
assert_contains "$TMP/doctor-fallback.out" 'Claude runtime: FAIL'
assert_contains "$TMP/doctor-fallback.out" 'Global Claude CLI: OK'

if env HOME="$TMP/home" PATH="$TMP/bad-bin:/usr/bin:/bin" CLAUDE_ALL_RUNTIME_DIR="$TMP/missing-runtime" \
  CLAUDE_ALL_PROFILES_DIR="$TMP/home/.claude-all/profiles" \
  "$ROOT/bin/claude-all" doctor > "$TMP/doctor-bad.out" 2>&1; then
  fail 'doctor 不应放过缺失/损坏的 Claude CLI'
fi
assert_contains "$TMP/doctor-bad.out" 'Claude runtime: FAIL'

# 安装器要把健康 CLI 固化为隔离 runtime，并且不再自动添加 Fugu。
cat > "$TMP/good-bin/claude-fugu" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/good-bin/claude-fugu"
INSTALL_HOME="$TMP/install-home"
INSTALL_PREFIX="$TMP/install-prefix"
mkdir -p "$INSTALL_HOME/.claude-all/profiles"
cat > "$INSTALL_HOME/.claude-all/profiles/claude.env" <<'EOF'
# claude — claude-all 内置 profile(可改可删)
CLAUDE_ALL_LAUNCH=cmd
CLAUDE_ALL_CMD=claude
CLAUDE_ALL_LABEL="cc-switch 当前源"
EOF
cat > "$INSTALL_HOME/.claude-all/profiles/deepseek.env" <<'EOF'
CLAUDE_ALL_LAUNCH=claudish
CLAUDE_ALL_MODEL=oai@deepseek-test
OPENAI_BASE_URL=https://api.deepseek.example/v1
OPENAI_API_KEY=TEST_SECRET
EOF
cat > "$INSTALL_HOME/.claude-all/profiles/kimi-cc.env" <<'EOF'
CLAUDE_ALL_LAUNCH=direct
ANTHROPIC_BASE_URL=https://api.kimi.example/coding/
ANTHROPIC_AUTH_TOKEN=TEST_SECRET
ANTHROPIC_MODEL=kimi-test
EOF
if ! env HOME="$INSTALL_HOME" PATH="$TMP/good-bin:/usr/bin:/bin" \
  CCGP_PREFIX="$INSTALL_PREFIX" CCGP_BINDIR="$TMP/install-bin" \
  CCGP_CONFIG_FILE="$TMP/install-config" CLAUDE_ALL_HOME="$INSTALL_HOME/.claude-all" \
  CCGP_TOKEN=TEST_SECRET CCGP_SKIP_PROBE=1 CCGP_STATUSLINE=no \
  bash "$ROOT/install.sh" > "$TMP/install.out" 2> "$TMP/install.err"; then
  printf '%s\n' '--- installer stdout ---' >&2
  sed -E 's/(KEY|TOKEN|SECRET)=?[^ ]*/\1=<redacted>/g' "$TMP/install.out" >&2 || true
  printf '%s\n' '--- installer stderr ---' >&2
  sed -E 's/(KEY|TOKEN|SECRET)=?[^ ]*/\1=<redacted>/g' "$TMP/install.err" >&2 || true
  fail '安装器执行失败'
fi
assert_eq "$(_claude_all_claude_version "$INSTALL_PREFIX/runtime/bin/claude")" '9.9.9 (Claude Code)'
[ ! -f "$INSTALL_HOME/.claude-all/profiles/claude-fugu.env" ] || fail '安装器不应再创建 Fugu profile'
profile_names="$(find "$INSTALL_HOME/.claude-all/profiles" -maxdepth 1 -name '*.env' -exec basename {} .env \; | sort | tr '\n' ' ' | sed 's/ $//')"
assert_eq "$profile_names" 'claude claude-glm claude-plbbl deepseek kimi-cc'
assert_contains "$INSTALL_HOME/.claude-all/profiles/claude.env" 'CLAUDE_ALL_LAUNCH=direct'
assert_contains "$INSTALL_HOME/.claude-all/profiles/claude.env" 'Claude 官方'
if grep -q '^CLAUDE_ALL_CMD=' "$INSTALL_HOME/.claude-all/profiles/claude.env"; then
  fail '官方 Claude profile 不应继承 CC Switch 的 cmd/settings 污染'
fi

printf 'PASS: claude runtime resilience tests\n'
