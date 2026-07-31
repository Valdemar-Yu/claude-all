#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-all-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/bin" "$TMP/home/.claude-all/profiles"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 缺少: $2"; }
assert_not_contains() { ! grep -F -- "$2" "$1" >/dev/null || fail "$1 不应包含: $2"; }
assert_eq() { [ "$1" = "$2" ] || fail "期望 '$2'，实际 '$1'"; }

cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""; write=""; url=""; header_source=""; headers=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --write-out) write="$2"; shift 2 ;;
    --header) header_source="$2"; shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    --silent|--show-error) shift ;;
    *)
      case "$1" in *TEST_SECRET*) echo 'secret leaked into curl argv' >&2; exit 90 ;; esac
      url="$1"; shift
      ;;
  esac
done
[ -n "$out" ] || exit 91
[ "$header_source" = @- ] || exit 92
headers="$(cat)"
case "${MOCK_MODE:-ok}" in
  ok)
    cat > "$out" <<'JSON'
{"object":"list","data":[{"id":"gpt-main"},{"id":"gpt-sub"},{"id":"gpt-team"}],"has_more":false}
JSON
    status=200
    ;;
  anthropic)
    case "$headers" in *'x-api-key: '*) : ;; *) exit 93 ;; esac
    cat > "$out" <<'JSON'
{"data":[{"id":"claude-main"},{"id":"claude-fast"}],"has_more":false,"last_id":"claude-fast"}
JSON
    status=200
    ;;
  bad-json) printf 'not-json' > "$out"; status=200 ;;
  http-error) printf '{"error":"denied"}' > "$out"; status=404 ;;
esac
printf '%s' "$status"
SH
chmod +x "$TMP/bin/curl"

# URL 规范化与模型解析。
# shellcheck source=/dev/null
source "$ROOT/lib/model-catalog.sh"
assert_eq "$(_claude_all_models_endpoint 'https://relay.example/v1')" 'https://relay.example/v1/models'
assert_eq "$(_claude_all_models_endpoint 'https://relay.example/team/chat/completions')" 'https://relay.example/team/v1/models'
if PATH="$TMP/bin:$PATH" MOCK_MODE=ok _claude_all_catalog_fetch openai 'http://relay.example/team' 'TEST_SECRET'; then
  fail '远程 HTTP Models URL 应被拒绝'
fi
assert_contains <(printf '%s' "$CLAUDE_ALL_CATALOG_ERROR") '只允许 HTTPS'
PATH="$TMP/bin:$PATH" MOCK_MODE=ok _claude_all_catalog_fetch openai 'https://relay.example/team' 'TEST_SECRET'
assert_eq "${#CLAUDE_ALL_CATALOG_MODELS[@]}" '3'
assert_eq "${CLAUDE_ALL_CATALOG_MODELS[1]}" 'gpt-sub'
if PATH="$TMP/bin:$PATH" MOCK_MODE=bad-json _claude_all_catalog_fetch openai 'https://relay.example' 'TEST_SECRET'; then
  fail '非法 JSON 应失败'
fi
case "$CLAUDE_ALL_CATALOG_ERROR" in *'有效 JSON'*) : ;; *) fail "非法 JSON 错误信息不明确: $CLAUDE_ALL_CATALOG_ERROR" ;; esac

# OpenAI add：模型多选、三角色、API key 安全 quoting。
PWNED="$TMP/pwned"
KEY='TEST_SECRET$(touch '$PWNED')'
printf '%s\n' \
  relay openai 'https://relay.example/team' "$KEY" \
  a 1 2 3 n \
  | env HOME="$TMP/home" PATH="$TMP/bin:$PATH" MOCK_MODE=ok CLAUDE_ALL_PROFILES_DIR="$TMP/home/.claude-all/profiles" \
      "$ROOT/bin/claude-all" add > "$TMP/add-openai.out" 2> "$TMP/add-openai.err"
