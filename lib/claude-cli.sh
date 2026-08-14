#!/usr/bin/env bash
# Claude CLI runtime discovery, validation, and update-safe snapshots.
# shellcheck shell=bash

_claude_all_realpath() {
  local source="$1" dir
  while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)" || return 1
    source="$(readlink "$source")" || return 1
    case "$source" in /*) : ;; *) source="$dir/$source" ;; esac
  done
  dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$source")"
}

_claude_all_claude_version() {
  local candidate="$1" output
  [ -n "$candidate" ] && [ -x "$candidate" ] || return 1
  output="$("$candidate" --version 2>/dev/null)" || return 1
  case "$output" in
    *'Claude Code'*) printf '%s\n' "$output" ;;
    *) return 1 ;;
  esac
}

_claude_all_install_runtime() {
  local source="$1" runtime_dir="$2" resolved tmp version
  version="$(_claude_all_claude_version "$source")" || return 1
  resolved="$(_claude_all_realpath "$source")" || return 1
  mkdir -p "$runtime_dir" || return 1
  chmod 700 "$runtime_dir" 2>/dev/null || true
  tmp="$runtime_dir/.claude.tmp.$$"
  rm -f "$tmp"
  if ! ln "$resolved" "$tmp" 2>/dev/null; then
    cp "$resolved" "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  chmod 755 "$tmp" || { rm -f "$tmp"; return 1; }
  _claude_all_claude_version "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$runtime_dir/claude" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$version"
}

_claude_all_activate_runtime() {
  local runtime_dir="$1" candidate="$1/claude"
  _claude_all_claude_version "$candidate" >/dev/null 2>&1 || return 1
  candidate="$(_claude_all_realpath "$candidate")" || return 1
  case ":$PATH:" in
    *":$runtime_dir:"*) : ;;
    *) PATH="$runtime_dir:$PATH" ;;
  esac
  export PATH
  export CLAUDE_PATH="$candidate"
  if [ "${CLAUDE_ALL_ALLOW_AUTOUPDATE:-0}" != 1 ]; then
    export DISABLE_AUTOUPDATER=1
  fi
}

_claude_all_resolve_claude() {
  local runtime_dir="$1" candidate
  if [ -n "${CLAUDE_ALL_CLAUDE_BIN:-}" ]; then
    _claude_all_claude_version "$CLAUDE_ALL_CLAUDE_BIN" >/dev/null 2>&1 || return 1
    _claude_all_realpath "$CLAUDE_ALL_CLAUDE_BIN"
    return
  fi
  candidate="$runtime_dir/claude"
  if _claude_all_claude_version "$candidate" >/dev/null 2>&1; then
    _claude_all_realpath "$candidate"
    return
  fi
  candidate="$(command -v claude 2>/dev/null || true)"
  [ -n "$candidate" ] || return 1
  _claude_all_claude_version "$candidate" >/dev/null 2>&1 || return 1
  _claude_all_realpath "$candidate"
}

_claude_all_claude_error() {
  cat >&2 <<'EOF'
Claude CLI 缺失或已损坏（`claude --version` 未通过）。
claude-all 不会继续启动，避免所有 profile 进入同一个损坏运行时。

修复后请重新运行安装器，生成经过验证的隔离 runtime：
  npm install -g @anthropic-ai/claude-code@stable
  ./install.sh

也可以使用 Anthropic 推荐的 native installer，再运行 ./install.sh。
用 `claude-all doctor` 查看诊断；项目默认禁用后台自动更新，手动更新后重跑安装器即可原子刷新 runtime。
EOF
}
