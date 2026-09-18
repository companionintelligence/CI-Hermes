"""Tests for the ci-runtime plugin's registration paths.

The plugin has no Hermes imports, so it loads standalone. What is under test is
the choice of delivery: a frozen system-prompt section on a host that offers
one, the per-turn ``pre_llm_call`` hook everywhere else, and the fallbacks
between them.

Run: ``python3 -m unittest plugin_test`` from this directory.
"""

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
# The directory name has a hyphen, so it cannot be imported as a package; load
# the module from its path, the way Hermes' plugin loader does.
_spec = importlib.util.spec_from_file_location("ci_runtime_plugin", os.path.join(_HERE, "__init__.py"))
plugin = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = plugin
_spec.loader.exec_module(plugin)


class _RecordingCtx:
    """A plugin context with both registration APIs, recording each call."""

    def __init__(self, *, section_error=None):
        self.sections = []
        self.hooks = []
        self._section_error = section_error

    def register_system_prompt_section(self, id, content, *, position="after_memory", max_chars=4000):
        if self._section_error is not None:
            raise self._section_error
        self.sections.append((id, content, position, max_chars))

    def register_hook(self, name, callback):
        self.hooks.append((name, callback))


class _LegacyCtx:
    """A plugin context from before system-prompt sections existed (Hermes < v0.21)."""

    def __init__(self):
        self.hooks = []

    def register_hook(self, name, callback):
        self.hooks.append((name, callback))


class FormatTests(unittest.TestCase):
    def test_title_becomes_a_colon_terminated_lead_line(self):
        self.assertEqual(
            plugin._format_context("# CI Runtime Context\n\n- a\n- b"),
            "CI Runtime Context:\n- a\n- b",
        )

    def test_a_trailing_colon_on_the_title_is_not_doubled(self):
        self.assertEqual(plugin._format_context("# Title:\n- a"), "Title:\n- a")

    def test_leading_blank_lines_are_dropped(self):
        self.assertEqual(plugin._format_context("\n\n# T\n- a"), "T:\n- a")

    def test_the_shipped_context_file_formats_and_fits_the_section_cap(self):
        text = plugin._load_runtime_context()
        self.assertTrue(text.startswith("CI Runtime Context:"))
        self.assertIn("/opt/data", text)
        self.assertLessEqual(len(text), plugin.SECTION_MAX_CHARS)


class RegistrationTests(unittest.TestCase):
    def test_a_v021_host_gets_a_frozen_section_and_no_per_turn_hook(self):
        ctx = _RecordingCtx()
        plugin.register(ctx)
        self.assertEqual(len(ctx.sections), 1)
        section_id, content, position, _ = ctx.sections[0]
        self.assertEqual(section_id, "ci-runtime")
        self.assertEqual(position, "after_memory")
        self.assertEqual(content, plugin._load_runtime_context())
        self.assertEqual(ctx.hooks, [], "the section replaces the hook; both would inject twice")

    def test_a_legacy_host_gets_the_pre_llm_call_hook(self):
        ctx = _LegacyCtx()
        plugin.register(ctx)
        self.assertEqual([name for name, _ in ctx.hooks], ["pre_llm_call"])
        _, callback = ctx.hooks[0]
        result = callback(session_id="s", user_message="hi")
        self.assertEqual(result, {"context": plugin._load_runtime_context()})

    def test_a_section_api_that_refuses_falls_back_to_the_hook(self):
        ctx = _RecordingCtx(section_error=ValueError("section id taken"))
        with self.assertLogs(plugin.logger, level="WARNING") as logs:
            plugin.register(ctx)
        self.assertEqual(ctx.sections, [])
        self.assertEqual([name for name, _ in ctx.hooks], ["pre_llm_call"])
        self.assertTrue(any("injecting per turn" in line for line in logs.output))

    def test_context_over_the_section_cap_falls_back_to_the_hook(self):
        ctx = _RecordingCtx()
        huge = "# T\n" + ("- x" * 3000)
        with mock.patch.object(plugin, "_load_runtime_context", return_value=plugin._format_context(huge)):
            with self.assertLogs(plugin.logger, level="WARNING"):
                plugin.register(ctx)
        self.assertEqual(ctx.sections, [])
        self.assertEqual([name for name, _ in ctx.hooks], ["pre_llm_call"])

    def test_an_empty_context_file_is_an_error_not_an_empty_prompt(self):
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
            fh.write("\n\n")
        try:
            with mock.patch.object(plugin, "CONTEXT_FILE", Path(fh.name)):
                with self.assertRaises(RuntimeError):
                    plugin.register(_RecordingCtx())
        finally:
            os.unlink(fh.name)


if __name__ == "__main__":
    unittest.main()
