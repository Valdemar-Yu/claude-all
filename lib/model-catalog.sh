#!/usr/bin/env bash
# Models API 发现辅助函数。调用后通过 CLAUDE_ALL_CATALOG_MODELS / CLAUDE_ALL_CATALOG_ERROR 返回结果。

_claude_all_models_endpoint() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit

url = sys.argv[1].strip()
parts = urlsplit(url)
if (not parts.scheme or not parts.netloc or parts.username or parts.password
        or any(char.isspace() for char in url)):
    raise SystemExit(2)
path = parts.path.rstrip("/")
for suffix in ("/chat/completions", "/responses", "/messages"):
    if path.endswith(suffix):
        path = path[:-len(suffix)].rstrip("/")
        break
if path.endswith("/models"):
    pass
elif path.endswith("/v1"):
    path += "/models"
else:
    path += "/v1/models"
print(urlunsplit((parts.scheme, parts.netloc, path, parts.query, "")))
PY
}

_claude_all_models_url_is_safe() {
  python3 - "$1" <<'PY'
import ipaddress
import sys
from urllib.parse import urlsplit

parts = urlsplit(sys.argv[1])
if parts.scheme == "https":
    raise SystemExit(0)
if parts.scheme != "http":
    raise SystemExit(1)
host = parts.hostname or ""
if host == "localhost":
    raise SystemExit(0)
try:
    if ipaddress.ip_address(host).is_loopback:
        raise SystemExit(0)
except ValueError:
    pass
raise SystemExit(1)
PY
}

_claude_all_models_page_url() {
  python3 - "$1" "${2:-}" "$3" <<'PY'
import sys
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

url, cursor, protocol = sys.argv[1:4]
parts = urlsplit(url)
query = parse_qsl(parts.query, keep_blank_values=True)
if protocol == "anthropic":
    keys = {key for key, _ in query}
    if "limit" not in keys:
        query.append(("limit", "1000"))
    if cursor:
        query = [(key, value) for key, value in query if key != "after_id"]
        query.append(("after_id", cursor))
print(urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query), parts.fragment)))
PY
}

_claude_all_parse_models_page() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import re
import sys

body_path, models_path, meta_path = sys.argv[1:4]
try:
    with open(body_path, encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception as exc:
    raise SystemExit(f"响应不是有效 JSON: {exc}")

if not isinstance(payload, dict) or not isinstance(payload.get("data"), list):
    raise SystemExit("响应缺少 data 数组")

try:
    with open(models_path, encoding="utf-8") as handle:
        seen = {line.rstrip("\n") for line in handle if line.rstrip("\n")}
except FileNotFoundError:
    seen = set()

added = []
last_data_id = ""
for item in payload["data"]:
    if not isinstance(item, dict) or not isinstance(item.get("id"), str):
        continue
    model_id = item["id"].strip()
    if not model_id or len(model_id) > 512 or not re.fullmatch(r"[A-Za-z0-9._:/@+\[\]-]+", model_id):
        continue
    last_data_id = model_id
    if model_id not in seen:
        seen.add(model_id)
        added.append(model_id)

with open(models_path, "a", encoding="utf-8") as handle:
    for model_id in added:
        handle.write(model_id + "\n")

has_more = payload.get("has_more") is True
last_id = payload.get("last_id") if isinstance(payload.get("last_id"), str) else last_data_id
with open(meta_path, "w", encoding="utf-8") as handle:
    handle.write(("1" if has_more else "0") + "\n")
    handle.write((last_id or "") + "\n")
PY
}

_claude_all_write_auth_headers() {
  printf 'Accept: application/json\n'
  if [ "$1" = anthropic ]; then
    printf 'x-api-key: %s\n' "$2"
    printf 'anthropic-version: 2023-06-01\n'
  elif [ "$1" = anthropic-bearer ]; then
    printf 'Authorization: Bearer %s\n' "$2"
    printf 'anthropic-version: 2023-06-01\n'
  else
    printf 'Authorization: Bearer %s\n' "$2"
  fi
  printf '\n'
}

