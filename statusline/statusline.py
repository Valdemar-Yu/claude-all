#!/usr/bin/env python3
"""Claude Code custom statusline (single line).

Layout / 布局:
  🤖 <model> [1M] ⚡<effort>   🧠 <context-bar> <used%> (<used>/<size>)   ⏳ 5h <remaining%> ↻<reset>   📅 7d <remaining%> ↻<reset>   🕐 <date time>

- model name; appends "[1M]" when the model runs the 1M-token context window
  模型名; 1M 上下文窗口时追加 "[1M]"
- ⚡<effort>: live /effort reasoning level (low/medium/high/xhigh/max); hidden when unsupported
  实时 /effort 思考强度; 模型不支持时隐藏
- context bar from official `context_window.used_percentage`, falls back to parsing the transcript
  上下文优先用官方字段, 缺失时回退解析 transcript
- quota segments support Claude Pro/Max, Kimi, Z.ai GLM, and an optional PLBBL account pool
  配额支持 Claude、Kimi、GLM 与可选 PLBBL 账号池，均显示剩余比例和重置倒计时
- 🕐 clock: responsive to terminal width via the COLUMNS env var (Claude Code v2.1.153+).
  Degrades full "YY-MM-DD HH:MM" -> "MM-DD HH:MM" -> "HH:MM" -> hidden as space shrinks.
  时钟按 COLUMNS 宽度分级降级: 完整 -> 去年份 -> 只时间 -> 隐藏

Any error degrades silently — the statusline never crashes. / 任何异常都静默降级。

Reads a JSON session object on stdin, prints one line on stdout.
Docs: https://code.claude.com/docs/en/statusline
"""
import sys, json, os, time, re, unicodedata, shutil, subprocess, math, fcntl, pwd, hashlib
import urllib.request, urllib.parse
from http.cookies import SimpleCookie


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _open_authenticated(request, timeout):
    """Open an authenticated request without forwarding credentials on redirects."""
    return urllib.request.build_opener(_NoRedirect).open(request, timeout=timeout)


def _hostname(url):
    try:
        return (urllib.parse.urlparse(url).hostname or "").lower()
    except Exception:
        return ""


_ANSI_RE = re.compile(r"\033\[[0-9;]*m")
_CACHE_DIR = os.path.expanduser(
    os.environ.get("CLAUDE_ALL_STATUSLINE_CACHE_DIR", "~/.cache/claude-all/statusline"))
try:
    os.makedirs(_CACHE_DIR, mode=0o700, exist_ok=True)
    os.chmod(_CACHE_DIR, 0o700)
except Exception:
    pass

def _scoped_cache(name, *values):
    scope = "\0".join(str(value) for value in values)
    suffix = hashlib.sha256(scope.encode()).hexdigest()[:16]
    return os.path.join(_CACHE_DIR, f"{name}-{suffix}.json")


def read_input():
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}

def c(txt, code):
    return f"\033[{code}m{txt}\033[0m"


def safe_text(value):
    """Strip terminal control characters from provider/session supplied labels."""
    return "".join(ch for ch in str(value)
                   if ord(ch) >= 32 and not 127 <= ord(ch) < 160)


def disp_width(s):
    """Rendered terminal width: ANSI codes count 0, emoji/CJK-wide count 2, rest 1."""
    s = _ANSI_RE.sub("", s)
    w = 0
    for ch in s:
        o = ord(ch)
        if unicodedata.combining(ch) or 0xFE00 <= o <= 0xFE0F:  # combining / variation selector
            continue
        if (unicodedata.east_asian_width(ch) in ("W", "F")
                or 0x1F000 <= o <= 0x1FAFF or 0x2600 <= o <= 0x27BF
                or 0x2300 <= o <= 0x23FF or 0x2B00 <= o <= 0x2BFF):
            w += 2
        else:
            w += 1
    return w

def term_width():
    """Current terminal width: prefer COLUMNS (Claude Code v2.1.153+), fall back to probe/80."""
    try:
        return int(os.environ["COLUMNS"])
    except (KeyError, ValueError):
        return shutil.get_terminal_size((80, 24)).columns

def human(n):
    n = int(n or 0)
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n/1_000:.0f}k"
    return str(n)

