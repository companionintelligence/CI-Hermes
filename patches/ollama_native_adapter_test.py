"""Unit tests for ollama_native_adapter — stdlib unittest; httpx is the one dependency.

Run from this directory:  python3 -m unittest discover -p '*_test.py' --verbose
"""

from __future__ import annotations

import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import httpx  # noqa: E402

import ollama_native_adapter as adapter  # noqa: E402


class DefaultReadTimeoutTest(unittest.TestCase):
    """The read leg must never undercut upstream's own local-endpoint budget: with the
    env unset it is HERMES_API_TIMEOUT's upstream default (1800 s), and the env — the same
    knob upstream's /v1 client follows — moves it."""

    def _with_env(self, value):
        env = {k: v for k, v in os.environ.items() if k != adapter.API_TIMEOUT_ENV}
        if value is not None:
            env[adapter.API_TIMEOUT_ENV] = value
        return mock.patch.dict(os.environ, env, clear=True)

    def test_unset_follows_upstream_default(self):
        with self._with_env(None):
            self.assertEqual(adapter.default_read_timeout(), 1800.0)

    def test_env_sets_it(self):
        with self._with_env("900"):
            self.assertEqual(adapter.default_read_timeout(), 900.0)
        with self._with_env(" 2700.5 "):
            self.assertEqual(adapter.default_read_timeout(), 2700.5)

    def test_garbage_and_non_positive_fall_back(self):
        for raw in ("", "abc", "0", "-5", "inf", "nan"):
            with self.subTest(raw=raw), self._with_env(raw):
                self.assertEqual(adapter.default_read_timeout(), 1800.0)


class ClientDefaultTimeoutTest(unittest.TestCase):
    """The client's default timeout — what /api/chat and /api/embed get when no per-call
    or per-client timeout was given — carries that read leg; the short connect/write/pool
    legs stay short so a dead endpoint still fails fast."""

    def test_client_default_uses_the_env_driven_read_leg(self):
        with mock.patch.dict(os.environ, {adapter.API_TIMEOUT_ENV: "1234"}):
            client = adapter.OllamaNativeClient(base_url="http://ci-hub:5002/api/inference/pool")
        try:
            timeout = client._default_timeout
            self.assertIsInstance(timeout, httpx.Timeout)
            self.assertEqual(timeout.read, 1234.0)
            self.assertEqual(timeout.connect, 15.0)
            self.assertEqual(timeout.write, 30.0)
            self.assertEqual(timeout.pool, 30.0)
            # And it is what a request without its own timeout is sent with.
            self.assertIs(client._timeout_kwargs(None)["timeout"], timeout)
        finally:
            client.close()

    def test_explicit_client_timeout_wins(self):
        client = adapter.OllamaNativeClient(base_url="http://ci-hub:5002", timeout=42.0)
        try:
            self.assertEqual(client._default_timeout, 42.0)
            self.assertEqual(client._timeout_kwargs(None)["timeout"], 42.0)
            self.assertEqual(client._timeout_kwargs(7.0)["timeout"], 7.0)
        finally:
            client.close()


if __name__ == "__main__":
    unittest.main()
