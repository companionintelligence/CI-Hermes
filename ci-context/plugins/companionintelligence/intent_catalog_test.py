"""Unit tests for the CI Intent catalog client.

Pure module, no Hermes runtime required. Run from this directory:

    python -m unittest intent_catalog_test
"""

import unittest

from intent_catalog import describe_catalog_for_prompt, fetch_intent_manifest

MANIFEST = {
    "version": "1.0.0",
    "domains": [
        {"key": "memory", "title": "Memory", "description": "Recall/remember/forget."},
        {"key": "media", "title": "Media", "description": "Photos and entertainment."},
    ],
    "entities": [],
    "intents": [
        {
            "name": "memory.recall",
            "tool": "memory_recall",
            "domain": "memory",
            "title": "Recall knowledge",
            "description": "Recall stored facts.",
            "parameters": {"type": "object"},
            "privacy": {"access": "read", "sensitivity": "personal", "destructive": False, "external": False},
        },
        {
            "name": "memory.forget",
            "tool": "memory_forget",
            "domain": "memory",
            "title": "Forget knowledge",
            "description": "Archive or delete knowledge.",
            "parameters": {"type": "object"},
            "privacy": {"access": "delete", "sensitivity": "personal", "destructive": True, "external": False},
        },
        {
            "name": "media.streamingAvailability",
            "tool": "media_streamingAvailability",
            "domain": "media",
            "title": "Find where to stream",
            "description": "Resolve streaming availability.",
            "parameters": {"type": "object"},
            "privacy": {"access": "read", "sensitivity": "low", "destructive": False, "external": True},
        },
    ],
}


class FetchIntentManifestTests(unittest.TestCase):
    def test_prefers_the_canonical_agent_path(self):
        called = {}

        def get_json(path):
            called["path"] = path
            return MANIFEST

        manifest = fetch_intent_manifest(get_json)
        self.assertEqual(called["path"], "/api/agent/intents")
        self.assertEqual(len(manifest["intents"]), 3)

    def test_falls_back_to_legacy_api_intents_when_agent_path_404s(self):
        seen = []

        def get_json(path):
            seen.append(path)
            if path == "/api/agent/intents":
                raise RuntimeError("HTTP 404")  # older CI-Server
            return MANIFEST

        manifest = fetch_intent_manifest(get_json)
        self.assertEqual(seen, ["/api/agent/intents", "/api/intents"])
        self.assertEqual(len(manifest["intents"]), 3)

    def test_degrades_to_none_on_error_or_malformed(self):
        def boom(_path):
            raise RuntimeError("CI-Server down")

        self.assertIsNone(fetch_intent_manifest(boom))
        self.assertIsNone(fetch_intent_manifest(lambda _p: {}))
        self.assertIsNone(fetch_intent_manifest(lambda _p: None))


class DescribeCatalogTests(unittest.TestCase):
    def test_groups_by_domain_and_flags_destructive_external(self):
        text = describe_catalog_for_prompt(MANIFEST)
        self.assertIn("### memory", text)
        self.assertIn("### media", text)
        self.assertIn("`memory_recall`", text)
        self.assertIn("destructive", text)
        self.assertIn("external", text)

    def test_empty_for_missing_or_empty_manifest(self):
        self.assertEqual(describe_catalog_for_prompt(None), "")
        self.assertEqual(describe_catalog_for_prompt({"intents": []}), "")


if __name__ == "__main__":
    unittest.main()