def fmt_model(data, ctx):
    """Model name; annotate the effective 1M context window with '[1M]'."""
    name = safe_text((data.get("model") or {}).get("display_name", "Claude"))
    mid = safe_text((data.get("model") or {}).get("id", ""))
    if ctx:
        is_1m = ctx[1] >= 1_000_000
    else:
        is_1m = "1m" in mid.lower() or "1m" in name.lower()
    # strip a self-supplied "(1M context)"-style suffix before re-adding a compact tag
    name = re.sub(r"\s*[\(\[][^)\]]*1m[^)\]]*[\)\]]", "", name, flags=re.I).strip()
    return f"{name} [1M]" if is_1m else name

def bar(pct, width=8):
    pct = max(0.0, min(100.0, float(pct or 0)))
    filled = int(round(pct / 100 * width))
    return "█" * filled + "░" * (width - filled)

def pct_color(remaining):
    """Color a REMAINING percentage: less left -> redder."""
    if remaining > 50: return "32"   # green
    if remaining > 20: return "33"   # yellow
    return "31"                       # red

def used_color(used):
    """Color a USED percentage: more used -> redder."""
    if used < 60: return "32"
    if used < 85: return "33"
    return "31"

def fmt_countdown(resets_at):
    """resets_at is unix seconds -> '2h14m' / '3d5h' / '45m'."""
    try:
        delta = int(resets_at) - int(time.time())
    except Exception:
        return ""
    if delta <= 0:
        return "now"
    d, rem = divmod(delta, 86400)
    h, rem = divmod(rem, 3600)
    m, _ = divmod(rem, 60)
    if d: return f"{d}d{h}h"
    if h: return f"{h}h{m}m"
    return f"{m}m"

# ---- context: prefer official fields, fall back to the transcript ----
def _positive_int(value):
    try:
        value = int(value)
        return value if value > 0 else None
    except (TypeError, ValueError):
        return None


def effective_context_window(fallback=None, data=None):
    """Return the active route limit, then the launcher or source fallback."""
    if data:
        model = data.get("model") or {}
        candidates = {
            safe_text(model.get("id", "")).rsplit("@", 1)[-1].lower(),
            safe_text(model.get("display_name", "")).rsplit("@", 1)[-1].lower(),
        }
        candidates.discard("")
        for role in ("opus", "sonnet", "haiku"):
            if role in candidates:
                window = _positive_int(os.environ.get(
                    f"CLAUDE_ALL_CONTEXT_WINDOW_{role.upper()}"))
                if window:
                    return window
        for role in ("opus", "sonnet", "haiku"):
            route_model = os.environ.get(f"CLAUDE_ALL_CONTEXT_MODEL_{role.upper()}", "")
            route_id = route_model.rsplit("@", 1)[-1].lower()
            if route_id and route_id in candidates:
                window = _positive_int(os.environ.get(
                    f"CLAUDE_ALL_CONTEXT_WINDOW_{role.upper()}"))
                if window:
                    return window
    window = _positive_int(os.environ.get("CLAUDE_ALL_EFFECTIVE_CONTEXT_WINDOW"))
    return window or _positive_int(fallback)


def context_from_claudish(data=None):
    """Read claudish's token count, normalized to the route's effective window."""
    try:
        proxy = urllib.parse.urlparse(os.environ.get("ANTHROPIC_BASE_URL", ""))
        if proxy.hostname not in ("127.0.0.1", "localhost", "::1") or not proxy.port:
            return None
        state_dir = os.path.expanduser(
            os.environ.get("CLAUDISH_STATE_DIR", "~/.claudish"))
        with open(os.path.join(state_dir, f"tokens-{proxy.port}.json")) as f:
            metrics = json.load(f)
        size = effective_context_window(metrics.get("context_window"), data)
        if not size:
            return None
        input_tokens = metrics.get("input_tokens")
        if isinstance(input_tokens, int) and input_tokens >= 0:
            used_tokens = input_tokens
            used_pct = max(0.0, min(100.0, used_tokens / size * 100.0))
        else:
            left = float(metrics["context_left_percent"])
            if not math.isfinite(left) or not 0 <= left <= 100:
                return None
            used_pct = 100.0 - left
            used_tokens = int(round(size * used_pct / 100.0))
        return used_pct, size, used_tokens
    except Exception:
        return None


