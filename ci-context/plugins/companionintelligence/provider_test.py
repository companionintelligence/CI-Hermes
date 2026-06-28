"""Functional tests for the Companion Intelligence Hermes plugin.

The plugin subclasses ``agent.memory_provider.MemoryProvider``, which only exists
inside the Hermes runtime. We stub that base so the module imports standalone,
then exercise the REAL client + provider logic (feature-flag gating, the
memory-client drift fixes, and the intent-catalog injection) with mocks.

Run: ``python3 -m unittest provider_test`` from this directory.
"""

import os
import sys
import threading
import types
import unittest
import urllib.error

# --- Stub the Hermes base so ``import companionintelligence`` works standalone ---
_agent = types.ModuleType("agent")
_mp = types.ModuleType("agent.memory_provider")


class _StubMemoryProvider:  # minimal base; the plugin only subclasses it
    pass


_mp.MemoryProvider = _StubMemoryProvider
sys.modules.setdefault("agent", _agent)
sys.modules.setdefault("agent.memory_provider", _mp)

# Make the package importable by name from the parent dir.
_HERE = os.path.dirname(os.path.abspath(__file__))
_PARENT = os.path.dirname(_HERE)
if _PARENT not in sys.path:
    sys.path.insert(0, _PARENT)

import companionintelligence as ci  # noqa: E402

_FLAGS = (
    "CI_MEMORY_CONTEXT_ENABLED",
    "CI_MEMORY_RECALL_ENABLED",
    "CI_MEMORY_TURN_ENABLED",
    "CI_MEMORY_WRITE_ENABLED",
    "CI_INTENTS_ENABLED",
)


def _clear_flags():
    for name in _FLAGS:
        os.environ.pop(name, None)


_MANIFEST = {
    "version": "1.0.0",
    "domains": [{"key": "memory", "title": "Memory", "description": "x"}],
    "entities": [],
    "intents": [
        {
            "name": "memory.recall",
            "tool": "memory_recall",
            "domain": "memory",
            "title": "Recall",
            "description": "Recall facts.",
            "parameters": {"type": "object"},
            "privacy": {"access": "read", "sensitivity": "personal", "destructive": False, "external": False},
            "consumes": [],
            "produces": ["concept"],
            "phrases": [],
        }
    ],
}


class _MockClient:
    def __init__(self, block="PROFILE", manifest=None):
        self._block = block
        self._manifest = manifest
        self.context_calls = 0
        self.recall_calls = 0
        self.turn_calls = []
        self.write_calls = []
        self.write_event = threading.Event()

    def context(self):
        self.context_calls += 1
        return {"block": self._block}

    def recall(self, query, max_results=5):
        self.recall_calls += 1
        return {"block": "RECALL"}

    def turn(self, messages, session_id="", platform=""):
        self.turn_calls.append((messages, session_id, platform))
        return {}

    def write(self, content, source="", title="", session_id=""):
        self.write_calls.append((content, source, session_id))
        self.write_event.set()
        return {}

    def _get(self, path):  # used by fetch_intent_manifest
        return self._manifest or {}


def _provider_with_client(client):
    provider = ci.CompanionIntelligenceProvider()
    provider._client = client
    provider._session_id = "s1"
    provider._platform = "hermes"
    provider._sync_thread = None
    return provider


class FeatureFlagTests(unittest.TestCase):
    def setUp(self):
        _clear_flags()

    def tearDown(self):
        _clear_flags()

    def test_default_enabled(self):
        self.assertTrue(ci._feature_enabled("CI_INTENTS_ENABLED"))

    def test_falsy_values_disable(self):
        for val in ("0", "false", "FALSE", "no", "off", " Off "):
            os.environ["CI_INTENTS_ENABLED"] = val
            self.assertFalse(ci._feature_enabled("CI_INTENTS_ENABLED"), val)

    def test_other_values_enable(self):
        for val in ("1", "true", "yes", "on", "whatever"):
            os.environ["CI_INTENTS_ENABLED"] = val
            self.assertTrue(ci._feature_enabled("CI_INTENTS_ENABLED"), val)