PROFILE="$TMP/home/.claude-all/profiles/relay.env"
[ -f "$PROFILE" ] || fail '没有生成 OpenAI profile'
[ "$(stat -f '%Lp' "$PROFILE" 2>/dev/null || stat -c '%a' "$PROFILE")" = 600 ] || fail 'profile 权限不是 600'
assert_contains "$PROFILE" 'CLAUDE_ALL_SCHEMA=2'
assert_contains "$PROFILE" 'CLAUDE_ALL_DEFAULT_MODEL=gpt-main'
assert_contains "$PROFILE" 'CLAUDE_ALL_SUBAGENT_MODEL=gpt-sub'
assert_contains "$PROFILE" 'CLAUDE_ALL_TEAM_MODEL=gpt-team'
(
  set -a
  # shellcheck disable=SC1090
  source "$PROFILE"
  set +a
  [ "$OPENAI_API_KEY" = "$KEY" ]
) || fail 'profile source 后 key 不一致'
[ ! -e "$PWNED" ] || fail 'source profile 执行了 API key 中的命令替换'

# 新版 claudish profile 必须走三个 role map，不能退回单一 explicit primary。
env HOME="$TMP/home" PATH="$TMP/bin:$PATH" CLAUDE_ALL_PROFILES_DIR="$TMP/home/.claude-all/profiles" CLAUDE_ALL_DRY_RUN=1 \
  "$ROOT/bin/claude-all" relay > "$TMP/dry-openai.out"
assert_contains "$TMP/dry-openai.out" 'roles: main=gpt-main subagent=gpt-sub teammate=gpt-team'
assert_contains "$TMP/dry-openai.out" '--model-opus oai@gpt-main'
assert_contains "$TMP/dry-openai.out" '--model-sonnet oai@gpt-sub'
assert_contains "$TMP/dry-openai.out" '--model-haiku oai@gpt-team'
assert_not_contains "$TMP/dry-openai.out" 'claudish --model oai@gpt-main'
assert_not_contains "$TMP/dry-openai.out" 'TEST_SECRET'

# Models API 失败时允许手动输入；direct profile 生成相同的角色语义。
printf '%s\n' \
  direct-api anthropic 'https://anthropic.example' 'TEST_SECRET' \
  'claude-main,claude-fast' 1 2 1 n \
  | env HOME="$TMP/home" PATH="$TMP/bin:$PATH" MOCK_MODE=http-error CLAUDE_ALL_PROFILES_DIR="$TMP/home/.claude-all/profiles" \
      "$ROOT/bin/claude-all" add > "$TMP/add-direct.out" 2> "$TMP/add-direct.err"
DIRECT="$TMP/home/.claude-all/profiles/direct-api.env"
assert_contains "$DIRECT" 'CLAUDE_ALL_PROTOCOL=anthropic'
assert_contains "$DIRECT" 'CLAUDE_ALL_DEFAULT_MODEL=claude-main'
assert_contains "$DIRECT" 'CLAUDE_ALL_SUBAGENT_MODEL=claude-fast'
assert_contains "$TMP/add-direct.err" 'HTTP 404'
env HOME="$TMP/home" PATH="$TMP/bin:$PATH" CLAUDE_ALL_PROFILES_DIR="$TMP/home/.claude-all/profiles" CLAUDE_ALL_DRY_RUN=1 \
  "$ROOT/bin/claude-all" direct-api > "$TMP/dry-direct.out"
assert_contains "$TMP/dry-direct.out" 'ANTHROPIC_DEFAULT_OPUS_MODEL=claude-main'
assert_contains "$TMP/dry-direct.out" 'ANTHROPIC_DEFAULT_SONNET_MODEL=claude-fast'
assert_contains "$TMP/dry-direct.out" 'would exec: claude --settings <agent-routing-json> --model opus'

# 旧 cmd profile 与 plbbl 首项兼容。
cat > "$TMP/home/.claude-all/profiles/claude-plbbl.env" <<'EOF'
CLAUDE_ALL_LAUNCH=cmd
CLAUDE_ALL_CMD=claude-plbbl
CLAUDE_ALL_LABEL="plbbl"
EOF
cat > "$TMP/home/.claude-all/profiles/aaa.env" <<'EOF'
CLAUDE_ALL_LAUNCH=cmd
CLAUDE_ALL_CMD=claude
EOF
env HOME="$TMP/home" CLAUDE_ALL_PROFILES_DIR="$TMP/home/.claude-all/profiles" "$ROOT/bin/claude-all" list > "$TMP/list.out"
first="$(sed -n '1p' "$TMP/list.out")"
case "$first" in *claude-plbbl*) : ;; *) fail "plbbl 不是首项: $first" ;; esac

printf 'PASS: claude-all model wizard tests\n'