def context_from_official(data):
    cw = data.get("context_window") or {}
    used_pct = cw.get("used_percentage")
    source_size = cw.get("context_window_size")
    total_in = cw.get("total_input_tokens")
    size = effective_context_window(source_size, data)
    if used_pct is None or not size:
        return None
    if isinstance(total_in, int) and total_in >= 0:
        used_tok = total_in
        used_pct = max(0.0, min(100.0, used_tok / size * 100.0))
    else:
        used_pct = max(0.0, min(100.0, float(used_pct)))
        used_tok = int(round(size * used_pct / 100.0))
    return used_pct, size, int(used_tok or 0)

def context_from_transcript(data):
    path = data.get("transcript_path", "")
    if not path or not os.path.exists(path):
        return None
    used = 0
    try:
        with open(path) as f:
            for line in f:
                try:
                    u = (json.loads(line).get("message") or {}).get("usage")
                except Exception:
                    continue
                if not u:
                    continue
                used = (u.get("input_tokens", 0)
                        + u.get("cache_read_input_tokens", 0)
                        + u.get("cache_creation_input_tokens", 0))
    except Exception:
        return None
    mid = (data.get("model") or {}).get("id", "")
    inferred_size = 1_000_000 if "1m" in mid.lower() else 200_000
    size = effective_context_window(inferred_size, data)
    return min(100.0, used / size * 100 if size else 0), size, used

# ---- Kimi Coding Plan quota (fallback when official rate_limits absent) ----
_KIMI_CACHE = None  # tests may override; runtime caches are scoped by base URL and token
_KIMI_CACHE_TTL = 120  # seconds between network calls

def _write_json_cache(path, data):
    """Atomically write a credential-free JSON cache with mode 0600."""
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, separators=(",", ":"))
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _parse_iso(s):
    """'2026-07-19T08:26:44.702772Z' -> unix seconds."""
    try:
        from datetime import datetime, timezone
        return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except Exception:
        return None

def kimi_quota():
    """Query api.kimi.com/coding/v1/usages; cached on disk for _KIMI_CACHE_TTL.

    Returns {"five_hour": {...}, "seven_day": {...}} in the same shape the
    rate_limits renderer expects, or None on any failure (silent degrade).
    """
    base = os.environ.get("ANTHROPIC_BASE_URL", "")
    key = os.environ.get("ANTHROPIC_AUTH_TOKEN") or os.environ.get("ANTHROPIC_API_KEY")
    host = _hostname(base)
    if not (host == "kimi.com" or host.endswith(".kimi.com")) or not key:
        return None
    cache = _KIMI_CACHE or _scoped_cache("kimi", base.lower(), key)
    # fresh cache?
    try:
        if time.time() - os.path.getmtime(cache) < _KIMI_CACHE_TTL:
            with open(cache) as f:
                return json.load(f)
    except Exception:
        pass
    try:
        req = urllib.request.Request(
            "https://api.kimi.com/coding/v1/usages",
            headers={"Authorization": f"Bearer {key}"})
        with _open_authenticated(req, timeout=4) as r:
            d = json.loads(r.read())
        out = {}
        for w in d.get("limits") or []:
            win = w.get("window") or {}
            det = w.get("detail") or {}
            if win.get("duration") == 300 and det.get("remaining") is not None:
                out["five_hour"] = {
                    "used_percentage": 100 - float(det["remaining"]),
                    "resets_at": _parse_iso(det.get("resetTime", "")),
                }
        u = d.get("usage") or {}
        if u.get("remaining") is not None:
            out["seven_day"] = {
                "used_percentage": 100 - float(u["remaining"]),
                "resets_at": _parse_iso(u.get("resetTime", "")),
            }
        result = out or None
        if result:
            try:
                _write_json_cache(cache, result)
            except Exception:
                pass
        return result
    except Exception:
        # network down etc.: serve stale cache if we have one
        try:
            with open(cache) as f:
                return json.load(f)
        except Exception:
            return None

# ---- configurable PLBBL account-pool weekly quota ----
_GECODE_URL = os.environ.get("CLAUDE_ALL_POOL_USAGE_URL", "").strip()
_GECODE_SERVICE = os.environ.get("CLAUDE_ALL_POOL_KEYCHAIN_SERVICE", "").strip()
_GECODE_COOKIE = (os.environ.get("CLAUDE_ALL_POOL_COOKIE_NAME", "").strip()
                  or "chatgpt_code_access")