class ExtractBlockTests(unittest.TestCase):
    def test_block_then_text_then_context(self):
        self.assertEqual(ci._extract_block({"block": "b", "text": "t"}), "b")
        self.assertEqual(ci._extract_block({"text": "t", "context": "c"}), "t")
        self.assertEqual(ci._extract_block({"context": "c"}), "c")
        self.assertEqual(ci._extract_block({}), "")
        self.assertEqual(ci._extract_block(None), "")


class CIClientDriftTests(unittest.TestCase):
    def _client(self):
        return ci._CIClient("http://ci-server:8642", "tok")

    def test_url_normalization_strips_api_mcp_suffix(self):
        client = ci._CIClient("http://ci-server:8642/api/mcp/", "tok")
        self.assertEqual(client._base, "http://ci-server:8642")

    def test_url_normalization_only_strips_api_mcp_and_whitespace(self):
        # A too-aggressive strip (e.g. stripping any /api/* path) must not pass.
        for url, expected in [
            ("http://ci-server:8642", "http://ci-server:8642"),
            ("http://ci-server:8642/api/memory", "http://ci-server:8642/api/memory"),
            ("  http://ci-server:8642/api/mcp  ", "http://ci-server:8642"),
        ]:
            self.assertEqual(ci._CIClient(url, "t")._base, expected, url)

    def test_recall_clamps_results(self):
        client = self._client()
        captured = {}
        client._post = lambda path, payload: captured.update(payload=payload) or {}
        client.recall("q", max_results=-3)  # negative → min bound of 1
        self.assertEqual(captured["payload"]["maxResults"], 1)
        client.recall("q", max_results=0)  # 0 is falsy → defaults to 5 (max_results or 5)
        self.assertEqual(captured["payload"]["maxResults"], 5)

    def test_recall_caps_max_results_at_20(self):
        client = self._client()
        captured = {}
        client._post = lambda path, payload: captured.update(path=path, payload=payload) or {}
        client.recall("q", max_results=999)
        self.assertEqual(captured["path"], "/api/memory/recall")
        self.assertEqual(captured["payload"]["maxResults"], 20)

    def test_write_falls_back_to_note_on_404(self):
        client = self._client()
        calls = []

        def fake_post(path, payload):
            calls.append(path)
            if path == "/api/memory/write":
                raise urllib.error.HTTPError("http://u", 404, "Not Found", None, None)
            return {"ok": True}

        client._post = fake_post
        out = client.write("hello")
        self.assertEqual(calls, ["/api/memory/write", "/api/memory/note"])
        self.assertEqual(out, {"ok": True})

    def test_write_reraises_non_404(self):
        client = self._client()

        def fake_post(path, payload):
            raise urllib.error.HTTPError("http://u", 500, "Server Error", None, None)

        client._post = fake_post
        with self.assertRaises(urllib.error.HTTPError):
            client.write("hello")


class ContextAndIntentGatingTests(unittest.TestCase):
    def setUp(self):
        _clear_flags()

    def tearDown(self):
        _clear_flags()

    def test_default_includes_context_and_catalog(self):
        client = _MockClient(block="PROFILE", manifest=_MANIFEST)
        out = _provider_with_client(client).system_prompt_block()
        self.assertIn("PROFILE", out)
        self.assertIn("memory_recall", out)  # catalog rendered
        self.assertEqual(client.context_calls, 1)

    def test_context_flag_off_skips_profile_keeps_catalog(self):
        os.environ["CI_MEMORY_CONTEXT_ENABLED"] = "false"
        client = _MockClient(block="PROFILE", manifest=_MANIFEST)
        out = _provider_with_client(client).system_prompt_block()
        self.assertEqual(client.context_calls, 0)
        self.assertNotIn("PROFILE", out)
        self.assertIn("memory_recall", out)

    def test_intents_flag_off_skips_catalog_keeps_profile(self):
        os.environ["CI_INTENTS_ENABLED"] = "false"
        client = _MockClient(block="PROFILE", manifest=_MANIFEST)
        out = _provider_with_client(client).system_prompt_block()
        self.assertIn("PROFILE", out)
        self.assertNotIn("memory_recall", out)


