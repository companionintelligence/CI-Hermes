"""Functional tests for the Companion Intelligence Hermes plugin.

The plugin subclasses ``agent.memory_provider.MemoryProvider``, which only exists
inside the Hermes runtime. We stub that base so the module imports standalone,
then exercise the REAL client + provider logic (feature-flag gating, the
memory-client drift fixes, and the intent-catalog injection) with mocks.

Run: ``python3 -m unittest provider_test`` from this directory.
"""

import http.server
import io
import json
import os
import sys
import tempfile
import threading
import types
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

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

# The UTF-8 BOM, spelled as the bytes it actually is. Every BOM fixture below builds
# on this rather than embedding a U+FEFF in a string literal, where it is invisible in
# review and one editor normalization away from vanishing — taking the whole point of
# the test with it and leaving it green.
_UTF8_BOM = b"\xef\xbb\xbf"

_FLAGS = (
    "CI_MEMORY_CONTEXT_ENABLED",
    "CI_MEMORY_RECALL_ENABLED",
    "CI_MEMORY_TURN_ENABLED",
    "CI_MEMORY_WRITE_ENABLED",
    "CI_INTENTS_ENABLED",
    "CI_INTENT_TOOLS_ENABLED",
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
        self.get_calls = []
        self.invoke_calls = []
        self.invoke_result = {"success": True, "data": {"ok": 1}}
        self.invoke_error = None

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

    def invoke_intent(self, name, arguments=None):
        self.invoke_calls.append((name, arguments))
        if self.invoke_error is not None:
            raise self.invoke_error
        return self.invoke_result

    def _get(self, path):  # used by fetch_intent_manifest
        self.get_calls.append(path)
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

    def test_write_does_not_retry_a_dead_alias_on_404(self):
        # This asserted the opposite until 2026-09: a 404 fell back to
        # /api/memory/note, a route CI-Server renamed to /write on 2026-06-03.
        # The fallback therefore turned one 404 into two and raised the second,
        # which is strictly worse than reporting the first.
        client = self._client()
        calls = []

        def fake_post(path, payload):
            calls.append(path)
            raise urllib.error.HTTPError("http://u", 404, "Not Found", None, None)

        client._post = fake_post
        with self.assertRaises(urllib.error.HTTPError):
            client.write("hello")
        self.assertEqual(calls, ["/api/memory/write"])

    def test_write_reraises_non_404(self):
        client = self._client()

        def fake_post(path, payload):
            raise urllib.error.HTTPError("http://u", 500, "Server Error", None, None)

        client._post = fake_post
        with self.assertRaises(urllib.error.HTTPError):
            client.write("hello")


class _FakeResp:
    """Minimal urllib response usable as a context manager."""

    def __init__(self, body=b"{}", status=200):
        self._body = body
        self.status = status

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class MemoryTransportTests(unittest.TestCase):
    """The /api/memory/* transport: request construction, auth header, parsing."""

    def _client(self):
        return ci._CIClient("http://ci-server:8642", "tok")

    def _capture(self, body=b"{}"):
        captured = {}

        def fake_urlopen(req, timeout=None):
            captured["url"] = req.full_url
            captured["method"] = req.get_method()
            captured["api_key"] = req.get_header("X-api-key")
            captured["content_type"] = req.get_header("Content-type")
            captured["accept"] = req.get_header("Accept")
            captured["body"] = req.data
            return _FakeResp(body)

        return captured, fake_urlopen

    def test_context_issues_authenticated_get(self):
        cap, fake = self._capture(b'{"block":"PROFILE"}')
        with mock.patch.object(ci, "_urlopen", fake):
            out = self._client().context()
        self.assertTrue(cap["url"].endswith("/api/memory/context"))
        self.assertEqual(cap["method"], "GET")
        self.assertEqual(cap["api_key"], "tok")
        self.assertEqual(cap["accept"], "application/json")
        self.assertEqual(out, {"block": "PROFILE"})

    def test_recall_posts_query_and_capped_results(self):
        cap, fake = self._capture()
        with mock.patch.object(ci, "_urlopen", fake):
            self._client().recall("hello", 7)
        self.assertTrue(cap["url"].endswith("/api/memory/recall"))
        self.assertEqual(cap["method"], "POST")
        self.assertEqual(cap["content_type"], "application/json")
        self.assertEqual(json.loads(cap["body"]), {"query": "hello", "maxResults": 7})

    def test_turn_payload_includes_session_and_platform(self):
        cap, fake = self._capture()
        with mock.patch.object(ci, "_urlopen", fake):
            self._client().turn([{"role": "user", "content": "u"}], session_id="s1", platform="hermes")
        body = json.loads(cap["body"])
        self.assertEqual(body["messages"], [{"role": "user", "content": "u"}])
        self.assertEqual(body["sessionId"], "s1")
        self.assertEqual(body["platform"], "hermes")

    def test_turn_payload_omits_empty_session_and_platform(self):
        cap, fake = self._capture()
        with mock.patch.object(ci, "_urlopen", fake):
            self._client().turn([{"role": "user", "content": "u"}])
        body = json.loads(cap["body"])
        self.assertNotIn("sessionId", body)
        self.assertNotIn("platform", body)

    def test_write_payload_includes_supplied_fields_only(self):
        cap, fake = self._capture()
        with mock.patch.object(ci, "_urlopen", fake):
            self._client().write("note text", source="MEMORY.md", title="T", session_id="s")
        self.assertTrue(cap["url"].endswith("/api/memory/write"))
        self.assertEqual(
            json.loads(cap["body"]),
            {"content": "note text", "source": "MEMORY.md", "title": "T", "sessionId": "s"},
        )

    def test_write_payload_omits_empty_optionals(self):
        cap, fake = self._capture()
        with mock.patch.object(ci, "_urlopen", fake):
            self._client().write("just content")
        self.assertEqual(json.loads(cap["body"]), {"content": "just content"})

    def test_empty_body_parses_to_empty_dict(self):
        _, fake = self._capture(b"")
        with mock.patch.object(ci, "_urlopen", fake):
            self.assertEqual(self._client().context(), {})

    def test_http_error_propagates(self):
        def fake(req, timeout=None):
            raise urllib.error.HTTPError(req.full_url, 500, "err", None, None)

        with mock.patch.object(ci, "_urlopen", fake):
            with self.assertRaises(urllib.error.HTTPError):
                self._client().context()

    def test_post_sets_accept_and_content_type_on_recall_turn_write(self):
        # The CI-Server contract expects JSON in/out; every POST must say so.
        for op in (
            lambda c: c.recall("q"),
            lambda c: c.turn([{"role": "user", "content": "u"}]),
            lambda c: c.write("note"),
        ):
            cap, fake = self._capture()
            with mock.patch.object(ci, "_urlopen", fake):
                op(self._client())
            self.assertEqual(cap["accept"], "application/json")
            self.assertEqual(cap["content_type"], "application/json")
            self.assertEqual(cap["api_key"], "tok")


class UserAgentTests(unittest.TestCase):
    """Every request must name itself.

    urllib defaults to ``Python-urllib/<x.y>``, which edge proxies in front of a
    CI-Server deployment block outright — Cloudflare answers that signature 403
    ("Error 1010") before the request reaches the server. Nothing in the plugin
    surfaces it: writes are swallowed rather than allowed to break a session, so a
    blocked plugin is indistinguishable from a working one that has nothing to
    say. These tests exist because that failure has no other symptom.
    """

    def _capture_ua(self, body=b"{}"):
        captured = {}

        def fake_urlopen(req, timeout=None):
            captured["user_agent"] = req.get_header("User-agent")
            return _FakeResp(body)

        return captured, fake_urlopen

    def test_every_client_path_sends_the_product_user_agent(self):
        # Named individually rather than trusting the shared helper: the bug being
        # fixed was one path missing a header the others had.
        client = ci._CIClient("http://ci-server:8642", "tok")
        for label, op in (
            ("context", lambda: client.context()),
            ("recall", lambda: client.recall("q")),
            ("turn", lambda: client.turn([{"role": "user", "content": "u"}])),
            ("write", lambda: client.write("note")),
            ("intent", lambda: client.invoke_intent("memory_search", {})),
            ("health", lambda: client.health()),
        ):
            cap, fake = self._capture_ua()
            with mock.patch.object(ci, "_urlopen", fake):
                op()
            self.assertEqual(cap["user_agent"], ci._USER_AGENT, f"{label} sent {cap.get('user_agent')!r}")
            self.assertNotIn("Python-urllib", cap["user_agent"] or "", label)

    def test_user_agent_names_the_package_and_a_version(self):
        self.assertRegex(ci._USER_AGENT, r"^companionintelligence-hermes-memory/\S+$")

    def test_explicit_header_suppresses_urllibs_default(self):
        # Load-bearing and subtle: urllib looks for its own default under the
        # CAPITALIZED key, and add_header stores "User-Agent" as "User-agent". If
        # those ever stopped agreeing, urllib would re-add Python-urllib and the
        # 403 would come back with every other test still passing.
        req = ci._build_request("http://ci-server:8642/api/health", "tok", method="GET")
        self.assertTrue(req.has_header("User-agent"))
        self.assertEqual(req.get_header("User-agent"), ci._USER_AGENT)

    def test_content_type_is_set_only_when_there_is_a_body(self):
        get = ci._build_request("http://h/x", "tok", method="GET")
        post = ci._build_request("http://h/x", "tok", method="POST", data=b"{}")
        self.assertIsNone(get.get_header("Content-type"))
        self.assertEqual(post.get_header("Content-type"), "application/json")
        for req in (get, post):
            self.assertEqual(req.get_header("X-api-key"), "tok")
            self.assertEqual(req.get_header("Accept"), "application/json")


class PluginVersionTests(unittest.TestCase):
    def test_reads_the_version_stamped_into_plugin_yaml(self):
        # scripts/pack-memory-plugin.sh rewrites this line at release time, so the
        # User-Agent reports whatever version was actually packed.
        stamped = ""
        with open(os.path.join(_HERE, "plugin.yaml"), encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("version:"):
                    stamped = line.split(":", 1)[1].strip()
                    break
        self.assertTrue(stamped, "plugin.yaml has no version: line to stamp")
        self.assertEqual(ci._plugin_version(), stamped)

    def test_unreadable_manifest_degrades_to_unknown(self):
        # A missing manifest costs the User-Agent its version. It must not raise:
        # this runs at import time, so an exception here disables the plugin.
        with mock.patch.object(ci.Path, "read_text", side_effect=OSError("nope")):
            self.assertEqual(ci._plugin_version(), "unknown")


class SetupProbeTests(unittest.TestCase):
    """`hermes memory setup`'s own connection test — the first request a user makes."""

    def _run_setup(self, urlopen, url="http://ci-server:8642", token="tok"):
        """Drive post_setup end to end, returning (stdout, saved config.yaml dict)."""
        hermes_cli = types.ModuleType("hermes_cli")
        config_mod = types.ModuleType("hermes_cli.config")
        saved = {}
        config_mod.save_config = lambda cfg: saved.update(cfg)
        hermes_cli.config = config_mod

        config = {}
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as home:
            with mock.patch.dict(sys.modules, {"hermes_cli": hermes_cli, "hermes_cli.config": config_mod}), \
                 mock.patch.object(ci, "_urlopen", urlopen), \
                 mock.patch.object(sys, "stdin", io.StringIO(f"{url}\n{token}\n")), \
                 mock.patch.object(sys, "stdout", out):
                ci.CompanionIntelligenceProvider().post_setup(home, config)
        return out.getvalue(), saved

    def test_probe_sends_the_product_user_agent(self):
        # The user-visible bug: this probe was the request Cloudflare rejected, so
        # setup failed with a 403 on a key and URL that were both correct.
        seen = {}

        def fake_urlopen(req, timeout=None):
            seen["user_agent"] = req.get_header("User-agent")
            seen["url"] = req.full_url
            return _FakeResp(b'{"status":"ok"}')

        text, saved = self._run_setup(fake_urlopen)
        self.assertEqual(seen["user_agent"], ci._USER_AGENT)
        self.assertTrue(seen["url"].endswith("/api/health"))
        self.assertIn("Connected", text)
        self.assertEqual(saved["memory"]["provider"], "companionintelligence")

    def test_html_error_body_is_named_as_a_proxy_not_a_bad_key(self):
        # CI-Server answers in JSON. An HTML body means the request never reached
        # it — the difference between re-minting a key and changing the address.
        def fake_urlopen(req, timeout=None):
            raise urllib.error.HTTPError(
                req.full_url, 403, "Forbidden", None,
                io.BytesIO(b"<html><head><title>Access denied</title></head></html>"),
            )

        text, saved = self._run_setup(fake_urlopen)
        self.assertIn("CDN or proxy in front of", text)
        self.assertIn("Nothing was saved", text)
        self.assertEqual(saved, {})

    def test_json_error_body_gets_no_proxy_hint(self):
        def fake_urlopen(req, timeout=None):
            raise urllib.error.HTTPError(
                req.full_url, 403, "Forbidden", None, io.BytesIO(b'{"error":"insufficient scope"}'),
            )

        text, _ = self._run_setup(fake_urlopen)
        self.assertNotIn("CDN or proxy", text)
        self.assertIn("insufficient scope", text)


class SetupConsoleAndFileHygieneTests(unittest.TestCase):
    """Hazards that only appear off a UTF-8 POSIX box: console codec, EOLs, BOMs.

    `hermes memory setup` is run from a terminal, and on Windows that terminal is
    frequently Git Bash — where stdout is a cp1252-encoded PIPE, not a console.
    """

    @staticmethod
    def _narrow_stdout():
        """Stand in for Git Bash's stdout: cp1252, strict, and it is a pipe."""
        return io.TextIOWrapper(io.BytesIO(), encoding="cp1252", newline="")

    def _run(self, urlopen, *, home, stdout=None, url="http://ci-server:8642", token="tok"):
        """post_setup against a real temp home; returns (stdout_text, saved)."""
        hermes_cli = types.ModuleType("hermes_cli")
        config_mod = types.ModuleType("hermes_cli.config")
        saved = {}
        config_mod.save_config = lambda cfg: saved.update(cfg)
        hermes_cli.config = config_mod
        out = stdout if stdout is not None else io.StringIO()

        with mock.patch.dict(sys.modules, {"hermes_cli": hermes_cli, "hermes_cli.config": config_mod}), \
             mock.patch.object(ci, "_urlopen", urlopen), \
             mock.patch.object(sys, "stdin", io.StringIO(f"{url}\n{token}\n")), \
             mock.patch.object(sys, "stdout", out):
            ci.CompanionIntelligenceProvider().post_setup(home, {})

        if isinstance(out, io.StringIO):
            return out.getvalue(), saved
        out.flush()
        return out.buffer.getvalue().decode("cp1252"), saved

    def test_wizard_survives_a_cp1252_console(self):
        # The whole wizard used to die here, on its second print, before the first
        # prompt: '─' has no cp1252 mapping, so print() raised UnicodeEncodeError
        # and the user got a traceback instead of a setup flow.
        with tempfile.TemporaryDirectory() as home:
            text, saved = self._run(
                lambda req, timeout=None: _FakeResp(b'{"status":"ok"}'),
                home=home,
                stdout=self._narrow_stdout(),
            )
        self.assertIn("[ok]", text, "glyphs must degrade to ASCII, not raise")
        self.assertIn("Connected", text)
        self.assertEqual(saved["memory"]["provider"], "companionintelligence")

    def test_say_never_raises_on_an_unencodable_character(self):
        # Backstop for prose and server-supplied strings the glyph constants do not
        # cover — a CJK character has no cp1252 mapping at all.
        out = self._narrow_stdout()
        with mock.patch.object(sys, "stdout", out):
            ci._say("server said: 日本語")
        out.flush()
        self.assertIn("server said:", out.buffer.getvalue().decode("cp1252"))

    def test_env_file_is_written_lf_on_every_platform(self):
        # Text mode translates \n to os.linesep, so without newline="" this file
        # goes out CRLF on Windows and a shell consumer that sources it exports the
        # token with a trailing \r.
        with tempfile.TemporaryDirectory() as home:
            self._run(lambda req, timeout=None: _FakeResp(b'{"status":"ok"}'), home=home)
            raw = (Path(home) / ".env").read_bytes()
        self.assertNotIn(b"\r\n", raw)
        self.assertIn(b"CI_SERVER_TOKEN=tok\n", raw)

    def test_bom_prefixed_env_file_replaces_the_token_rather_than_duplicating_it(self):
        # Notepad's default is UTF-8-with-BOM. Read as plain utf-8 the BOM stays glued
        # to the first line, so the first key reads as U+FEFF + "CI_SERVER_TOKEN"
        # rather than "CI_SERVER_TOKEN", the replace missed, and a SECOND token line
        # was appended — setup reported success while a first-wins loader kept using
        # the stale key.
        with tempfile.TemporaryDirectory() as home:
            env_path = Path(home) / ".env"
            env_path.write_bytes(_UTF8_BOM + b"CI_SERVER_TOKEN=stale\nOTHER=keep\n")
            self._run(
                lambda req, timeout=None: _FakeResp(b'{"status":"ok"}'),
                home=home,
                token="fresh",
            )
            lines = env_path.read_text(encoding="utf-8-sig").splitlines()
        self.assertEqual([ln for ln in lines if ln.startswith("CI_SERVER_TOKEN=")], ["CI_SERVER_TOKEN=fresh"])
        self.assertIn("OTHER=keep", lines)

    def test_an_error_quoting_the_key_does_not_print_the_key(self):
        # http.client raises ValueError("Invalid header value b'<token>\\r'") for a
        # \r-tainted key. That reached the generic handler, which printed the
        # exception verbatim — writing the user's live credential to the terminal.
        secret = "sk-live-abcdef123456"

        def fake_urlopen(req, timeout=None):
            raise ValueError(f"Invalid header value {secret!r}")

        with tempfile.TemporaryDirectory() as home:
            text, saved = self._run(fake_urlopen, home=home, token=secret)
        self.assertNotIn(secret, text)
        self.assertIn("Unexpected error", text)
        self.assertIn("3456", text, "a tail stub should survive, to identify the key")
        self.assertEqual(saved, {})

    def test_save_config_keeps_other_settings_when_the_file_has_a_bom(self):
        # Reading with the locale codec (cp1252 on Windows) raised on non-ASCII,
        # the bare except treated that as "no config", and the write-back silently
        # dropped every key it was not currently saving.
        with tempfile.TemporaryDirectory() as home:
            cfg_dir = Path(home) / "companionintelligence"
            cfg_dir.mkdir(parents=True)
            # _UTF8_BOM as explicit bytes, not a U+FEFF in the literal: an invisible
            # character is exactly what an editor or a formatter silently strips, and
            # the test would keep passing while no longer testing a BOM at all.
            (cfg_dir / "config.json").write_bytes(
                _UTF8_BOM + '{"url": "http://old", "note": "café"}'.encode("utf-8")
            )
            ci.CompanionIntelligenceProvider().save_config({"url": "http://new"}, home)
            data = json.loads((cfg_dir / "config.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(data["url"], "http://new")
        self.assertEqual(data["note"], "café", "unrelated settings must survive the write")


class LoadConfigTests(unittest.TestCase):
    """``_load_config`` is the runtime READ path — ``is_available()``, client
    construction and every session start go through it, and every failure in it is
    swallowed by design. A regression here is silent: no traceback, no warning, just
    a plugin that quietly stops using the settings the user saved.
    """

    def _home_with_config(self, raw: bytes) -> str:
        """Write *raw* as the config file of a throwaway Hermes home, and point
        ``_load_config`` at it by stubbing the module it imports lazily."""
        home = tempfile.TemporaryDirectory()
        self.addCleanup(home.cleanup)
        cfg_dir = Path(home.name) / "companionintelligence"
        cfg_dir.mkdir(parents=True)
        (cfg_dir / "config.json").write_bytes(raw)

        stub = types.ModuleType("hermes_constants")
        stub.get_hermes_home = lambda: Path(home.name)
        sys.modules["hermes_constants"] = stub
        self.addCleanup(sys.modules.pop, "hermes_constants", None)
        return home.name

    def test_a_bom_prefixed_config_is_still_read(self):
        # Notepad's default on Windows is UTF-8-with-BOM. Read as plain utf-8 the BOM
        # survives into the string, json.loads raises on it, and the bare `except`
        # treats that as "no config" — leaving the plugin on env vars alone. The saved
        # CI-Server URL is ignored and memory never accumulates, with nothing printed.
        self._home_with_config(
            _UTF8_BOM + '{"url": "http://saved:8642", "token": "from-file"}'.encode("utf-8")
        )
        # Blanked, not cleared: these are the base _load_config layers the file over,
        # so a real CI_SERVER_URL in the runner's environment would mask the read.
        with mock.patch.dict(os.environ, {"CI_SERVER_URL": "", "CI_SERVER_TOKEN": ""}):
            cfg = ci._load_config()
            self.assertEqual(cfg["url"], "http://saved:8642")
            self.assertEqual(cfg["token"], "from-file")
            self.assertTrue(
                ci.CompanionIntelligenceProvider().is_available(),
                "a saved config must be enough to make the provider available",
            )


class _OkHandler(http.server.BaseHTTPRequestHandler):
    """Answers anything with 200 and records the request-target it was given."""

    received: list

    def do_GET(self):
        type(self).received.append(self.path)
        body = b'{"status":"ok"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class ProxyBypassTests(unittest.TestCase):
    """A proxy is bypassed for addresses it could not serve — and only those.

    urllib's default opener honours the WinINET registry proxy on Windows, and its
    "bypass local addresses" rule exempts only DOTLESS hosts — so ``127.0.0.1``, the
    default address this plugin ships with, is handed to a corporate proxy and never
    arrives. Capture failures are swallowed by design, so the symptom is memory that
    silently never accumulates.

    The other direction matters just as much: a CI-Server reached at its public domain
    (the app's "Expose app" setting) may only be reachable THROUGH the corporate proxy,
    so ignoring proxies outright would trade one broken deployment for another.
    """

    def _serve(self):
        """Start a throwaway HTTP server; returns (port, received-paths)."""
        handler = type("_H", (_OkHandler,), {"received": []})
        srv = http.server.HTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.server_close)
        self.addCleanup(srv.shutdown)
        return srv.server_address[1], handler.received

    def _only_proxy(self, proxy_url: str):
        """Patch the environment down to *proxy_url* as its single proxy setting.

        ``clear=True`` matters: ``patch.dict`` otherwise MERGES, leaving the runner's
        own proxy environment to decide the outcome. An ambient ``NO_PROXY=*`` — the
        norm on exactly the corporate-proxy machines this fix targets, and the default
        in several CI images — sends urllib through ``proxy_bypass_environment``, which
        bypasses the proxy injected here and fails the public-host test on a correct
        tree. Nothing under test reads any other variable.
        """
        return mock.patch.dict(os.environ, {"http_proxy": proxy_url}, clear=True)

    def test_a_loopback_server_is_reached_despite_a_configured_proxy(self):
        port, received = self._serve()
        # Port 1 answers nothing. If the plugin honoured this proxy for loopback the
        # request would fail instead of reaching the server started above.
        with self._only_proxy("http://127.0.0.1:1"):
            self.assertTrue(ci._CIClient(f"http://127.0.0.1:{port}", "tok").health())
        # A proxied request arrives as an absolute URI; a direct one as a bare path.
        self.assertEqual(received, ["/api/health"])

    def test_a_public_server_still_goes_through_the_proxy(self):
        # The regression guard for over-correcting: on a corporate laptop the proxy is
        # the only route to an exposed CI-Server, and the hostname below resolves
        # nowhere, so this can only pass if the proxy was actually used.
        port, received = self._serve()
        with self._only_proxy(f"http://127.0.0.1:{port}"):
            self.assertTrue(ci._CIClient("http://memory.example.com", "tok").health())
        self.assertEqual(received, ["http://memory.example.com/api/health"])

    def test_direct_host_classification(self):
        for host in (
            "127.0.0.1", "::1", "[::1]", "10.1.2.3", "192.168.1.9", "172.16.0.4",
            "169.254.1.1", "100.101.102.103",           # link-local, and the tailnet range
            "ci-memory", "hub",                           # dotless: what <local> means
            "ci-memory.ci.lan", "hub.local", "box.internal", "hub.tailnet.ts.net",
            "ci-memory.ci.lan.",                          # trailing dot on an FQDN
            "CI-Memory.CI.LAN",                           # case is not significant
        ):
            self.assertTrue(ci._is_direct_host(host), f"{host} should bypass the proxy")

        # Not 203.0.113.x here: ipaddress counts the documentation ranges as private,
        # so those would pass for a reason that has nothing to do with this rule.
        for host in ("memory.example.com", "8.8.8.8", "93.184.216.34", "ci.computer", "2606:4700::1111", ""):
            self.assertFalse(ci._is_direct_host(host), f"{host} should keep the proxy")


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

    def test_whitespace_only_content_is_skipped(self):
        client = _MockClient()
        _provider_with_client(client).on_memory_write("write", "MEMORY.md", "   \n\t  ")
        self.assertEqual(client.write_calls, [])


class MemoryFlushBehaviorTests(unittest.TestCase):
    """Truncation, role filtering, and serialization across all flush paths."""

    def setUp(self):
        _clear_flags()

    def tearDown(self):
        _clear_flags()

    def test_sync_turn_truncates_both_user_and_assistant_to_4000(self):
        client = _MockClient()
        provider = _provider_with_client(client)
        provider.sync_turn("u" * 5000, "a" * 6000)
        provider._sync_thread.join(timeout=5)
        messages, _, _ = client.turn_calls[0]
        self.assertEqual(len(messages[0]["content"]), 4000)
        self.assertEqual(len(messages[1]["content"]), 4000)

    def test_session_end_truncates_messages_to_4000(self):
        client = _MockClient()
        msgs = [{"role": "user", "content": "x" * 5000}, {"role": "assistant", "content": "y" * 5000}]
        _provider_with_client(client).on_session_end(msgs)
        sent, _, _ = client.turn_calls[0]
        self.assertEqual(len(sent[0]["content"]), 4000)
        self.assertEqual(len(sent[1]["content"]), 4000)

    def test_pre_compress_truncates_messages_to_4000(self):
        client = _MockClient()
        msgs = [{"role": "user", "content": "x" * 5000}]
        _provider_with_client(client).on_pre_compress(msgs)
        # Background thread — give it a beat to land.
        for _ in range(50):
            if client.turn_calls:
                break
            threading.Event().wait(0.01)
        sent, _, _ = client.turn_calls[0]
        self.assertEqual(len(sent[0]["content"]), 4000)

    def test_session_end_drops_non_user_assistant_roles(self):
        client = _MockClient()
        msgs = [
            {"role": "system", "content": "sys"},
            {"role": "user", "content": "u"},
            {"role": "tool", "content": "t"},
            {"role": "assistant", "content": "a"},
        ]
        _provider_with_client(client).on_session_end(msgs)
        sent, _, _ = client.turn_calls[0]
        self.assertEqual([m["role"] for m in sent], ["user", "assistant"])

    def test_sync_turn_serializes_back_to_back_calls(self):
        # Two rapid sync_turn() calls must serialize; the second waits for the
        # first to land so writes can't reorder against the same session.
        client = _MockClient()
        provider = _provider_with_client(client)
        provider.sync_turn("u1", "a1")
        first = provider._sync_thread
        provider.sync_turn("u2", "a2")
        second = provider._sync_thread
        self.assertIsNot(first, second)
        second.join(timeout=5)
        # The first call's user content must appear in the first persisted turn.
        self.assertEqual(client.turn_calls[0][0][0]["content"], "u1")
        self.assertEqual(client.turn_calls[1][0][0]["content"], "u2")


class PrefetchResultParsingTests(unittest.TestCase):
    """prefetch() must honour the block | text | context fallback chain."""

    def setUp(self):
        _clear_flags()

    def tearDown(self):
        _clear_flags()

    def _provider_returning(self, payload):
        client = _MockClient()
        client.recall = lambda q, max_results=5: payload
        provider = _provider_with_client(client)
        return provider

    def test_prefetch_uses_text_when_block_missing(self):
        provider = self._provider_returning({"text": "FALLBACK-TEXT"})
        provider.queue_prefetch("q")
        self.assertEqual(provider.prefetch("q"), "FALLBACK-TEXT")

    def test_prefetch_uses_context_when_block_and_text_missing(self):
        provider = self._provider_returning({"context": "FALLBACK-CTX"})
        provider.queue_prefetch("q")
        self.assertEqual(provider.prefetch("q"), "FALLBACK-CTX")


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


class IntentToolSchemaTests(unittest.TestCase):
    """get_tool_schemas — catalog-backed tool registration with session caching."""

    def setUp(self):
        _clear_flags()

    def tearDown(self):
        _clear_flags()

    def test_default_exposes_read_intents_as_openai_schemas(self):
        client = _MockClient(manifest=_MANIFEST)
        schemas = _provider_with_client(client).get_tool_schemas()
        self.assertEqual([s["name"] for s in schemas], ["memory_recall"])
        self.assertEqual(set(schemas[0].keys()), {"name", "description", "parameters"})
        self.assertEqual(schemas[0]["parameters"], {"type": "object"})

    def test_schemas_are_cached_after_first_call(self):
        client = _MockClient(manifest=_MANIFEST)
        provider = _provider_with_client(client)
        first = provider.get_tool_schemas()
        fetches = len(client.get_calls)
        second = provider.get_tool_schemas()
        self.assertEqual(first, second)
        self.assertEqual(len(client.get_calls), fetches)  # no re-fetch

    def test_intent_tools_flag_off_exposes_nothing(self):
        os.environ["CI_INTENT_TOOLS_ENABLED"] = "false"
        client = _MockClient(manifest=_MANIFEST)
        self.assertEqual(_provider_with_client(client).get_tool_schemas(), [])
        self.assertEqual(client.get_calls, [])  # no catalog fetch at all

    def test_master_intents_flag_off_exposes_nothing(self):
        os.environ["CI_INTENTS_ENABLED"] = "false"
        client = _MockClient(manifest=_MANIFEST)
        self.assertEqual(_provider_with_client(client).get_tool_schemas(), [])

    def test_unreachable_catalog_degrades_to_empty_and_caches(self):
        client = _MockClient(manifest=_MANIFEST)

        def boom(_path):
            raise RuntimeError("CI-Server down")

        client._get = boom
        provider = _provider_with_client(client)
        self.assertEqual(provider.get_tool_schemas(), [])
        # The failure is cached: the routing table was built from the first
        # answer, so later calls must not start advertising unroutable tools.
        client._get = lambda path: _MANIFEST
        self.assertEqual(provider.get_tool_schemas(), [])

    def test_works_before_initialize_by_building_client_from_config(self):
        # MemoryManager.add_provider() calls get_tool_schemas() BEFORE
        # initialize(), so no session client exists yet.
        client = _MockClient(manifest=_MANIFEST)
        provider = ci.CompanionIntelligenceProvider()  # _client is None
        env = {"CI_SERVER_URL": "http://ci-server:8642", "CI_SERVER_TOKEN": "tok"}
        with mock.patch.dict(os.environ, env), \
                mock.patch.object(ci, "_CIClient", return_value=client):
            schemas = provider.get_tool_schemas()
        self.assertEqual([s["name"] for s in schemas], ["memory_recall"])

    def test_no_config_and_no_client_exposes_nothing(self):
        provider = ci.CompanionIntelligenceProvider()
        with mock.patch.dict(os.environ):
            os.environ.pop("CI_SERVER_URL", None)
            os.environ.pop("CI_SERVER_TOKEN", None)
            self.assertEqual(provider.get_tool_schemas(), [])


class HandleToolCallTests(unittest.TestCase):
    """handle_tool_call — JSON-string results, structured errors, never raises."""

    def setUp(self):
        _clear_flags()

    def tearDown(self):
        _clear_flags()

    def test_happy_path_returns_tool_result_as_json_string(self):
        client = _MockClient(manifest=_MANIFEST)
        client.invoke_result = {"success": True, "data": {"hello": "world"}}
        out = _provider_with_client(client).handle_tool_call("memory_recall", {"query": "ada"})
        self.assertIsInstance(out, str)
        self.assertEqual(json.loads(out), {"success": True, "data": {"hello": "world"}})
        self.assertEqual(client.invoke_calls, [("memory_recall", {"query": "ada"})])

    def test_none_args_default_to_empty_input(self):
        client = _MockClient(manifest=_MANIFEST)
        _provider_with_client(client).handle_tool_call("memory_recall", None)
        self.assertEqual(client.invoke_calls, [("memory_recall", {})])

    def test_http_403_returns_structured_error_with_server_detail(self):
        client = _MockClient(manifest=_MANIFEST)
        exc = urllib.error.HTTPError("http://u", 403, "Forbidden", None, None)
        exc.ci_body = "destructive intents need the dispatcher"
        client.invoke_error = exc
        out = _provider_with_client(client).handle_tool_call("memory_forget", {})
        payload = json.loads(out)
        self.assertFalse(payload["success"])
        self.assertIn("403", payload["error"])
        self.assertIn("destructive intents need the dispatcher", payload["error"])

    def test_http_404_mentions_missing_executor(self):
        client = _MockClient(manifest=_MANIFEST)
        client.invoke_error = urllib.error.HTTPError("http://u", 404, "Not Found", None, None)
        payload = json.loads(_provider_with_client(client).handle_tool_call("nope_tool", {}))
        self.assertFalse(payload["success"])
        self.assertIn("404", payload["error"])

    def test_unexpected_exception_never_raises(self):
        client = _MockClient(manifest=_MANIFEST)
        client.invoke_error = RuntimeError("socket exploded")
        payload = json.loads(_provider_with_client(client).handle_tool_call("memory_recall", {}))
        self.assertFalse(payload["success"])
        self.assertIn("socket exploded", payload["error"])

    def test_missing_client_returns_structured_error(self):
        provider = ci.CompanionIntelligenceProvider()
        with mock.patch.dict(os.environ):
            os.environ.pop("CI_SERVER_URL", None)
            os.environ.pop("CI_SERVER_TOKEN", None)
            payload = json.loads(provider.handle_tool_call("memory_recall", {}))
        self.assertFalse(payload["success"])
        self.assertIn("not configured", payload["error"])


class InvokeIntentTransportTests(unittest.TestCase):
    """_CIClient.invoke_intent — execute-path fallback ordering (canonical → legacy)."""

    def _client(self):
        return ci._CIClient("http://ci-server:8642", "tok")

    def test_posts_to_canonical_execute_path_first(self):
        client = self._client()
        captured = {}
        client._post = lambda path, payload: captured.update(path=path, payload=payload) or {"success": True}
        out = client.invoke_intent("predictions_forecast", {"horizon": "24h"})
        self.assertEqual(captured["path"], "/api/agent/intents/predictions_forecast/execute")
        self.assertEqual(captured["payload"], {"horizon": "24h"})
        self.assertEqual(out, {"success": True})

    def test_falls_back_to_legacy_path_on_route_miss_404(self):
        client = self._client()
        seen = []

        def fake_post(path, payload):
            seen.append(path)
            if path.startswith("/api/agent/"):
                raise urllib.error.HTTPError("http://u", 404, "Not Found", None, None)
            return {"success": True}

        client._post = fake_post
        out = client.invoke_intent("predictions.forecast")
        self.assertEqual(
            seen,
            [
                "/api/agent/intents/predictions.forecast/execute",
                "/api/intents/predictions.forecast/execute",
            ],
        )
        self.assertEqual(out, {"success": True})

    def test_non_404_http_error_propagates_without_fallback(self):
        client = self._client()
        seen = []

        def fake_post(path, payload):
            seen.append(path)
            raise urllib.error.HTTPError("http://u", 403, "Forbidden", None, None)

        client._post = fake_post
        with self.assertRaises(urllib.error.HTTPError):
            client.invoke_intent("memory_forget")
        self.assertEqual(len(seen), 1)

    def test_404_on_every_candidate_reraises_the_404(self):
        client = self._client()

        def fake_post(path, payload):
            raise urllib.error.HTTPError("http://u", 404, "Not Found", None, None)

        client._post = fake_post
        with self.assertRaises(urllib.error.HTTPError):
            client.invoke_intent("unknown_intent")

    def test_empty_name_raises_value_error(self):
        with self.assertRaises(ValueError):
            self._client().invoke_intent("")


class SystemPromptCallableLineTests(unittest.TestCase):
    """The catalog block advertises callable tools only when registration is active."""

    def setUp(self):
        _clear_flags()

    def tearDown(self):
        _clear_flags()

    def test_callable_line_present_when_tools_active(self):
        client = _MockClient(block="PROFILE", manifest=_MANIFEST)
        out = _provider_with_client(client).system_prompt_block()
        self.assertIn("memory_recall", out)
        self.assertIn("registered as callable tools", out)

    def test_callable_line_absent_when_tools_flag_off(self):
        os.environ["CI_INTENT_TOOLS_ENABLED"] = "false"
        client = _MockClient(block="PROFILE", manifest=_MANIFEST)
        out = _provider_with_client(client).system_prompt_block()
        self.assertIn("memory_recall", out)  # catalog still injected
        self.assertNotIn("registered as callable tools", out)

    def test_callable_line_absent_when_no_tools_registered(self):
        # Catalog reachable but every intent filtered (destructive) → no line.
        destructive_only = {
            "intents": [
                {
                    "name": "memory.forget",
                    "tool": "memory_forget",
                    "domain": "memory",
                    "title": "Forget",
                    "description": "Delete knowledge.",
                    "parameters": {"type": "object"},
                    "privacy": {"access": "delete", "destructive": True, "external": False},
                }
            ]
        }
        client = _MockClient(block="PROFILE", manifest=destructive_only)
        out = _provider_with_client(client).system_prompt_block()
        self.assertIn("memory_forget", out)  # still described in the catalog
        self.assertNotIn("registered as callable tools", out)


if __name__ == "__main__":
    unittest.main()
