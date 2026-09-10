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


    def test_reports_every_failed_path_when_no_candidate_yields_a_manifest(self):
        # The regression guard for CI-Server#1684: both paths 404'd through the
        # gateway, this returned None, and nothing anywhere said so.
        reported = []

        def boom(path):
            raise RuntimeError("HTTP 404 for %s" % path)

        self.assertIsNone(fetch_intent_manifest(boom, reported.extend))
        self.assertEqual(len(reported), 2)
        self.assertIn("/api/agent/intents: HTTP 404", reported[0])
        self.assertIn("/api/intents: HTTP 404", reported[1])

    def test_names_a_200_that_is_not_a_manifest(self):
        # nginx serves the SPA rather than 404ing for an unmatched /api path, so
        # the body parses fine and simply has no intents[]. "Malformed" must be a
        # distinguishable reason, not a silent None.
        reported = []
        self.assertIsNone(fetch_intent_manifest(lambda _p: {"ok": True}, reported.extend))
        self.assertEqual(len(reported), 2)
        self.assertTrue(all("200 without an intents[] list" in line for line in reported))

    def test_stays_silent_when_a_fallback_path_succeeds(self):
        called = []

        def get_json(path):
            if path == "/api/agent/intents":
                raise RuntimeError("HTTP 404")
            return MANIFEST

        manifest = fetch_intent_manifest(get_json, called.append)
        self.assertEqual(len(manifest["intents"]), 3)
        self.assertEqual(
            called, [], "a working legacy alias is not a failure worth warning about"
        )


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
        # All three map now: the gated two are approval-carded by CI-Server rather
        # than refused, so hiding them would make the card unreachable. Order
        # follows the manifest.
        self.assertEqual(
            [s["name"] for s in schemas],
            ["memory_recall", "memory_forget", "media_streamingAvailability"],
        )
        schema = schemas[0]
        self.assertEqual(set(schema.keys()), {"name", "description", "parameters"})
        self.assertIn("Recall knowledge", schema["description"])
        self.assertIn("Recall stored facts.", schema["description"])
        self.assertEqual(schema["parameters"], {"type": "object"})

    def test_maps_gated_intents_too_and_says_the_owner_decides(self):
        # This asserted the opposite until 2026-09. Skipping destructive and
        # external intents was correct while a connect key held `write` —
        # CI-Server refused them before its gate, so offering the tool bought
        # only a confusing 403. CI-Server now mints these keys at `full` and
        # queues anything irreversible as an approval card, which makes a hidden
        # tool a card the agent can never ask for.
        schemas = {s["name"]: s for s in manifest_to_tool_schemas(MANIFEST)}
        self.assertIn("memory_forget", schemas)
        self.assertIn("media_streamingAvailability", schemas)

        # A gated tool warns in its description, because a model that discovers
        # the gate by calling will read the queued result as a failure and retry.
        self.assertIn("Requires the owner's approval", schemas["memory_forget"]["description"])
        self.assertIn("do NOT call it again", schemas["memory_forget"]["description"])

        # An ungated one is left alone — a warning on every read would be noise.
        self.assertNotIn(
            "Requires the owner's approval",
            schemas["memory_recall"]["description"],
        )

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
