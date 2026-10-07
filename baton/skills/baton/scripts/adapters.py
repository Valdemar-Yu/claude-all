"""Executor adapters used by Baton.

The state machine only needs a command, an environment and a leg result.  The
two built in adapters keep CLI-specific details here so a future executor can
be added without teaching Baton about another event format.
"""
import json
import os
import re
import shlex


RESULT_KEYS = {"status", "summary", "artifact", "change_size"}
RESULT_STATUSES = {"done", "decision", "report", "blocked"}
PYTHON_INSTALL_MODULES = {
    "pip", "ensurepip", "venv", "virtualenv", "pipenv", "poetry", "uv",
    "conda", "mamba", "micromamba", "setuptools", "easy_install",
}


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError, TypeError):
        return None


def _read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def _result(value):
    if not isinstance(value, dict):
        return None
    if value.get("status") in RESULT_STATUSES and RESULT_KEYS.intersection(value):
        return {
            "status": value.get("status"),
            "summary": str(value.get("summary") or ""),
            "artifact": str(value.get("artifact") or ""),
            "change_size": str(value.get("change_size") or "none"),
        }
    # Claude --output-format json wraps a --json-schema response in ``structured_output``.
    for key in ("structured_output", "structuredOutput", "result", "output"):
        nested = value.get(key)
        if isinstance(nested, dict):
            parsed = _result(nested)
            if parsed:
                return parsed
        if isinstance(nested, str):
            parsed = _scan_json(nested)
            if parsed:
                return parsed
    return None


def _scan_json(text):
    """Find the last protocol object in plain text without guessing natural language."""
    text = text or ""
    candidates = []
    decoder = json.JSONDecoder()
    for match in re.finditer(r"[\\{]", text):
        try:
            value, end = decoder.raw_decode(text[match.start():])
        except (ValueError, TypeError):
            continue
        parsed = _result(value)
        if parsed:
            candidates.append((match.start() + end, parsed))
    return candidates[-1][1] if candidates else None


def _schema_path():
    return os.path.join(os.path.dirname(os.path.dirname(__file__)), "templates", "leg-result.schema.json")


class ExecutorAdapter:
    name = "base"

    def __init__(self, config=None):
        self.config = config or {}

    def build_command(self, project, kind, session_id, result_path):  # pragma: no cover - interface
        raise NotImplementedError

    def prepare_env(self, project):
        return dict(os.environ)

    def parse_result(self, result_path, stdout_path, stderr_path):
        raise NotImplementedError

    def thread_id(self, events_path, stdout_path=None):
        return None

    @staticmethod
    def _append_prompt(cmd, project, kind, session_id):
        if kind == "start":
            cmd += ["-C", project.root, "-"]
        else:
            cmd += [session_id or "", "-"]
        return cmd


