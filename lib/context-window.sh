# lib/context-window.sh — claude-all/cc-gpt-plbbl 共用的模型上下文窗口映射。

_claude_all_has_model_arg() {
  local arg
  for arg in "$@"; do
    [ "$arg" = -- ] && break
    case "$arg" in --model|-m|--model=*|-m=*) return 0 ;; esac
  done
  return 1
}

_claude_all_has_effort_arg() {
  local arg
  for arg in "$@"; do
    [ "$arg" = -- ] && break
    case "$arg" in --effort|--effort=*) return 0 ;; esac
  done
  return 1
}

_claude_all_active_model() {
  local fallback="$1" arg active="" expect_value=0
  shift
  for arg in "$@"; do
    [ "$arg" = -- ] && break
    if [ "$expect_value" -eq 1 ]; then
      active="$arg"
      expect_value=0
      continue
    fi
    case "$arg" in
      --model=*) active="${arg#--model=}" ;;
      -m=*)      active="${arg#-m=}" ;;
      --model|-m) expect_value=1 ;;
    esac
  done
  printf '%s' "${active:-$fallback}"
}

_claude_all_normalize_claudish_args() {
  local arg after_separator=0
  CLAUDE_ALL_NORMALIZED_ARGS=()
  for arg in "$@"; do
    if [ "$after_separator" -eq 1 ]; then
      CLAUDE_ALL_NORMALIZED_ARGS+=("$arg")
      continue
    fi
    case "$arg" in
      --) after_separator=1; CLAUDE_ALL_NORMALIZED_ARGS+=("$arg") ;;
      --model=*) CLAUDE_ALL_NORMALIZED_ARGS+=(--model "${arg#--model=}") ;;
      -m=*) CLAUDE_ALL_NORMALIZED_ARGS+=(-m "${arg#-m=}") ;;
      --effort=*) CLAUDE_ALL_NORMALIZED_ARGS+=(--effort "${arg#--effort=}") ;;
      *) CLAUDE_ALL_NORMALIZED_ARGS+=("$arg") ;;
    esac
  done
}

_claude_all_context_window() {
  local model="${1##*@}"
  case "$model" in
    *codex-spark*|*chat-latest*) echo 128000 ;;
    *gpt-5.4-mini*)              echo 400000 ;;
    *gpt-5.4*)                   echo 1000000 ;;
    *gpt-5.6*|*gpt-5.5*|*gpt-5.3*|*gpt-5.1*|gpt-5|gpt-5-*) echo 400000 ;;
    *) echo "${CCGP_DEFAULT_CONTEXT_WINDOW:-200000}" ;;
  esac
}

_claude_all_export_context_windows() {
  local primary="$1" model window primary_window="" min_window="" headroom pct
  shift
  for model in "$primary" "$@"; do
    window="$(_claude_all_context_window "$model")"
    case "$window" in ''|*[!0-9]*) printf '[claude-all] 无效上下文窗口:%s\n' "$window" >&2; return 1 ;; esac
    [ "$window" -gt 0 ] || { printf '[claude-all] 上下文窗口必须大于 0\n' >&2; return 1; }
    [ -n "$primary_window" ] || primary_window="$window"
    if [ -z "$min_window" ] || [ "$window" -lt "$min_window" ]; then min_window="$window"; fi
  done

  headroom="${CCGP_OUTPUT_HEADROOM:-20000}"
  pct="${CCGP_AUTOCOMPACT_PCT:-75}"
  case "$headroom" in ''|*[!0-9]*) printf '[claude-all] 无效输出余量:%s\n' "$headroom" >&2; return 1 ;; esac
  case "$pct" in ''|*[!0-9]*) printf '[claude-all] 无效 compact 百分比:%s\n' "$pct" >&2; return 1 ;; esac
  [ "$headroom" -lt "$min_window" ] \
    || { printf '[claude-all] 输出余量必须小于上下文窗口\n' >&2; return 1; }
  [ "$pct" -ge 1 ] && [ "$pct" -le 100 ] \
    || { printf '[claude-all] compact 百分比必须在 1-100\n' >&2; return 1; }

  export CLAUDE_ALL_EFFECTIVE_CONTEXT_WINDOW="$primary_window"
  export CLAUDE_CODE_AUTO_COMPACT_WINDOW=$(( min_window - headroom ))
  export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="$pct"
}

_claude_all_export_context_window() {
  _claude_all_export_context_windows "$1"
}
