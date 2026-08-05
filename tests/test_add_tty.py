#!/usr/bin/env python3
import errno
import os
from pathlib import Path
import pty
import select
import signal
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "bin" / "claude-all"


class AddWizardTtyTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.home = self.root / "home"
        self.profiles = self.home / ".claude-all" / "profiles"
        self.bindir = self.root / "bin"
        self.profiles.mkdir(parents=True)
        self.bindir.mkdir()
        curl = self.bindir / "curl"
        curl.write_text("""#!/usr/bin/env bash
set -euo pipefail
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    --header|--connect-timeout|--max-time) shift 2 ;;
    --silent|--show-error) shift ;;
    *) shift ;;
  esac
done
cat > "$out" <<'JSON'
{"object":"list","data":[{"id":"gpt-main"},{"id":"gpt-sub"},{"id":"gpt-team"}]}
JSON
printf '200'
""")
        curl.chmod(0o755)

    def tearDown(self):
        self.tempdir.cleanup()

    def run_add(self, steps):
        env = os.environ.copy()
        env.update({
            "HOME": str(self.home),
            "PATH": f"{self.bindir}{os.pathsep}{env['PATH']}",
            "CLAUDE_ALL_PROFILES_DIR": str(self.profiles),
            "TERM": "xterm-256color",
        })
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(str(LAUNCHER), [str(LAUNCHER), "add"], env)

        output = bytearray()
        status = None
        reaped = False
        deadline = time.monotonic() + 15
        try:
            for marker, reply in steps:
                marker_bytes = marker.encode()
                while marker_bytes not in output:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        self.fail(f"等待提示超时: {marker}\n{output.decode(errors='replace')}")
                    ready, _, _ = select.select([fd], [], [], min(remaining, 1))
                    if not ready:
                        continue
                    try:
                        output.extend(os.read(fd, 4096))
                    except OSError as exc:
                        if exc.errno == errno.EIO:
                            break
                        raise
                else:
                    os.write(fd, reply)
                    continue
                break

            while time.monotonic() < deadline:
                waited, status = os.waitpid(pid, os.WNOHANG)
                if waited:
                    reaped = True
                    break
                ready, _, _ = select.select([fd], [], [], 0.1)
                if not ready:
                    continue
                try:
                    chunk = os.read(fd, 4096)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        continue
                    raise
                if chunk:
                    output.extend(chunk)
            if status is None:
                self.fail(f"向导未在期限内退出\n{output.decode(errors='replace')}")
        finally:
            os.close(fd)
            if not reaped:
                waited, final_status = os.waitpid(pid, os.WNOHANG)
                if not waited:
                    try:
                        os.killpg(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    cleanup_deadline = time.monotonic() + 1
                    while time.monotonic() < cleanup_deadline:
                        waited, final_status = os.waitpid(pid, os.WNOHANG)
                        if waited:
                            break
                        time.sleep(0.05)
                    if not waited:
                        try:
                            os.killpg(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        _, final_status = os.waitpid(pid, 0)
                if status is None:
                    status = final_status
        exit_code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)
        self.assertEqual(exit_code, 0, output.decode(errors="replace"))
        return output.decode(errors="replace")

    def test_first_item_only_continues_after_enter(self):
        output = self.run_add([
            ("API 名称", b"tty-single\n"),
            ("协议 anthropic/openai", b"openai\n"),
            ("base_url", b"https://relay.example\n"),
            ("api_key", b"TEST_SECRET\n"),
            ("选择这个 API 要保留的模型", b" "),
            ("已选 1", b"\r"),
            ("选择默认主模型", b"\r"),
            ("选择默认 subagent 模型", b"\r"),
            ("选择默认 Agent Team teammate 模型", b"\r"),
            ("现在启动吗", b"n\n"),
        ])
        profile = self.profiles / "tty-single.env"
        self.assertTrue(profile.exists(), output)
        content = profile.read_text()
        self.assertIn("CLAUDE_ALL_DEFAULT_MODEL=gpt-main", content)
        self.assertIn("CLAUDE_ALL_SUBAGENT_MODEL=gpt-main", content)
        self.assertIn("CLAUDE_ALL_TEAM_MODEL=gpt-main", content)
        self.assertNotIn("[claude-all] 取消", output)

    def test_q_still_cancels_model_selection(self):
        output = self.run_add([
            ("API 名称", b"tty-cancel\n"),
            ("协议 anthropic/openai", b"openai\n"),
            ("base_url", b"https://relay.example\n"),
            ("api_key", b"TEST_SECRET\n"),
            ("选择这个 API 要保留的模型", b"q"),
        ])
        self.assertFalse((self.profiles / "tty-cancel.env").exists())
        self.assertIn("取消", output)


if __name__ == "__main__":
    unittest.main()