_claude_all_catalog_fetch() {
  local proto="$1" base="$2" api_key="$3"
  local tmp endpoint cursor="" page=0 status url has_more=0 last_id auth_mode parse_error
  local body_file models_file meta_file curl_error

  CLAUDE_ALL_CATALOG_MODELS=()
  CLAUDE_ALL_CATALOG_ERROR=""
  CLAUDE_ALL_CATALOG_AUTH_MODE=""

  case "$base$api_key" in
    *$'\n'*|*$'\r'*) CLAUDE_ALL_CATALOG_ERROR="base_url 或 api_key 含换行"; return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || { CLAUDE_ALL_CATALOG_ERROR="缺少 curl"; return 1; }
  command -v python3 >/dev/null 2>&1 || { CLAUDE_ALL_CATALOG_ERROR="缺少 python3"; return 1; }

  endpoint="$(_claude_all_models_endpoint "$base" 2>/dev/null)" || {
    CLAUDE_ALL_CATALOG_ERROR="base_url 无法解析"
    return 1
  }
  case "$endpoint" in
    http://*|https://*) : ;;
    *) CLAUDE_ALL_CATALOG_ERROR="base_url 必须以 http:// 或 https:// 开头"; return 1 ;;
  esac
  if ! _claude_all_models_url_is_safe "$endpoint"; then
    CLAUDE_ALL_CATALOG_ERROR="带 API key 的远程 Models 请求只允许 HTTPS（HTTP 仅允许 localhost/loopback）"
    return 1
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-all-models.XXXXXX")" || {
    CLAUDE_ALL_CATALOG_ERROR="无法创建临时目录"
    return 1
  }
  chmod 700 "$tmp" 2>/dev/null || true
  body_file="$tmp/body.json"; models_file="$tmp/models"; meta_file="$tmp/meta"; curl_error="$tmp/curl.err"
  : > "$models_file"
  chmod 600 "$models_file" 2>/dev/null || true

  auth_mode="$proto"
  while [ "$page" -lt 20 ]; do
    page=$(( page + 1 ))
    url="$(_claude_all_models_page_url "$endpoint" "$cursor" "$proto" 2>/dev/null)" || {
      CLAUDE_ALL_CATALOG_ERROR="Models URL 无法生成"
      rm -rf "$tmp"
      return 1
    }

    # --header @- 从 stdin 读取认证头，API key 不进入 argv 或临时文件。
    if ! status="$(_claude_all_write_auth_headers "$auth_mode" "$api_key" \
      | curl --silent --show-error --connect-timeout 10 --max-time 30 \
        --output "$body_file" --write-out '%{http_code}' --header @- "$url" 2>"$curl_error")"; then
      CLAUDE_ALL_CATALOG_ERROR="Models API 网络请求失败"
      rm -rf "$tmp"
      return 1
    fi

    if [ "$proto" = anthropic ] && [ "$auth_mode" = anthropic ] && { [ "$status" = 401 ] || [ "$status" = 403 ]; }; then
      auth_mode=anthropic-bearer
      page=$(( page - 1 ))
      continue
    fi
    if [ "$proto" = openai ] && [ "$auth_mode" = openai ] && { [ "$status" = 401 ] || [ "$status" = 403 ]; }; then
      auth_mode=openai-api-key
      page=$(( page - 1 ))
      continue
    fi
    if [ "$status" -lt 200 ] 2>/dev/null || [ "$status" -ge 300 ] 2>/dev/null; then
      CLAUDE_ALL_CATALOG_ERROR="Models API 返回 HTTP $status"
      rm -rf "$tmp"
      return 1
    fi

    if ! _claude_all_parse_models_page "$body_file" "$models_file" "$meta_file" 2>"$tmp/parse.err"; then
      parse_error="$(tr '\n\r' '  ' < "$tmp/parse.err")"
      CLAUDE_ALL_CATALOG_ERROR="${parse_error:-Models 响应解析失败}"
      rm -rf "$tmp"
      return 1
    fi
    has_more="$(sed -n '1p' "$meta_file")"
    last_id="$(sed -n '2p' "$meta_file")"
    [ "$has_more" = 1 ] && [ -n "$last_id" ] || break
    if [ "$last_id" = "$cursor" ]; then
      CLAUDE_ALL_CATALOG_ERROR="Models API 分页 cursor 未推进"
      rm -rf "$tmp"
      return 1
    fi
    cursor="$last_id"
  done
  if [ "$has_more" = 1 ]; then
    CLAUDE_ALL_CATALOG_ERROR="Models API 超过 20 页，未保存不完整列表"
    rm -rf "$tmp"
    return 1
  fi

  while IFS= read -r model_id; do
    [ -n "$model_id" ] && CLAUDE_ALL_CATALOG_MODELS+=("$model_id")
  done < "$models_file"
  rm -rf "$tmp"

  if [ "${#CLAUDE_ALL_CATALOG_MODELS[@]}" -eq 0 ]; then
    CLAUDE_ALL_CATALOG_ERROR="Models API 未返回模型 ID"
    return 1
  fi
  CLAUDE_ALL_CATALOG_AUTH_MODE="$auth_mode"
  return 0
}
