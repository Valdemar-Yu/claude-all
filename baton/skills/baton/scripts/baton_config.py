"""Configuration loading and setup helpers for Baton.

The module deliberately has no dependency on the CLI so configuration merging and
the setup presets can be tested without spawning an executor or touching a real HOME.
"""
import json
import os
import re


USER_CONFIG_ENV = "BATON_USER_CONFIG"
DEFAULT_USER_CONFIG = os.path.join("~", ".config", "baton", "config.json")
ADAPTERS = ("codex", "claude")
JUDGE_STAGES = ("decision", "review", "final")
JUDGE_MODES = ("conductor", "council")


def deep_merge(base, over):
    """Return a recursive merge without mutating either input."""
    out = dict(base or {})
    for key, value in (over or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError, TypeError):
        return default


def user_config_path(env=None):
    env = os.environ if env is None else env
    return os.path.expanduser(env.get(USER_CONFIG_ENV) or DEFAULT_USER_CONFIG)


def _dict(value):
    return value if isinstance(value, dict) else {}


def _layered_executor(layers):
    """Merge legacy executor keys and role executor keys with explicit precedence.

    The skill config contains a complete roles.executor default.  Legacy root-level
    executor overrides from a project must still win over those defaults, while an
    explicit roles.executor value in user/project config wins over both.
    """
    base = _dict(layers[0]) if layers else {}
    base_roles = _dict(_dict(base.get("roles")).get("executor"))
    legacy = {}
    for layer in layers:
        legacy = deep_merge(legacy, _dict(layer.get("executor")))
    explicit_roles = {}
    for layer in layers[1:]:
        explicit_roles = deep_merge(explicit_roles, _dict(_dict(layer.get("roles")).get("executor")))
    effective = deep_merge(base_roles, legacy)
    return deep_merge(effective, explicit_roles)


def normalize_config(data, base=None):
    """Normalize a merged config and expose a single effective executor view."""
    out = deep_merge({}, data)
    base = _dict(base) if base is not None else out
    roles = _dict(out.get("roles"))
    defaults_roles = _dict(_dict(base.get("roles")).get("defaults"))
    if defaults_roles:
        roles = deep_merge(defaults_roles, roles)
    roles.setdefault("conductor", {
        "label": "Claude",
        "backend": "claude-code",
        "profile": "",
    })
    roles.setdefault("judge", {
        "mode": "conductor",
        "stages": {stage: "conductor" for stage in JUDGE_STAGES},
        "council": {"chief_model": "", "chief_backend": "", "councilors": []},
    })
    judge = roles["judge"] if isinstance(roles["judge"], dict) else {}
    judge.setdefault("mode", "conductor")
    stages = judge.get("stages") if isinstance(judge.get("stages"), dict) else {}
    judge["stages"] = {stage: stages.get(stage, judge["mode"]) for stage in JUDGE_STAGES}
    council = judge.get("council") if isinstance(judge.get("council"), dict) else {}
    council.setdefault("chief_model", "")
    council.setdefault("chief_backend", "")
    council.setdefault("councilors", [])
    judge["council"] = council
    roles["judge"] = judge
    executor = _dict(roles.get("executor"))
    if not executor:
        executor = _dict(out.get("executor"))
    executor.setdefault("adapter", "codex")
    roles["executor"] = executor
    out["roles"] = roles
    out["executor"] = executor
    return out


def load_config(skill_path, project_path=None, env=None):
    """Load skill, optional user, and project config in that order.

    ``project_path`` is the .baton/config.json path.  The user layer is skipped
    when BATON_USER_CONFIG is explicitly set to an empty string, which is useful
    for isolated tests and embedding applications.
    """
    skill = read_json(skill_path, {})
    env = os.environ if env is None else env
    if USER_CONFIG_ENV in env:
        user_path = env.get(USER_CONFIG_ENV)
        user = read_json(os.path.expanduser(user_path), {}) if user_path else {}
    else:
        user = read_json(user_config_path(env), {})
    project = read_json(project_path, {}) if project_path else {}
    merged = deep_merge(deep_merge(skill, user), project)
    # The complete skill defaults must be applied before legacy overrides.  Rebuild
    # the effective executor explicitly so a project-level old executor.model is not
    # shadowed by the skill's roles.executor default.
    merged["roles"] = deep_merge(_dict(skill.get("roles")), _dict(user.get("roles")))
    merged["roles"] = deep_merge(merged["roles"], _dict(project.get("roles")))
    merged["roles"]["executor"] = _layered_executor([skill, user, project])
    merged["executor"] = deep_merge(_dict(skill.get("executor")), _dict(user.get("executor")))
    merged["executor"] = deep_merge(merged["executor"], _dict(project.get("executor")))
    merged = normalize_config(merged, base=skill)
    return merged


def executor_config(config):
    return _dict(_dict(config).get("roles")).get("executor", _dict(_dict(config).get("executor")))


def conductor_config(config):
    return _dict(_dict(_dict(config).get("roles")).get("conductor"))


def judge_config(config):
    return _dict(_dict(_dict(config).get("roles")).get("judge"))


def executor_adapter(config):
    adapter = str(executor_config(config).get("adapter") or "codex").lower()
    return adapter if adapter in ADAPTERS else adapter


def config_target(root, scope, env=None):
    if scope == "project":
        return os.path.join(os.path.abspath(root), ".baton", "config.json")
    if scope == "user":
        return user_config_path(env)
    raise ValueError("scope must be project or user")


def parse_bool(value):
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    if text in ("1", "true", "yes", "on", "y"):
        return True
    if text in ("0", "false", "no", "off", "n"):
        return False
    raise ValueError("布尔值只能是 true/false、yes/no 或 1/0")


