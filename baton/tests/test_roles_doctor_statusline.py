import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "baton" / "scripts"


class RoleIntegrationTests(unittest.TestCase):
    def test_council_generator_quotes_and_cleans_claude_environment(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            source = root / "config.json"
            output = root / "config.baton.json"
            defs = root / "council-def.baton.sh"
            source.write_text(json.dumps({"roles": {"conductor": {"model": "deepseek"}, "judge": {"council": {
                "chief_model": "deepseek", "councilors": [{"name": "safe-cc", "adapter": "claude", "command": "/opt/claude", "model": "sonnet"}, {"name": "glm", "adapter": "claude", "command": "/opt/claude-all", "profile": "glm"}]
            }}}}), encoding="utf-8")
            subprocess.run([sys.executable, str(SCRIPTS / "council_gen.py"), "--source", str(source),
                            "--config-output", str(output), "--def-output", str(defs)], check=True, capture_output=True, text=True)
            text = defs.read_text(encoding="utf-8")
            self.assertIn("env -u ANTHROPIC_BASE_URL", text)
            self.assertIn("/opt/claude-all glm", text)
            self.assertIn("https://github.com/ParadoxZW/council.skill", text)

    def test_doctor_reports_roles_without_codex_quota_for_claude_executor(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            home = root / "home"
            bindir = root / "bin"
            bindir.mkdir()
            (bindir / "claude").write_text("#!/bin/sh\necho 'claude test'\n", encoding="utf-8")
            (bindir / "claude").chmod(0o755)
            config = root / "config.json"
            config.write_text(json.dumps({"roles": {"executor": {"adapter": "claude", "command": "claude", "model": "sonnet"},
                                                   "conductor": {"label": "Kimi", "backend": "claude-all", "profile": "kimi"},
                                                   "judge": {"mode": "council", "stages": {"decision": "council", "review": "conductor", "final": "council"}}}}), encoding="utf-8")
            env = dict(os.environ, HOME=str(home), PATH=str(bindir) + os.pathsep + os.environ.get("PATH", ""),
                       BATON_USER_CONFIG=str(config))
            result = subprocess.run([sys.executable, str(SCRIPTS / "baton.py"), "--root", str(root), "doctor"],
                                    env=env, capture_output=True, text=True)
            self.assertIn("指挥：Kimi", result.stdout)
            self.assertIn("裁判：mode=council", result.stdout)
            self.assertIn("执行者：adapter=claude", result.stdout)
            self.assertIn("不检查 Codex 登录、models_cache 或额度", result.stdout)
            self.assertNotIn("Codex 额度：无法获取", result.stdout)

    def test_statusline_omits_quota_line_for_claude_executor(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            project = root / "project"
            (project / ".baton").mkdir(parents=True)
            config = root / "config.json"
            config.write_text(json.dumps({"roles": {"executor": {"adapter": "claude", "command": "claude"}}}), encoding="utf-8")
            env = dict(os.environ, BATON_USER_CONFIG=str(config), BATON_BASE_STATUSLINE="")
            result = subprocess.run([sys.executable, str(SCRIPTS / "statusline.py" )], input=json.dumps({"workspace": {"project_dir": str(project)}}),
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.stdout, "\n")


if __name__ == "__main__":
    unittest.main()
