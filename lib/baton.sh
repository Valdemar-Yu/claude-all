#!/usr/bin/env bash
# Baton integration helpers. Sourced by install, launch and uninstall scripts.
# The manifest is the ownership boundary: only links recorded by claude-all may
# be removed later. Existing user files and links stay untouched.

_claude_all_baton_init() {
  : "${CLAUDE_ALL_BATON_PREFIX:=${CCGP_PREFIX:-${_PREFIX:-$HOME/.local/share/claude-all}}}"
  : "${CLAUDE_ALL_BATON_VENDOR_DIR:=$CLAUDE_ALL_BATON_PREFIX/baton}"
  : "${CLAUDE_ALL_BATON_LINKS_FILE:=$CLAUDE_ALL_BATON_PREFIX/baton-links}"
  : "${CLAUDE_ALL_BATON_GLOBAL_SKILL:=$HOME/.claude/skills/baton}"
  : "${CLAUDE_ALL_BATON_GLOBAL_COUNCIL:=$HOME/.claude/skills/council}"
  : "${CLAUDE_ALL_BATON_GLOBAL_BIN:=$HOME/.local/bin/baton}"
}

_baton_path_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

# Portable realpath for paths whose final component may be a symlink.
_baton_resolve_path() {
  local path="$1" link dir depth="${2:-0}"
  [ "$depth" -lt 40 ] || return 1
  if [ -L "$path" ]; then
    link="$(readlink "$path")"
    case "$link" in
      /*) path="$link" ;;
      *) path="$(dirname "$path")/$link" ;;
    esac
    _baton_resolve_path "$path" $((depth + 1))
    return
  fi
  if [ -d "$path" ]; then
    (cd -P "$path" >/dev/null 2>&1 && pwd)
    return
  fi
  dir="$(cd -P "$(dirname "$path")" >/dev/null 2>&1 && pwd)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

_baton_manifest_has_path() {
  local path="$1"
  [ -f "$CLAUDE_ALL_BATON_LINKS_FILE" ] || return 1
  awk -F '\t' -v p="$path" '$1 == p { found=1 } END { exit(found ? 0 : 1) }' \
    "$CLAUDE_ALL_BATON_LINKS_FILE"
}

_baton_manifest_target() {
  local path="$1"
  [ -f "$CLAUDE_ALL_BATON_LINKS_FILE" ] || return 1
  awk -F '\t' -v p="$path" '$1 == p { print $2; found=1; exit } END { if (!found) exit 1 }' \
    "$CLAUDE_ALL_BATON_LINKS_FILE"
}

_baton_manifest_record() {
  local path="$1" target="$2" dir tmp
  [ -n "$path" ] && [ -n "$target" ] || return 0
  dir="$(dirname "$CLAUDE_ALL_BATON_LINKS_FILE")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  touch "$CLAUDE_ALL_BATON_LINKS_FILE"
  chmod 600 "$CLAUDE_ALL_BATON_LINKS_FILE" 2>/dev/null || true
  if awk -F '\t' -v p="$path" -v t="$target" '$1 == p && $2 == t { found=1 } END { exit(found ? 0 : 1) }' \
      "$CLAUDE_ALL_BATON_LINKS_FILE"; then
    return 0
  fi
  tmp="$CLAUDE_ALL_BATON_LINKS_FILE.tmp.$$"
  awk -F '\t' -v p="$path" '$1 != p' "$CLAUDE_ALL_BATON_LINKS_FILE" > "$tmp"
  printf '%s\t%s\n' "$path" "$target" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$CLAUDE_ALL_BATON_LINKS_FILE"
}

_baton_skill_target() {
  _claude_all_baton_init
  if _baton_path_present "$CLAUDE_ALL_BATON_GLOBAL_SKILL"; then
    _baton_resolve_path "$CLAUDE_ALL_BATON_GLOBAL_SKILL"
    return $?
  fi
  return 1
}

_baton_council_target() {
  _claude_all_baton_init
  if _baton_path_present "$CLAUDE_ALL_BATON_GLOBAL_COUNCIL"; then
    _baton_resolve_path "$CLAUDE_ALL_BATON_GLOBAL_COUNCIL"
    return $?
  fi
  return 1
}

_baton_make_link() {
  local path="$1" target="$2" parent current
  [ -n "$target" ] || return 1
  if _baton_path_present "$path"; then
    if _baton_manifest_has_path "$path"; then
      current="$(readlink "$path" 2>/dev/null || true)"
      if [ ! -L "$path" ] || [ "$current" != "$target" ]; then
        [ -L "$path" ] || return 0
        rm -f "$path"
        parent="$(dirname "$path")"
        mkdir -p "$parent"
        ln -s "$target" "$path"
      fi
      _baton_manifest_record "$path" "$target"
    fi
    return 0
  fi
  parent="$(dirname "$path")"
  mkdir -p "$parent"
  ln -s "$target" "$path"
  _baton_manifest_record "$path" "$target"
}

_baton_expand_config_dir() {
  local value="$1" prefix
  case "$value" in
    '~/'*) prefix='~/'; printf '%s/%s\n' "$HOME" "${value#"$prefix"}" ;;
    '$HOME/'*) prefix='$HOME/'; printf '%s/%s\n' "$HOME" "${value#"$prefix"}" ;;
    '${HOME}/'*) prefix='${HOME}/'; printf '%s/%s\n' "$HOME" "${value#"$prefix"}" ;;
    /*) printf '%s\n' "$value" ;;
    *) return 1 ;;
  esac
}

# Link one managed Claude config directory. Existing entries are never replaced.
_claude_all_baton_link_config() {
  local config_dir="$1" council_target
  [ -n "$config_dir" ] || return 0
  _claude_all_baton_init
  if _baton_path_present "$CLAUDE_ALL_BATON_GLOBAL_SKILL"; then
    _baton_make_link "$config_dir/skills/baton" "$CLAUDE_ALL_BATON_GLOBAL_SKILL"
  fi
  council_target="$(_baton_council_target 2>/dev/null || true)"
  if [ -n "$council_target" ]; then
    _baton_make_link "$config_dir/skills/council" "$CLAUDE_ALL_BATON_GLOBAL_COUNCIL"
  fi
}

_claude_all_baton_profile_config_dirs() {
  local profiles_dir="$1" file line value config_dir
  [ -d "$profiles_dir" ] || return 0
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    line="$(grep -E '^CLAUDE_CONFIG_DIR=' "$file" 2>/dev/null | head -1 || true)"
    [ -n "$line" ] || continue
    value="${line#CLAUDE_CONFIG_DIR=}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    config_dir="$(_baton_expand_config_dir "$value" 2>/dev/null || true)"
    [ -n "$config_dir" ] || continue
    printf '%s\n' "$config_dir"
  done < <(find "$profiles_dir" -maxdepth 1 -type f -name '*.env' 2>/dev/null | sort)
}

_claude_all_baton_managed_config_dirs() {
  local all_dir="$1" plbbl_dir="$2" profiles_dir="$3"
  {
    [ -n "$all_dir" ] && printf '%s\n' "$all_dir"
    [ -n "$plbbl_dir" ] && printf '%s\n' "$plbbl_dir"
    _claude_all_baton_profile_config_dirs "$profiles_dir"
  } | awk 'NF && !seen[$0]++'
}

_claude_all_baton_link_profile_configs() {
  local profiles_dir="$1" config_dir
  while IFS= read -r config_dir; do
    [ -n "$config_dir" ] || continue
    _claude_all_baton_link_config "$config_dir"
  done < <(_claude_all_baton_profile_config_dirs "$profiles_dir")
}

# Install the vendored skill if the user's global Baton skill is absent. The
# upstream installer remains the owner of its two global links; this wrapper
# records only links that point at our vendored copy.
_claude_all_baton_install() {
  local vendor_skill vendor_install global_skill global_bin skill_target vendor_target bin_target
  _claude_all_baton_init
  vendor_skill="$CLAUDE_ALL_BATON_VENDOR_DIR/skills/baton"
  vendor_install="$CLAUDE_ALL_BATON_VENDOR_DIR/install.sh"
  global_skill="$CLAUDE_ALL_BATON_GLOBAL_SKILL"
  global_bin="$CLAUDE_ALL_BATON_GLOBAL_BIN"
  [ -d "$vendor_skill" ] || { echo "[claude-all] 缺少 vendored Baton skill：$vendor_skill" >&2; return 1; }

  if ! _baton_path_present "$global_skill"; then
    if [ -x "$vendor_install" ]; then
      if ! CLAUDE_SKILLS_DIR="$(dirname "$global_skill")" BATON_BIN_DIR="$(dirname "$global_bin")" \
        bash "$vendor_install" --skill >/dev/null; then
        # A pre-existing user CLI can make the upstream installer return 1
        # after it has created the skill link. Keep both user-owned items.
        if ! _baton_path_present "$global_skill"; then
          echo "[claude-all] Baton skill 安装失败，且未创建 $global_skill" >&2
          return 1
        fi
      fi
    else
      _baton_make_link "$global_skill" "$vendor_skill"
    fi
  fi

  skill_target="$(_baton_skill_target 2>/dev/null || true)"
  [ -n "$skill_target" ] || { echo "[claude-all] 无法确定 Baton skill 来源：$global_skill" >&2; return 1; }
  vendor_target="$(_baton_resolve_path "$vendor_skill" 2>/dev/null || true)"
  if [ -L "$global_skill" ] && [ "$skill_target" = "$vendor_target" ]; then
    _baton_manifest_record "$global_skill" "$(readlink "$global_skill")"
  fi

  bin_target="$(_baton_resolve_path "$vendor_skill/bin/baton" 2>/dev/null || true)"
  if [ -L "$global_bin" ] && [ "$(_baton_resolve_path "$global_bin" 2>/dev/null || true)" = "$bin_target" ]; then
    _baton_manifest_record "$global_bin" "$(readlink "$global_bin")"
  fi
  return 0
}

_claude_all_baton_link_managed_configs() {
  local all_dir="$1" plbbl_dir="$2" profiles_dir="$3"
  _claude_all_baton_link_config "$all_dir"
  _claude_all_baton_link_config "$plbbl_dir"
  _claude_all_baton_link_profile_configs "$profiles_dir"
}

_claude_all_baton_cli() {
  local candidate
  _claude_all_baton_init
  for candidate in "$CLAUDE_ALL_BATON_GLOBAL_BIN" "$(command -v baton 2>/dev/null || true)" "$CLAUDE_ALL_BATON_VENDOR_DIR/skills/baton/bin/baton"; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate" ] || [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

_claude_all_baton_cli_source() {
  local cli vendor_cli
  _claude_all_baton_init
  cli="$(_claude_all_baton_cli 2>/dev/null || true)"
  [ -n "$cli" ] || { printf 'missing\n'; return 0; }
  vendor_cli="$(_baton_resolve_path "$CLAUDE_ALL_BATON_VENDOR_DIR/skills/baton/bin/baton" 2>/dev/null || true)"
  if [ -n "$vendor_cli" ] && [ "$(_baton_resolve_path "$cli" 2>/dev/null || true)" = "$vendor_cli" ]; then
    printf 'vendored\n'
  else
    case "$(_baton_resolve_path "$cli" 2>/dev/null || true)" in
      */skills/baton/bin/baton) printf 'user\n' ;;
      *) printf 'invalid\n' ;;
    esac
  fi
}

_claude_all_baton_uninstall_links() {
  local path target current tmp kept=0
  _claude_all_baton_init
  [ -f "$CLAUDE_ALL_BATON_LINKS_FILE" ] || return 0
  tmp="$CLAUDE_ALL_BATON_LINKS_FILE.tmp.$$"
  : > "$tmp"
  while IFS='	' read -r path target || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    current="$(readlink "$path" 2>/dev/null || true)"
    if [ -L "$path" ] && [ -n "$target" ] && [ "$current" = "$target" ]; then
      rm -f "$path"
    else
      printf '%s\t%s\n' "$path" "$target" >> "$tmp"
      kept=$((kept + 1))
    fi
  done < "$CLAUDE_ALL_BATON_LINKS_FILE"
  if [ "$kept" -eq 0 ]; then
    rm -f "$tmp" "$CLAUDE_ALL_BATON_LINKS_FILE"
  else
    chmod 600 "$tmp"
    mv "$tmp" "$CLAUDE_ALL_BATON_LINKS_FILE"
  fi
}