_GECODE_CACHE = os.path.join(_CACHE_DIR, "plbbl-pool.json")
_GECODE_LOCK = _GECODE_CACHE + ".lock"
_GECODE_CACHE_TTL = 60
_GECODE_CACHE_KEYS = {
    "base_url", "fetched_at", "remaining_percent", "known_accounts", "total_accounts",
    "resets_at", "source_stale",
}


def _read_gecode_cache(base):
    """Read the credential-free aggregate cache for this PLBBL base URL."""
    try:
        with open(_GECODE_CACHE) as f:
            cached = json.load(f)
        if not isinstance(cached, dict) or set(cached) != _GECODE_CACHE_KEYS:
            return None
        if cached["base_url"] != base:
            return None
        fetched = cached["fetched_at"]
        remaining = cached["remaining_percent"]
        known = cached["known_accounts"]
        total = cached["total_accounts"]
        resets_at = cached["resets_at"]
        source_stale = cached["source_stale"]
        if (isinstance(fetched, bool) or not isinstance(fetched, (int, float))
                or not math.isfinite(float(fetched))):
            return None
        if (isinstance(remaining, bool) or not isinstance(remaining, (int, float))
                or not math.isfinite(float(remaining))):
            return None
        if (isinstance(known, bool) or not isinstance(known, int)
                or isinstance(total, bool) or not isinstance(total, int)
                or known < 0 or total < known or remaining < 0 or remaining > 100):
            return None
        if resets_at is not None and (isinstance(resets_at, bool)
                or not isinstance(resets_at, (int, float))
                or not math.isfinite(float(resets_at))):
            return None
        if not isinstance(source_stale, bool):
            return None
        return {
            "base_url": base,
            "fetched_at": float(fetched),
            "remaining_percent": float(remaining),
            "known_accounts": known,
            "total_accounts": total,
            "resets_at": float(resets_at) if resets_at is not None else None,
            "source_stale": source_stale,
        }
    except Exception:
        return None


def _write_gecode_cache(result):
    """Persist the credential-free pool aggregate with mode 0600."""
    _write_json_cache(_GECODE_CACHE, result)


def aggregate_pool_usage(items, now=None):
    """Aggregate readable accounts into a normalized quota and nearest reset."""
    now = time.time() if now is None else float(now)
    if not isinstance(items, list):
        raise ValueError("pool items must be a list")
    remaining = []
    reset_times = []
    source_stale = False
    for item in items:
        if not isinstance(item, dict):
            continue
        if item.get("reauth_required") or item.get("usage_status") == "unavailable":
            continue
        usage = item.get("usage")
        if not isinstance(usage, dict):
            continue
        used = usage.get("used_percent")
        if (isinstance(used, bool) or not isinstance(used, (int, float))
                or not math.isfinite(float(used))):
            continue
        remaining.append(max(0.0, min(100.0, 100.0 - float(used))))
        if item.get("error") or item.get("usage_error"):
            source_stale = True
        reset_at = usage.get("resets_at")
        if (not isinstance(reset_at, bool) and isinstance(reset_at, (int, float))
                and math.isfinite(float(reset_at)) and float(reset_at) > now):
            reset_times.append(float(reset_at))
    return {
        "remaining_percent": sum(remaining) / len(remaining) if remaining else 0.0,
        "known_accounts": len(remaining),
        "total_accounts": len(items),
        "resets_at": min(reset_times) if reset_times else None,
        "source_stale": source_stale,
    }


def _fetch_gecode_pool(base):
    """Fetch the read-only pool endpoint and return a credential-free aggregate."""
    parsed = urllib.parse.urlparse(_GECODE_URL)
    if parsed.scheme != "https" or not parsed.netloc or not _GECODE_SERVICE:
        raise ValueError("pool endpoint or Keychain service unavailable")
    account = pwd.getpwuid(os.getuid()).pw_name
    proc = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", _GECODE_SERVICE,
         "-a", account, "-w"],
        capture_output=True, text=True, timeout=2, check=True,
    )
    secret = proc.stdout.rstrip("\n")
    if not secret:
        raise ValueError("empty Keychain credential")

    cookie = SimpleCookie()
    cookie[_GECODE_COOKIE] = secret
    req = urllib.request.Request(_GECODE_URL, headers={
        "Accept": "application/json",
        "Cache-Control": "no-cache",
        "Cookie": cookie.output(header="", sep="").strip(),
        "User-Agent": "claude-code-statusline/1",
    }, method="GET")
    with _open_authenticated(req, timeout=2) as response:
        raw = response.read(1_000_001)
    if len(raw) > 1_000_000:
        raise ValueError("quota response too large")
    data = json.loads(raw)
    if not isinstance(data, dict) or not isinstance(data.get("items"), list):
        raise ValueError("invalid quota response")

    aggregate = aggregate_pool_usage(data["items"])
    return {"base_url": base, "fetched_at": time.time(), **aggregate}


