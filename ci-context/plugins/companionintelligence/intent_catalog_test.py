"""Unit tests for the CI Intent catalog client.

Pure module, no Hermes runtime required. Run from this directory:

    python -m unittest intent_catalog_test
"""

import unittest

from intent_catalog import (
    describe_catalog_for_prompt,
    execute_path_candidates,
    fetch_intent_manifest,
    manifest_to_tool_schemas,
)

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


class ManifestToToolSchemasTests(unittest.TestCase):
    def test_maps_read_intents_to_openai_function_schemas(self):
        schemas = manifest_to_tool_schemas(MANIFEST)
        # memory.forget (destructive) and media.streamingAvailability (external)
        # are filtered — only the read-only, appliance-local intent survives.
        self.assertEqual([s["name"] for s in schemas], ["memory_recall"])
        schema = schemas[0]
        self.assertEqual(set(schema.keys()), {"name", "description", "parameters"})
        self.assertIn("Recall knowledge", schema["description"])
        self.assertIn("Recall stored facts.", schema["description"])
        self.assertEqual(schema["parameters"], {"type": "object"})

    def test_filters_destructive_and_external(self):
        names = {s["name"] for s in manifest_to_tool_schemas(MANIFEST)}
        self.assertNotIn("memory_forget", names)
        self.assertNotIn("media_streamingAvailability", names)

    def test_include_filters_by_tool_or_dotted_name(self):
        manifest = {
            "intents": [
                dict(MANIFEST["intents"][0]),
                {
                    "name": "people.find",
                    "tool": "people_find",
                    "domain": "people",
                    "title": "Find people",
                    "description": "Find people.",
                    "parameters": {"type": "object"},
                    "privacy": {"access": "read", "destructive": False, "external": False},
                },
            ]
        }
        self.assertEqual(
            [s["name"] for s in manifest_to_tool_schemas(manifest, include={"memory_recall"})],
            ["memory_recall"],
        )
        # The dotted intent id works as an include key too.
        self.assertEqual(
            [s["name"] for s in manifest_to_tool_schemas(manifest, include={"people.find"})],
            ["people_find"],
        )

    def test_degrades_to_empty_on_missing_or_malformed(self):
        self.assertEqual(manifest_to_tool_schemas(None), [])
        self.assertEqual(manifest_to_tool_schemas({}), [])
        self.assertEqual(manifest_to_tool_schemas({"intents": "nope"}), [])
        self.assertEqual(manifest_to_tool_schemas({"intents": ["nope", 3]}), [])

    def test_intent_without_tool_name_is_skipped(self):
        manifest = {"intents": [{"name": "x.y", "title": "T", "privacy": {}}]}
        self.assertEqual(manifest_to_tool_schemas(manifest), [])

    def test_missing_parameters_default_to_empty_object_schema(self):
        manifest = {
            "intents": [
                {
                    "name": "a.b",
                    "tool": "a_b",
                    "title": "AB",
                    "description": "d",
                    "privacy": {"destructive": False, "external": False},
                }
            ]
        }
        schemas = manifest_to_tool_schemas(manifest)
        self.assertEqual(schemas[0]["parameters"], {"type": "object", "properties": {}})


class ExecutePathCandidatesTests(unittest.TestCase):
    def test_mirrors_catalog_path_fallback_ordering(self):
        self.assertEqual(
            execute_path_candidates("predictions_forecast"),
            [
                "/api/agent/intents/predictions_forecast/execute",
                "/api/intents/predictions_forecast/execute",
            ],
        )

    def test_accepts_dotted_intent_ids(self):
        self.assertEqual(
            execute_path_candidates("predictions.forecast"),
            [
                "/api/agent/intents/predictions.forecast/execute",
                "/api/intents/predictions.forecast/execute",
            ],
        )

    def test_url_encodes_unsafe_characters(self):
        paths = execute_path_candidates("a/b c")
        self.assertEqual(paths[0], "/api/agent/intents/a%2Fb%20c/execute")

    def test_empty_name_yields_no_candidates(self):
        self.assertEqual(execute_path_candidates(""), [])
        self.assertEqual(execute_path_candidates("   "), [])
        self.assertEqual(execute_path_candidates(None), [])


if __name__ == "__main__":
    unittest.main()