class RecallGatingTests(unittest.TestCase):
    def setUp(self):
        _clear_flags()

    def tearDown(self):
        _clear_flags()

    def test_recall_flag_off_no_prefetch(self):
        os.environ["CI_MEMORY_RECALL_ENABLED"] = "false"
        client = _MockClient()
        provider = _provider_with_client(client)
        provider.queue_prefetch("q")
        self.assertEqual(provider.prefetch("q"), "")
        self.assertEqual(client.recall_calls, 0)

    def test_recall_default_runs(self):
        client = _MockClient()
        provider = _provider_with_client(client)
        provider.queue_prefetch("q")
        self.assertEqual(provider.prefetch("q"), "RECALL")  # waits for the bg thread
        self.assertEqual(client.recall_calls, 1)


class TurnGatingTests(unittest.TestCase):
    def setUp(self):
        _clear_flags()

    def tearDown(self):
        _clear_flags()

    def test_turn_flag_off_no_sync(self):
        os.environ["CI_MEMORY_TURN_ENABLED"] = "false"
        client = _MockClient()
        provider = _provider_with_client(client)
        provider.sync_turn("u", "a")
        self.assertIsNone(provider._sync_thread)
        self.assertEqual(client.turn_calls, [])

    def test_turn_default_syncs_user_then_assistant(self):
        client = _MockClient()
        provider = _provider_with_client(client)
        provider.sync_turn("u", "a")
        self.assertIsNotNone(provider._sync_thread)
        provider._sync_thread.join(timeout=5)
        self.assertEqual(len(client.turn_calls), 1)
        messages, sid, platform = client.turn_calls[0]
        self.assertEqual(sid, "s1")
        self.assertEqual(platform, "hermes")
        self.assertEqual([m["role"] for m in messages], ["user", "assistant"])

    def test_truncation_uses_4000_chars(self):
        client = _MockClient()
        provider = _provider_with_client(client)
        provider.sync_turn("x" * 5000, "a")
        provider._sync_thread.join(timeout=5)
        messages, _, _ = client.turn_calls[0]
        self.assertEqual(len(messages[0]["content"]), 4000)


class WriteGatingTests(unittest.TestCase):
    def setUp(self):
        _clear_flags()

    def tearDown(self):
        _clear_flags()

    def test_write_flag_off_no_write(self):
        os.environ["CI_MEMORY_WRITE_ENABLED"] = "false"
        client = _MockClient()
        _provider_with_client(client).on_memory_write("write", "MEMORY.md", "remember this")
        self.assertEqual(client.write_calls, [])

    def test_write_default_persists(self):
        client = _MockClient()
        _provider_with_client(client).on_memory_write("write", "MEMORY.md", "remember this")
        self.assertTrue(client.write_event.wait(timeout=5))
        self.assertEqual(len(client.write_calls), 1)
        content, source, _ = client.write_calls[0]
        self.assertEqual(content, "remember this")
        self.assertEqual(source, "MEMORY.md")

    def test_clear_action_is_skipped(self):
        client = _MockClient()
        _provider_with_client(client).on_memory_write("clear", "MEMORY.md", "x")
        self.assertEqual(client.write_calls, [])


class SessionFlushGatingTests(unittest.TestCase):
    """on_session_end / on_pre_compress are gated by CI_MEMORY_TURN_ENABLED."""

    def setUp(self):
        _clear_flags()

    def tearDown(self):
        _clear_flags()

    _MESSAGES = [{"role": "user", "content": "u"}, {"role": "assistant", "content": "a"}]

    def test_session_end_off_no_flush(self):
        os.environ["CI_MEMORY_TURN_ENABLED"] = "false"
        client = _MockClient()
        _provider_with_client(client).on_session_end(self._MESSAGES)
        self.assertEqual(client.turn_calls, [])

    def test_session_end_default_flushes(self):
        client = _MockClient()
        _provider_with_client(client).on_session_end(self._MESSAGES)
        self.assertEqual(len(client.turn_calls), 1)

    def test_pre_compress_off_no_flush(self):
        os.environ["CI_MEMORY_TURN_ENABLED"] = "false"
        client = _MockClient()
        provider = _provider_with_client(client)
        provider.on_pre_compress(self._MESSAGES)
        self.assertEqual(client.turn_calls, [])


if __name__ == "__main__":
    unittest.main()
