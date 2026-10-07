#!/usr/bin/env bash
# Synchronize the vendored Baton tree from a clean local checkout.
set -euo pipefail

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
_ROOT="$(cd "$_SELF_DIR/.." >/dev/null 2>&1 && pwd)"
_VENDOR="$_ROOT/baton"
_CHECK=0
_TMP=""
trap '[ -z "${_TMP:-}" ] || rm -rf "$_TMP"' EXIT INT TERM

usage() {
  cat >&2 <<'USAGE'
用法: scripts/sync-baton.sh [--check] /path/to/Baton

默认同步 git HEAD 中跟踪的 skills/baton、council、install.sh、LICENSE 和 README.md。
--check 只比较跟踪文件，不写入文件。
USAGE
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) _CHECK=1; shift ;;
    -h|--help) usage ;;
    -*) echo "未知参数：$1" >&2; usage ;;
    *) break ;;
  esac
done
[ "$#" -eq 1 ] || usage
_SOURCE="$1"
[ -d "$_SOURCE" ] || { echo "Baton checkout 不存在：$_SOURCE" >&2; exit 1; }
_SOURCE="$(cd "$_SOURCE" >/dev/null 2>&1 && pwd)"
command -v git >/dev/null 2>&1 || { echo "同步 Baton 需要 git。" >&2; exit 1; }
git -C "$_SOURCE" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "上游路径不是 git checkout：$_SOURCE" >&2
  exit 1
}

_paths="skills/baton council install.sh LICENSE README.md"
for _path in $_paths; do
  git -C "$_SOURCE" ls-files --error-unmatch -- "$_path" >/dev/null 2>&1 || {
    echo "上游 git 中缺少跟踪路径：$_path" >&2
    exit 1
  }
done
_dirty="$(git -C "$_SOURCE" status --porcelain --untracked-files=all -- $_paths)"
if [ -n "$_dirty" ]; then
  echo "拒绝同步：上游 checkout 在同步路径有未提交改动：" >&2
  printf '%s\n' "$_dirty" >&2
  exit 1
fi

_COMMIT="$(git -C "$_SOURCE" rev-parse HEAD)"
_TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-all-baton-sync.XXXXXX")"
git -C "$_SOURCE" archive --format=tar HEAD -- $_paths | tar -x -C "$_TMP"

_compare_tracked() {
  local path="$1"
  diff -uN "$_TMP/$path" "$_VENDOR/$path"
}

_ok=1
while IFS= read -r _path; do
  [ -n "$_path" ] || continue
  _compare_tracked "$_path" || _ok=0
done <<EOF_FILES
$(git -C "$_SOURCE" ls-files -- $_paths)
EOF_FILES
if [ "$_CHECK" -eq 1 ]; then
  if [ "$_ok" -ne 1 ]; then
    echo "Baton vendored files differ from upstream $_SOURCE @ $_COMMIT (local multi-agent branch; differences are expected)" >&2
  else
    echo "Baton vendored files match upstream $_SOURCE @ $_COMMIT"
  fi
  exit 0
fi

rm -rf "$_VENDOR/skills" "$_VENDOR/council" \
  "$_VENDOR/install.sh" "$_VENDOR/LICENSE" "$_VENDOR/README.md"
cp -R "$_TMP/skills" "$_VENDOR/"
cp -R "$_TMP/council" "$_VENDOR/"
cp "$_TMP/install.sh" "$_TMP/LICENSE" "$_TMP/README.md" "$_VENDOR/"

_sync_date="$(date '+%Y-%m-%d')"
cat > "$_VENDOR/UPSTREAM" <<META
repository: https://github.com/Valdemar-Yu/Baton
commit: $_COMMIT
synced_at: $_sync_date

Local branch:
- claude-all multi-agent branch; vendored files intentionally diverge from upstream.
- Executor adapters: codex and claude; configurable conductor/judge/council roles.
- Setup, doctor, statusline, council generation and claude-all integration are maintained locally.
META
chmod +x "$_VENDOR/install.sh" "$_VENDOR/skills/baton/bin/baton" "$_VENDOR/skills/baton/scripts"/*.py
printf 'Synced Baton %s from %s\n' "$_COMMIT" "$_SOURCE"
