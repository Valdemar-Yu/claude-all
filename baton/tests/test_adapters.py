import json
import pathlib
import tempfile
import unittest
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "baton" / "scripts"
import sys
sys.path.insert(0, str(SCRIPTS))
import adapters  # noqa: E402


class AdapterTests(unittest.TestCase):
    def test_codex_command_and_provider(self):
        project = SimpleNamespace(root="/tmp/project")
        adapter = adapters.CodexAdapter({
            "model": "gpt-test", "reasoning_effort": "high", "service_tier": "default",
            "sandbox": "workspace-write", "network_access": False, "disable_fast_mode": True,
            "provider": {"name": "relay", "base_url": "https://relay.invalid/v1", "wire_api": "responses"},
        })
        cmd = adapter.build_command(project, "resume", "thread-1", "/tmp/last.json")
        self.assertEqual(cmd[:3], ["codex", "exec", "resume"])
        self.assertIn("thread-1", cmd)
        self.assertIn("model_provider=relay", cmd)
        self.assertIn("model_providers.relay.base_url=https://relay.invalid/v1", cmd)

    def test_claude_profile_resume_and_env_file(self):
        project = SimpleNamespace(root="/tmp/project", config={"supervision": {"test_command": "python3 -m unittest discover -s baton/tests && bash -n install.sh"}})
        with tempfile.TemporaryDirectory() as td:
            env_file = pathlib.Path(td) / "profile.env"
            env_file.write_text("CLAUDE_CONFIG_DIR=/tmp/claude\nTOKEN='value'\n", encoding="utf-8")
            adapter = adapters.ClaudeAdapter({
                "command": "/tmp/bin/claude-all", "profile": "glm", "profile_args": ["{profile}"],
                "model": "glm-test", "permission_mode": "acceptEdits",
                "env_file": str(env_file),
            })
            cmd = adapter.build_command(project, "resume", "session-1", "/tmp/last.json")
            self.assertEqual(cmd[:3], ["/tmp/bin/claude-all", "glm", "-p"])
            self.assertIn("--resume", cmd)
            self.assertIn("session-1", cmd)
            self.assertIn("--json-schema", cmd)
            self.assertIn("Bash(python3 -m unittest:*)", cmd)
            self.assertIn("Bash(bash -n:*)", cmd)
            env = adapter.prepare_env(project)
            self.assertEqual(env["CLAUDE_CONFIG_DIR"], "/tmp/claude")
            self.assertEqual(env["TOKEN"], "value")

    def test_claude_clears_inherited_backend_unless_explicitly_allowed(self):
        project = SimpleNamespace(root="/tmp/project", config={})
        import os
        old = {key: os.environ.get(key) for key in (
            "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_SUBAGENT_MODEL")}
        try:
            os.environ.update({"ANTHROPIC_BASE_URL": "https://relay.invalid", "ANTHROPIC_AUTH_TOKEN": "secret",
                               "OPENAI_API_KEY": "key", "CLAUDE_CONFIG_DIR": "/wrong", "CLAUDE_CODE_SUBAGENT_MODEL": "x"})
            clean = adapters.ClaudeAdapter({"command": "claude"}).prepare_env(project)
            self.assertNotIn("ANTHROPIC_BASE_URL", clean)
            self.assertNotIn("OPENAI_API_KEY", clean)
            self.assertNotIn("CLAUDE_CONFIG_DIR", clean)
            inherited = adapters.ClaudeAdapter({"command": "claude", "inherit_env": True}).prepare_env(project)
            self.assertEqual(inherited["ANTHROPIC_BASE_URL"], "https://relay.invalid")
        finally:
            for key, value in old.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def test_bypass_permissions_is_never_added_by_default(self):
        project = SimpleNamespace(root="/tmp/project", config={})
        safe = adapters.ClaudeAdapter({}).build_command(project, "start", "", "/tmp/last.json")
        self.assertNotIn("--dangerously-skip-permissions", safe)
        unsafe = adapters.ClaudeAdapter({"permission_mode": "bypassPermissions"}).build_command(project, "start", "", "/tmp/last.json")
        self.assertIn("--dangerously-skip-permissions", unsafe)

    def test_network_disabled_filters_explicit_network_tools(self):
        project = SimpleNamespace(root="/tmp/project", config={})
        cmd = adapters.ClaudeAdapter({"allowed_tools": ["Bash(curl:*)", "Bash(npm install:*)", "Bash(git status:*)"], "network_access": False}).build_command(project, "start", "", "/tmp/last.json")
        self.assertNotIn("Bash(curl:*)", cmd)
        self.assertNotIn("Bash(npm install:*)", cmd)
        self.assertIn("Bash(git status:*)", cmd)

    def test_default_tools_keep_python_module_name_and_filter_install_modules(self):
        project = SimpleNamespace(root="/tmp/project", config={
            "supervision": {
                "test_command": "python3 -m unittest discover -s baton/tests && python3 -m pip install x && python3 -m poetry install x",
            },
        })
        cmd = adapters.ClaudeAdapter({}).build_command(project, "start", "", "/tmp/last.json")
        self.assertIn("Bash(python3 -m unittest:*)", cmd)
        self.assertNotIn("Bash(python3 -m:*)", cmd)
        self.assertNotIn("Bash(python3 -m pip:*)", cmd)
        self.assertNotIn("Bash(python3 -m poetry:*)", cmd)

    def test_claude_result_file_has_priority_then_stdout_fallback(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            result = root / "last.json"
            stdout = root / "stdout"
            stderr = root / "stderr"
            stdout.write_text(json.dumps({"session_id": "s", "result": "not used"}), encoding="utf-8")
            result.write_text(json.dumps({"status": "done", "summary": "file", "artifact": "", "change_size": "minor"}), encoding="utf-8")
            adapter = adapters.ClaudeAdapter({})
            self.assertEqual(adapter.parse_result(str(result), str(stdout), str(stderr))["summary"], "file")
            result.unlink()
            stdout.write_text("prefix {\"status\":\"report\",\"summary\":\"stdout\",\"artifact\":\"a\",\"change_size\":\"major\"}", encoding="utf-8")
            self.assertEqual(adapter.parse_result(str(result), str(stdout), str(stderr))["status"], "report")


if __name__ == "__main__":
    unittest.main()