def gecode_pool_quota():
    """Return fresh/stale gecode pool aggregate, only for PLBBL sessions."""
    base = (os.environ.get("OPENAI_BASE_URL")
            or os.environ.get("LITELLM_BASE_URL", ""))
    host = _hostname(base)
    if not (host == "plbbl.com" or host.endswith(".plbbl.com")) \
            or not _GECODE_URL or not _GECODE_SERVICE:
        return None
    cache_scope = "\n".join((base.lower(), _GECODE_URL, _GECODE_SERVICE, _GECODE_COOKIE))

    cached = _read_gecode_cache(cache_scope)
    if cached is not None:
        age = time.time() - cached["fetched_at"]
        if 0 <= age < _GECODE_CACHE_TTL:
            return {**cached, "stale": False}

    lock_fd = None
    try:
        lock_fd = os.open(_GECODE_LOCK, os.O_RDWR | os.O_CREAT, 0o600)
        os.chmod(_GECODE_LOCK, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except Exception:
        if lock_fd is not None:
            os.close(lock_fd)
        return {**cached, "stale": True} if cached is not None else None

    try:
        cached = _read_gecode_cache(cache_scope)
        if cached is not None:
            age = time.time() - cached["fetched_at"]
            if 0 <= age < _GECODE_CACHE_TTL:
                return {**cached, "stale": False}
        try:
            result = _fetch_gecode_pool(cache_scope)
            try:
                _write_gecode_cache(result)
            except Exception:
                pass
            return {**result, "stale": False}
        except Exception:
            return {**cached, "stale": True} if cached is not None else None
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


def fmt_gecode_pool(quota):
    """Render normalized pool remainder and the nearest account reset."""
    remaining = float(quota["remaining_percent"])
    known = int(quota["known_accounts"])
    total = int(quota["total_accounts"])
    partial = known < total
    color = "33" if partial else pct_color(remaining)
    prefix = "~" if quota.get("stale") or quota.get("source_stale") else ""
    amount = "--" if not known else f"{prefix}{remaining:.0f}%"
    text = f"📅 周余 {amount}"
    countdown = fmt_countdown(quota.get("resets_at")) if quota.get("resets_at") else ""
    if countdown:
        text += f" ↻{countdown}"
    return c(text, color)


# ---- Z.ai GLM Coding Plan quota (fallback when official rate_limits absent) ----
_GLM_CACHE = None  # tests may override; runtime caches are scoped by base URL and token
_GLM_CACHE_TTL = 120  # seconds between network calls

def glm_quota():
    """Query <host>/api/monitor/usage/quota/limit; cached for _GLM_CACHE_TTL.

    Returns {"five_hour": {used_percentage, resets_at}, "month": {used_percentage,
    resets_at}} shaped for the rate_limits renderer, or None on any failure
    (silent degrade). Z.ai returns nextResetTime as a millisecond epoch; it is
    converted to seconds so the renderer can show a ↻ countdown.
    """
    base = os.environ.get("ANTHROPIC_BASE_URL", "")
    key = os.environ.get("ANTHROPIC_AUTH_TOKEN") or os.environ.get("ANTHROPIC_API_KEY")
    host = _hostname(base)
    trusted = (host == "z.ai" or host.endswith(".z.ai")
               or host == "open.bigmodel.cn" or host.endswith(".open.bigmodel.cn"))
    if urllib.parse.urlparse(base).scheme != "https" or not trusted or not key:
        return None
    cache = _GLM_CACHE or _scoped_cache("glm", base.lower(), key)
    # fresh cache?
    try:
        if time.time() - os.path.getmtime(cache) < _GLM_CACHE_TTL:
            with open(cache) as f:
                return json.load(f)
    except Exception:
        pass
    try:
        p = urllib.parse.urlparse(base)
        url = f"{p.scheme}://{p.netloc}/api/monitor/usage/quota/limit"
        req = urllib.request.Request(url, headers={
            "Authorization": key,  # z.ai wants the bare token, NO "Bearer " prefix
            "Accept-Language": "en-US,en",
            "Content-Type": "application/json",
        })
        with _open_authenticated(req, timeout=5) as r:
            d = json.loads(r.read())
        payload = d.get("data") or d  # z.ai wraps the payload as {code, msg, data}
        out = {}
        saw_token = False
        token_used = 0.0
        token_reset = None
        for lim in payload.get("limits") or []:
            t = lim.get("type")
            pct = lim.get("percentage")
            if pct is None:
                continue
            reset_ms = lim.get("nextResetTime")  # millisecond epoch
            if t == "TOKENS_LIMIT":
                # multiple 5h token pools may be reported; track the tightest
                # (max used) and that pool's reset timestamp
                if not saw_token or float(pct) > token_used:
                    token_used = float(pct)
                    token_reset = reset_ms
                saw_token = True
            elif t == "TIME_LIMIT":
                m = {"used_percentage": float(pct)}
                if reset_ms:
                    m["resets_at"] = reset_ms / 1000
                out["month"] = m
        if saw_token:
            fh = {"used_percentage": token_used}
            if token_reset:
                fh["resets_at"] = token_reset / 1000
            out["five_hour"] = fh
        result = out or None
        if result:
            try:
                _write_json_cache(cache, result)
            except Exception:
                pass
        return result
    except Exception:
        # network down etc.: serve stale cache if we have one
        try:
            with open(cache) as f:
                return json.load(f)
        except Exception:
            return None

def main():
    data = read_input()

    # ---- model + effort ----
    ctx = (context_from_claudish(data)
           or context_from_official(data)
           or context_from_transcript(data))
    model_seg = c(f"🤖 {fmt_model(data, ctx)}", "1;36")
    effort = (data.get("effort") or {}).get("level")
    if effort:
        model_seg += " " + c(f"⚡{safe_text(effort)}", "1;38;5;164")  # deep magenta-purple
    parts = [model_seg]

    # ---- context bar ----
    if ctx:
        used_pct, size, used_tok = ctx
        size_label = "1M" if size >= 1_000_000 else f"{size//1000}k"
        parts.append(
            c("🧠 " + bar(used_pct), used_color(used_pct))
            + f" {used_pct:.0f}% "
            + c(f"({human(used_tok)}/{size_label})", "90")
        )

    # ---- gecode pool weekly remainder (PLBBL sessions only) ----
    gecode_pool = gecode_pool_quota()
    if gecode_pool:
        parts.append(fmt_gecode_pool(gecode_pool))

    # ---- rate limits (may be absent) ----
    rl = data.get("rate_limits") or {}
    if not isinstance(rl, dict):
        rl = {}
    if not (rl.get("five_hour") or rl.get("seven_day")):
        rl = kimi_quota() or glm_quota() or {}
    if not isinstance(rl, dict):
        rl = {}
    for key, label, emoji in (("five_hour", "5h", "⏳"), ("seven_day", "7d", "📅"), ("month", "月", "📅")):
        w = rl.get(key)
        if not isinstance(w, dict) or w.get("used_percentage") is None:
            continue
        try:
            remaining = 100 - float(w["used_percentage"])
        except (TypeError, ValueError):
            continue
        txt = f"{emoji} {label} " + c(f"{remaining:.0f}%", pct_color(remaining))
        cd = fmt_countdown(w.get("resets_at")) if w.get("resets_at") else ""
        if cd:
            txt += c(f" ↻{cd}", "90")
        parts.append(txt)

    # ---- clock (rightmost), responsive to terminal width ----
    # kept live between events by "refreshInterval" in settings; COLUMNS injected by Claude Code
    SEP = "  "
    base_w = disp_width(SEP.join(parts))
    lt = time.localtime()
    variants = [
        time.strftime("%y-%m-%d %H:%M", lt),  # 26-07-16 10:49
        time.strftime("%m-%d %H:%M", lt),     # 07-16 10:49
        time.strftime("%H:%M", lt),           # 10:49
    ]
    avail = term_width() - base_w - disp_width(SEP) - 1  # -1 margin to avoid edge wrap
    for v in variants:
        seg_txt = f"🕐 {v}"
        if disp_width(seg_txt) <= avail:
            parts.append(c(seg_txt, "90"))
            break
    # if even "HH:MM" won't fit, the clock is omitted entirely

    sys.stdout.write(SEP.join(parts))

if __name__ == "__main__":
    main()