def _councilor(name, adapter="claude", model="", profile=""):
    return {"name": name, "adapter": adapter, "model": model, "profile": profile}


def preset(name):
    """Return a fresh setup preset by name."""
    common = {
        "conductor": {"label": "Claude Opus 5.5", "backend": "claude-code", "model": "opus", "profile": ""},
        "judge": {
            "mode": "conductor",
            "stages": {stage: "conductor" for stage in JUDGE_STAGES},
            "council": {
                "chief_model": "opus",
                "chief_backend": "",
                "councilors": [
                    _councilor("council-cc-opus", "claude", "opus"),
                    _councilor("council-codex-sol", "codex", "gpt-6.1-sol"),
                ],
            },
        },
        "executor": {
            "adapter": "codex", "model": "gpt-6.1-sol", "reasoning_effort": "xhigh",
            "service_tier": "default", "disable_fast_mode": True, "sandbox": "workspace-write",
            "network_access": False, "extra_config": [],
        },
    }
    if name == "default":
        return {"roles": common}
    if name == "deepseek-council":
        common["conductor"] = {"label": "DeepSeek", "backend": "claude-all", "model": "deepseek", "profile": "deepseek"}
        common["judge"]["mode"] = "council"
        common["judge"]["stages"] = {stage: "council" for stage in JUDGE_STAGES}
        common["judge"]["council"]["chief_model"] = "deepseek"
        common["judge"]["council"]["councilors"] = [
            _councilor("council-cc-deepseek", "claude", "deepseek", "deepseek"),
            _councilor("council-cc-kimi", "claude", "kimi", "kimi"),
            _councilor("council-codex-sol", "codex", "gpt-6.1-sol"),
        ]
        return {"roles": common}
    if name == "kimi-claude":
        common["conductor"] = {"label": "Kimi", "backend": "claude-all", "model": "kimi", "profile": "kimi"}
        common["executor"] = {
            "adapter": "claude", "command": "claude-all", "profile": "glm", "profile_args": ["{profile}"],
            "model": "glm-4.5", "permission_mode": "acceptEdits",
            "sandbox": "workspace-write", "network_access": False, "extra_args": [],
        }
        return {"roles": common}
    raise ValueError("未知 preset：{}（可选 default、deepseek-council、kimi-claude）".format(name))


def _set_path(data, path, value):
    node = data
    for key in path[:-1]:
        if not isinstance(node.get(key), dict):
            node[key] = {}
        node = node[key]
    node[path[-1]] = value


def apply_setup_patch(data, args):
    """Apply argparse setup values to an existing JSON object."""
    out = deep_merge({}, data)
    if getattr(args, "preset", None):
        out = deep_merge(out, preset(args.preset))
    values = (
        ("conductor_label", ("roles", "conductor", "label")),
        ("conductor_backend", ("roles", "conductor", "backend")),
        ("conductor_model", ("roles", "conductor", "model")),
        ("conductor_profile", ("roles", "conductor", "profile")),
        ("judge_mode", ("roles", "judge", "mode")),
        ("judge_decision", ("roles", "judge", "stages", "decision")),
        ("judge_review", ("roles", "judge", "stages", "review")),
        ("judge_final", ("roles", "judge", "stages", "final")),
        ("executor_adapter", ("roles", "executor", "adapter")),
        ("executor_model", ("roles", "executor", "model")),
        ("executor_reasoning_effort", ("roles", "executor", "reasoning_effort")),
        ("executor_service_tier", ("roles", "executor", "service_tier")),
        ("executor_sandbox", ("roles", "executor", "sandbox")),
        ("executor_command", ("roles", "executor", "command")),
        ("executor_profile", ("roles", "executor", "profile")),
        ("executor_config_dir", ("roles", "executor", "config_dir")),
        ("executor_env_file", ("roles", "executor", "env_file")),
        ("executor_permission_mode", ("roles", "executor", "permission_mode")),
        ("executor_inherit_env", ("roles", "executor", "inherit_env")),
    )
    for attr, path in values:
        value = getattr(args, attr, None)
        if value is not None:
            _set_path(out, path, value)
    for attr, path in (("executor_network_access", ("roles", "executor", "network_access")),
                       ("executor_disable_fast_mode", ("roles", "executor", "disable_fast_mode")),
                       ("executor_inherit_env", ("roles", "executor", "inherit_env"))):
        value = getattr(args, attr, None)
        if value is not None:
            _set_path(out, path, parse_bool(value))
    allowed = getattr(args, "executor_allowed_tool", None)
    if allowed:
        _set_path(out, ("roles", "executor", "allowed_tools"), list(allowed))
    extra = getattr(args, "executor_extra_arg", None)
    if extra:
        _set_path(out, ("roles", "executor", "extra_args"), list(extra))
    members = getattr(args, "judge_councilor", None)
    if members:
        parsed = []
        for item in members:
            # NAME[:adapter[:model[:profile]]] keeps non-interactive setup shell-friendly.
            parts = item.split(":", 3)
            name = parts[0]
            if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
                raise ValueError("councilor 名称只能包含字母、数字、下划线和短横线")
            parsed.append(_councilor(name, parts[1] if len(parts) > 1 and parts[1] else "claude",
                                     parts[2] if len(parts) > 2 else "",
                                     parts[3] if len(parts) > 3 else ""))
        _set_path(out, ("roles", "judge", "council", "councilors"), parsed)
    return out


def write_config(path, data):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = "{}.{}.tmp".format(path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)
