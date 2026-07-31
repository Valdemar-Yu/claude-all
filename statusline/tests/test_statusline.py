#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).resolve().parents[1] / "statusline.py"
spec = importlib.util.spec_from_file_location("claude_all_statusline", MODULE_PATH)
statusline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(statusline)


class Response:
    def __init__(self, payload):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, *_):
        return self.payload


class ContextTests(unittest.TestCase):
    def test_claudish_metrics_override_placeholder_usage(self):
        with tempfile.TemporaryDirectory() as directory:
            with open(os.path.join(directory, "tokens-4321.json"), "w") as f:
                json.dump({
                    "input_tokens": 256822,
                    "context_window": 1050000,
                    "context_left_percent": 75,
                }, f)
            with mock.patch.dict(os.environ, {
                    "ANTHROPIC_BASE_URL": "http://127.0.0.1:4321",
                    "CLAUDISH_STATE_DIR": directory,
                    }, clear=False):
                result = statusline.context_from_claudish()
        self.assertEqual(result, (25.0, 1050000, 256822))


class PoolTests(unittest.TestCase):
    def test_pool_average_and_nearest_reset(self):
        result = statusline.aggregate_pool_usage([
            {"usage_status": "available", "usage": {"used_percent": 0, "resets_at": 500}},
            {"usage_status": "available", "usage": {"used_percent": 20, "resets_at": 300}},
            {"usage_status": "available", "usage": {"used_percent": 100, "resets_at": 400}},
            {"usage_status": "unavailable", "usage": {"used_percent": 0, "resets_at": 200}},
        ], now=100)
        self.assertAlmostEqual(result["remaining_percent"], 60)
        self.assertEqual(result["known_accounts"], 3)
        self.assertEqual(result["total_accounts"], 4)
        self.assertEqual(result["resets_at"], 300)

    def test_pool_keeps_valid_snapshot_when_refresh_failed(self):
        result = statusline.aggregate_pool_usage([
            {"reauth_required": True, "usage": {"used_percent": 0, "resets_at": 900}},
            {"error": "refresh timeout", "usage_error": "timeout",
             "usage_status": "available", "usage": {"used_percent": 20, "resets_at": 900}},
            {"usage": {"used_percent": 40, "resets_at": 50}},
            {"usage": {"used_percent": "25", "resets_at": 900}},
        ], now=100)
        self.assertEqual(result["remaining_percent"], 70)
        self.assertEqual(result["known_accounts"], 2)
        self.assertEqual(result["resets_at"], 900)
        self.assertTrue(result["source_stale"])

    def test_pool_render_is_normalized_and_hides_account_count(self):
        text = statusline._ANSI_RE.sub("", statusline.fmt_gecode_pool({
            "remaining_percent": 95,
            "known_accounts": 4,
            "total_accounts": 4,
            "resets_at": time.time() + 7200,
            "stale": False,
            "source_stale": False,
        }))
        self.assertIn("周余 95%", text)
        self.assertIn("↻", text)
        self.assertNotIn("4号", text)

    def test_non_plbbl_does_not_query_pool(self):
        with mock.patch.dict(os.environ, {"OPENAI_BASE_URL": "https://example.com"}, clear=False), \
                mock.patch.object(statusline, "_GECODE_URL", "https://pool.example/api"), \
                mock.patch.object(statusline, "_GECODE_SERVICE", "test"), \
                mock.patch.object(statusline, "_fetch_gecode_pool") as fetch:
            self.assertIsNone(statusline.gecode_pool_quota())
            fetch.assert_not_called()

    def test_stale_pool_cache_survives_fetch_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = os.path.join(directory, "pool.json")
            lock = cache + ".lock"
            with mock.patch.object(statusline, "_GECODE_CACHE", cache), \
                    mock.patch.object(statusline, "_GECODE_LOCK", lock), \
                    mock.patch.object(statusline, "_GECODE_URL", "https://pool.example/api"), \
                    mock.patch.object(statusline, "_GECODE_SERVICE", "test"), \
                    mock.patch.object(statusline, "_fetch_gecode_pool", side_effect=OSError("offline")), \
                    mock.patch.dict(os.environ, {"OPENAI_BASE_URL": "https://plbbl.com/t/test"}, clear=False):
                scope = "\n".join(("https://plbbl.com/t/test", statusline._GECODE_URL,
                                    statusline._GECODE_SERVICE, statusline._GECODE_COOKIE))
                statusline._write_gecode_cache({
                    "base_url": scope,
                    "fetched_at": time.time() - 3600,
                    "remaining_percent": 72,
                    "known_accounts": 3,
                    "total_accounts": 4,
                    "resets_at": time.time() + 3600,
                    "source_stale": False,
                })
                result = statusline.gecode_pool_quota()
                self.assertTrue(result["stale"])
                self.assertEqual(result["remaining_percent"], 72)


class GlmTests(unittest.TestCase):
    def test_similar_hostname_is_not_trusted(self):
        with mock.patch.dict(os.environ, {
                "ANTHROPIC_BASE_URL": "https://z.ai.evil.example/api",
                "ANTHROPIC_AUTH_TOKEN": "test-token",
                }, clear=False), mock.patch.object(statusline, "_open_authenticated") as opened:
            self.assertIsNone(statusline.glm_quota())
            opened.assert_not_called()

    def test_glm_uses_tightest_token_pool_and_month(self):
        payload = {"data": {"limits": [
            {"type": "TOKENS_LIMIT", "percentage": 10, "nextResetTime": 2_000_000},
            {"type": "TOKENS_LIMIT", "percentage": 30, "nextResetTime": 3_000_000},
            {"type": "TIME_LIMIT", "percentage": 40, "nextResetTime": 4_000_000},
        ]}}
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(statusline, "_GLM_CACHE", os.path.join(directory, "glm.json")), \
                mock.patch.object(statusline, "_open_authenticated", return_value=Response(payload)), \
                mock.patch.dict(os.environ, {
                    "ANTHROPIC_BASE_URL": "https://open.bigmodel.cn/api/anthropic",
                    "ANTHROPIC_AUTH_TOKEN": "test-token",
                }, clear=False):
            result = statusline.glm_quota()
        self.assertEqual(result["five_hour"]["used_percentage"], 30)
        self.assertEqual(result["five_hour"]["resets_at"], 3000)
        self.assertEqual(result["month"]["used_percentage"], 40)


if __name__ == "__main__":
    unittest.main()
