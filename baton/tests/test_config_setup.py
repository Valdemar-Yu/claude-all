import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "baton" / "scripts"
sys.path.insert(0, str(SCRIPTS))
import baton_config  # noqa: E402


class ConfigLayerTests(unittest.TestCase):
    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data), encoding="utf-8")

    def test_legacy_executor_is_merged_and_roles_win_explicitly(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            skill = root / "skill.json"
            user = root / "user.json"
            project = root / ".baton" / "config.json"
            self.write(skill, {
                "executor": {"model": "base", "reasoning_effort": "high"},
                "roles": {"executor": {"adapter": "codex", "model": "base"}},
            })
            self.write(user, {"executor": {"model": "user"}})
            self.write(project, {
                "executor": {"model": "project", "network_access": True},
                "roles": {"executor": {"reasoning_effort": "xhigh"}},
            })
            cfg = baton_config.load_config(str(skill), str(project), {"BATON_USER_CONFIG": str(user)})
            ex = baton_config.executor_config(cfg)
            self.assertEqual(ex["adapter"], "codex")
            self.assertEqual(ex["model"], "project")
            self.assertEqual(ex["reasoning_effort"], "xhigh")
            self.assertTrue(ex["network_access"])
            self.assertEqual(cfg["executor"], ex)

    def test_user_layer_can_supply_roles_without_real_home(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            skill = root / "skill.json"
            user = root / "user.json"
            self.write(skill, {"executor": {"model": "base"}, "roles": {"executor": {"adapter": "codex"}}})
            self.write(user, {"roles": {"conductor": {"label": "DeepSeek"}, "executor": {"adapter": "claude"}}})
            cfg = baton_config.load_config(str(skill), None, {"BATON_USER_CONFIG": str(user)})
            self.assertEqual(baton_config.conductor_config(cfg)["label"], "DeepSeek")
            self.assertEqual(baton_config.executor_config(cfg)["adapter"], "claude")

    def test_missing_user_config_is_not_an_error(self):
        with tempfile.TemporaryDirectory() as td:
            skill = pathlib.Path(td) / "skill.json"
            self.write(skill, {"executor": {"model": "base"}, "roles": {"executor": {"adapter": "codex"}}})
            cfg = baton_config.load_config(str(skill), None, {"BATON_USER_CONFIG": ""})
            self.assertEqual(baton_config.executor_config(cfg)["model"], "base")


class SetupCliTests(unittest.TestCase):
    def run_setup(self, root, *args):
        env = dict(os.environ)
        env["BATON_USER_CONFIG"] = ""
        return subprocess.run(
            [sys.executable, str(SCRIPTS / "baton.py"), "--root", str(root), "setup", *args],
            cwd=str(ROOT), env=env, capture_output=True, text=True,
        )

    def test_non_tty_requires_arguments(self):
        with tempfile.TemporaryDirectory() as td:
            result = self.run_setup(pathlib.Path(td), "--scope", "project")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("非 TTY", result.stderr)

    def test_non_tty_preset_writes_project_config_and_preserves_unknown_keys(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            config = root / ".baton" / "config.json"
            config.parent.mkdir()
            config.write_text(json.dumps({"custom": {"keep": 1}, "executor": {"network_access": True}}), encoding="utf-8")
            result = self.run_setup(
                root, "--scope", "project", "--preset", "kimi-claude",
                "--judge-mode", "council", "--executor-allowed-tool", "Read",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(config.read_text(encoding="utf-8"))
            self.assertEqual(data["custom"]["keep"], 1)
            self.assertEqual(data["roles"]["conductor"]["label"], "Kimi")
            self.assertEqual(data["roles"]["executor"]["adapter"], "claude")
            self.assertEqual(data["roles"]["executor"]["allowed_tools"], ["Read"])
            self.assertIn("已写入 Baton project 配置", result.stdout)

    def test_non_tty_can_write_user_scope_to_fake_home_path(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            user = root / "user.json"
            env = dict(os.environ)
            env["BATON_USER_CONFIG"] = str(user)
            result = subprocess.run(
                [sys.executable, str(SCRIPTS / "baton.py"), "--root", str(root), "setup",
                 "--scope", "user", "--preset", "deepseek-council"],
                cwd=str(ROOT), env=env, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(user.read_text(encoding="utf-8"))
            self.assertEqual(data["roles"]["conductor"]["label"], "DeepSeek")
            self.assertEqual(data["roles"]["judge"]["mode"], "council")
            self.assertEqual(len(data["roles"]["judge"]["council"]["councilors"]), 3)


if __name__ == "__main__":
    unittest.main()