class CodexAdapter(ExecutorAdapter):
    name = "codex"

    def build_command(self, project, kind, session_id, result_path):
        ex = self.config
        cmd = ["codex", "exec"] + (["resume"] if kind == "resume" else [])
        cmd += ["--json", "-m", ex.get("model", "gpt-6.1-sol"),
                "-c", 'model_reasoning_effort="{}"'.format(ex.get("reasoning_effort", "xhigh")),
                "-c", 'service_tier="{}"'.format(ex.get("service_tier", "default")),
                "-c", 'sandbox_mode="{}"'.format(ex.get("sandbox", "workspace-write")),
                "-c", 'approval_policy="never"', "--output-schema", _schema_path(),
                "-o", result_path]
        provider = ex.get("provider")
        if isinstance(provider, dict) and provider.get("name"):
            name = provider["name"]
            cmd += ["-c", "model_provider={}".format(name)]
            for key in ("base_url", "wire_api"):
                if provider.get(key):
                    cmd += ["-c", "model_providers.{}.{}={}".format(name, key, provider[key])]
            for item in provider.get("extra_config") or []:
                cmd += ["-c", str(item)]
        if ex.get("sandbox") == "workspace-write":
            cmd += ["-c", "sandbox_workspace_write.network_access={}".format(
                "true" if ex.get("network_access") else "false")]
        if ex.get("disable_fast_mode"):
            cmd += ["--disable", "fast_mode"]
        for item in ex.get("extra_config") or []:
            cmd += ["-c", str(item)]
        if not os.path.exists(os.path.join(project.root, ".git")):
            cmd += ["--skip-git-repo-check"]
        return self._append_prompt(cmd, project, kind, session_id)

    def parse_result(self, result_path, stdout_path, stderr_path):
        value = _read_json(result_path)
        parsed = _result(value)
        if parsed:
            return parsed
        return None

    def thread_id(self, events_path, stdout_path=None):
        try:
            with open(events_path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if event.get("type") == "thread.started" and event.get("thread_id"):
                        return event["thread_id"]
        except OSError:
            pass
        return None


class ClaudeAdapter(ExecutorAdapter):
    name = "claude"

    @staticmethod
    def _command_name(config):
        raw = config.get("command") or "claude"
        try:
            return os.path.basename(shlex.split(str(raw))[0])
        except (IndexError, ValueError):
            return os.path.basename(str(raw).split()[0]) if str(raw).split() else "claude"

    @staticmethod
    def _default_allowed_tools(project):
        tools = [
            "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(ls:*)",
            "Bash(pwd:*)", "Bash(find:*)", "Bash(rg:*)", "Bash(python3 -m unittest:*)",
            "Bash(bash -n:*)",
        ]
        cfg = getattr(project, "config", {}) or {}
        command = ((cfg.get("supervision") or {}).get("test_command") or "").strip()
        for segment in re.split(r"(?:&&|\|\||[;\n])", command):
            segment = segment.strip()
            if not segment:
                continue
            try:
                words = shlex.split(segment)
            except ValueError:
                words = segment.split()
            while words and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[0]):
                words.pop(0)
            if not words:
                continue
            if len(words) > 2 and words[0] in ("python", "python3") and words[1] == "-m":
                module = words[2]
                prefix_words = words[:3]
                if (module in PYTHON_INSTALL_MODULES
                        or re.search(r"(?:install|setup|bootstrap|package)", module, re.I)
                        or re.search(r"\b(?:install|add|sync|update|upgrade|ensurepip|venv|virtualenv|pip)\b", segment, re.I)):
                    continue
            elif len(words) > 1 and words[0] == "bash" and words[1] == "-n":
                prefix_words = words[:2]
            else:
                prefix_words = words[:1]
            prefix = " ".join(prefix_words)
            lowered = segment.lower()
            if prefix in ("curl", "wget") or re.search(r"\b(?:npm|pnpm|yarn|pip)\s+install\b", lowered):
                continue
            tool = "Bash({}:*)".format(prefix)
            if tool not in tools:
                tools.append(tool)
        return tools

    @staticmethod
    def _network_safe_tools(tools, ex):
        if ex.get("network_access"):
            return list(tools)
        safe = []
        for tool in tools:
            lowered = str(tool).lower()
            if re.search(r"bash\((?:curl|wget)(?:[ :]|\))", lowered):
                continue
            if re.search(r"bash\((?:npm|pnpm|yarn|pip)[^)]*\binstall\b", lowered):
                continue
            if re.search(r"bash\(python3?\s+-m\s+(?:{})(?:[ :]|\))".format(
                    "|".join(sorted(PYTHON_INSTALL_MODULES))), lowered):
                continue
            safe.append(tool)
        return safe

    def build_command(self, project, kind, session_id, result_path):
        ex = self.config
        command = str(ex.get("command") or "claude")
        cmd = shlex.split(command) if isinstance(command, str) else list(command)
        if self._command_name(ex) == "claude-all" and ex.get("profile"):
            profile_args = ex.get("profile_args", ["{profile}"])
            cmd += [str(x).replace("{profile}", str(ex["profile"])) for x in profile_args]
        cmd += ["-p", "--output-format", "json"]
        if ex.get("model"):
            cmd += ["--model", str(ex["model"])]
        if kind == "resume" and session_id:
            cmd += ["--resume", str(session_id)]
        permission = ex.get("permission_mode") or "acceptEdits"
        cmd += ["--permission-mode", str(permission)]
        allowed = ex["allowed_tools"] if "allowed_tools" in ex else self._default_allowed_tools(project)
        if isinstance(allowed, str):
            allowed = [allowed]
        allowed = self._network_safe_tools(allowed, ex)
        if allowed:
            cmd += ["--allowed-tools", *[str(x) for x in allowed]]
        if ex.get("permission_mode") == "bypassPermissions":
            cmd += ["--allow-dangerously-skip-permissions", "--dangerously-skip-permissions"]
        if ex.get("json_schema", True):
            cmd += ["--json-schema", _read_text(_schema_path())]
        cmd += [str(x) for x in (ex.get("extra_args") or [])]
        return cmd

    def prepare_env(self, project):
        env = dict(os.environ)
        ex = self.config
        if self._command_name(ex) == "claude" and not ex.get("inherit_env", False):
            for key in list(env):
                if (key.startswith("ANTHROPIC_") or key.startswith("OPENAI_")
                        or key.startswith("CLAUDISH_") or key.startswith("CLAUDE_CODE_")):
                    env.pop(key, None)
            env.pop("CLAUDE_CONFIG_DIR", None)
        if ex.get("config_dir"):
            env["CLAUDE_CONFIG_DIR"] = os.path.expanduser(str(ex["config_dir"]))
        env_file = ex.get("env_file")
        if env_file:
            try:
                with open(os.path.expanduser(str(env_file)), encoding="utf-8") as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith("#") or "=" not in line:
                            continue
                        key, value = line.split("=", 1)
                        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key.strip()):
                            env[key.strip()] = value.strip().strip("\"'")
            except OSError:
                pass
        return env

    def parse_result(self, result_path, stdout_path, stderr_path):
        parsed = _result(_read_json(result_path))
        if parsed:
            return parsed
        stdout = _read_text(stdout_path)
        parsed = _scan_json(stdout)
        if parsed:
            return parsed
        # A Claude JSON envelope can contain the actual answer as ``result`` text.
        try:
            envelope = json.loads(stdout.strip())
        except (ValueError, TypeError):
            envelope = None
        if isinstance(envelope, dict):
            parsed = _result(envelope)
            if parsed:
                return parsed
            parsed = _scan_json(str(envelope.get("result") or ""))
            if parsed:
                return parsed
        return None

    def thread_id(self, events_path, stdout_path=None):
        for path in (stdout_path, events_path):
            if not path:
                continue
            text = _read_text(path)
            try:
                value = json.loads(text.strip())
            except (ValueError, TypeError):
                value = None
            if isinstance(value, dict) and value.get("session_id"):
                return value["session_id"]
            match = re.search(r'"session_id"\s*:\s*"([^"]+)"', text)
            if match:
                return match.group(1)
        return None


def get_adapter(config):
    adapter = str((config or {}).get("adapter") or "codex").lower()
    if adapter == "claude":
        return ClaudeAdapter(config)
    if adapter == "codex":
        return CodexAdapter(config)
    raise ValueError("不支持的执行者适配器：{}（可选 codex、claude）".format(adapter))
