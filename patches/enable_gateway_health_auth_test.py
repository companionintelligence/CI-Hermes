"""Unit tests for enable_gateway_health_auth — stdlib unittest, no dependencies.

Run from this directory:  python3 -m unittest discover -p '*_test.py' --verbose

Upstream's ``hermes_cli`` is not importable here (it needs the dashboard's deps), so
the tests stand in fake ``hermes_cli.web_server`` / ``hermes_cli.web_server_gateway``
modules and a fake ``urlopen``; the Docker build runs the static contract check
against the real tree.
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import textwrap
import types
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import check_gateway_health_auth_contract as contract  # noqa: E402
import enable_gateway_health_auth as shim  # noqa: E402

KEY = "0123456789abcdef0123456789abcdef"


def _fake_response(body: dict, status: int = 200):
    """A context manager standing in for the ``urlopen`` result."""
    resp = mock.MagicMock()
    resp.status = status
    resp.read.return_value = json.dumps(body).encode()
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False
    return resp


def _http_error(url: str, code: int):
    return urllib.error.HTTPError(url, code, "nope", hdrs=None, fp=None)


class _ShimState(unittest.TestCase):
    """Every test starts with no finder on sys.meta_path and nothing marked patched —
    the shim installs itself at import time from whatever env the runner has."""

    def setUp(self):
        self._saved_modules = {k: sys.modules.get(k) for k in ("hermes_cli", "hermes_cli.web_server",
                                                              "hermes_cli.web_server_gateway")}
        self._reset()

    def tearDown(self):
        self._reset()
        for name, module in self._saved_modules.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module

    @staticmethod
    def _reset():
        sys.meta_path[:] = [f for f in sys.meta_path if not isinstance(f, shim._PostImportPatcher)]
        shim._patched.clear()
        for name in ("hermes_cli.web_server_gateway", "hermes_cli.web_server", "hermes_cli"):
            sys.modules.pop(name, None)

    @staticmethod
    def _install_fake_settings(url, timeout=1.0):
        pkg = types.ModuleType("hermes_cli")
        pkg.__path__ = []  # a package, so the submodules resolve
        settings = types.ModuleType("hermes_cli.web_server")
        settings._GATEWAY_HEALTH_URL = url
        settings._GATEWAY_HEALTH_TIMEOUT = timeout
        sys.modules["hermes_cli"] = pkg
        sys.modules["hermes_cli.web_server"] = settings
        return settings

    @staticmethod
    def _install_fake_gateway_module():
        module = types.ModuleType("hermes_cli.web_server_gateway")

        def _probe_gateway_health():
            return False, None

        module._probe_gateway_health = _probe_gateway_health
        sys.modules["hermes_cli.web_server_gateway"] = module
        return module


class ProbeTest(_ShimState):
    """The replacement probe: what upstream's does, plus the Bearer header."""

    def _run(self, url, key, responder):
        self._install_fake_settings(url)
        env = {k: v for k, v in os.environ.items() if k != shim.KEY_ENV}
        if key is not None:
            env[shim.KEY_ENV] = key
        seen = []

        def urlopen(req, timeout=None):
            seen.append((req.full_url, req.get_method(), dict(req.header_items()), timeout))
            return responder(req.full_url)

        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(shim.urllib.request, "urlopen", urlopen):
            result = shim._probe_gateway_health()
        return result, seen

    def test_detailed_leg_carries_the_bearer_key_and_its_body_is_returned(self):
        detailed = {"status": "ok", "readiness": {"state_db": "ok"}, "gateway_state": "running"}
        result, seen = self._run("http://ci-hermes-gateway:8642", KEY,
                                 lambda url: _fake_response(detailed))
        self.assertEqual(result, (True, detailed))
        self.assertEqual(len(seen), 1, "the detailed leg answered; no fallback request")
        url, method, headers, timeout = seen[0]
        self.assertEqual(url, "http://ci-hermes-gateway:8642/health/detailed")
        self.assertEqual(method, "GET")
        self.assertEqual(headers.get("Authorization"), f"Bearer {KEY}")
        self.assertEqual(timeout, 1.0)

    def test_falls_back_to_plain_health_when_detailed_fails(self):
        def responder(url):
            if url.endswith("/health/detailed"):
                raise _http_error(url, 401)
            return _fake_response({"status": "ok", "platform": "hermes-agent"})

        result, seen = self._run("http://gw:8642", KEY, responder)
        self.assertEqual(result, (True, {"status": "ok", "platform": "hermes-agent"}))
        self.assertEqual([s[0] for s in seen], ["http://gw:8642/health/detailed", "http://gw:8642/health"])
        # The key travels on both legs: /health ignores it, and one header rule is
        # simpler than two.
        self.assertTrue(all(s[2].get("Authorization") == f"Bearer {KEY}" for s in seen))

    def test_explicit_health_paths_normalise_to_the_base(self):
        for configured in ("http://gw:8642/health", "http://gw:8642/health/detailed", "http://gw:8642/"):
            with self.subTest(configured=configured):
                _, seen = self._run(configured, KEY, lambda url: _fake_response({"status": "ok"}))
                self.assertEqual(seen[0][0], "http://gw:8642/health/detailed")

    def test_no_key_sends_no_authorization_header(self):
        _, seen = self._run("http://gw:8642", None, lambda url: _fake_response({"status": "ok"}))
        self.assertNotIn("Authorization", seen[0][2])
        _, seen = self._run("http://gw:8642", "   ", lambda url: _fake_response({"status": "ok"}))
        self.assertNotIn("Authorization", seen[0][2])

    def test_no_url_probes_nothing(self):
        result, seen = self._run("", KEY, lambda url: self.fail("must not be called"))
        self.assertEqual(result, (False, None))
        self.assertEqual(seen, [])

    def test_every_failure_is_silent(self):
        def responder(url):
            raise ConnectionRefusedError(url)

        result, seen = self._run("http://gw:8642", KEY, responder)
        self.assertEqual(result, (False, None))
        self.assertEqual(len(seen), 2)

    def test_non_200_is_not_success(self):
        result, _ = self._run("http://gw:8642", KEY, lambda url: _fake_response({"x": 1}, status=503))
        self.assertEqual(result, (False, None))


class InstallGatingTest(_ShimState):
    """The shim only engages in a process that both probes over HTTP and holds the key."""

    def _env(self, **overrides):
        env = {k: v for k, v in os.environ.items() if k not in (shim.KEY_ENV, shim.URL_ENV)}
        env.update(overrides)
        return mock.patch.dict(os.environ, env, clear=True)

    def _finder_installed(self):
        return any(isinstance(f, shim._PostImportPatcher) for f in sys.meta_path)

    def test_disabled_without_the_key_or_the_url(self):
        for env in ({}, {shim.KEY_ENV: KEY}, {shim.URL_ENV: "http://gw:8642"},
                    {shim.KEY_ENV: "", shim.URL_ENV: "http://gw:8642"}):
            with self.subTest(env=env), self._env(**env):
                self._reset()
                self.assertFalse(shim.enabled())
                shim.install()
                self.assertFalse(self._finder_installed())

    def test_enabled_with_both(self):
        with self._env(**{shim.KEY_ENV: KEY, shim.URL_ENV: "http://gw:8642"}):
            self.assertTrue(shim.enabled())
            shim.install()
            self.assertTrue(self._finder_installed())
            shim.install()
            self.assertEqual(sum(isinstance(f, shim._PostImportPatcher) for f in sys.meta_path), 1,
                             "install() is idempotent")

    def test_already_imported_module_is_patched_at_install(self):
        module = self._install_fake_gateway_module()
        original = module._probe_gateway_health
        with self._env(**{shim.KEY_ENV: KEY, shim.URL_ENV: "http://gw:8642"}):
            shim.install()
        self.assertIs(module._probe_gateway_health, shim._probe_gateway_health)
        self.assertIs(shim._probe_gateway_health._ci_health_auth_original, original)
        # Re-applying is a no-op: the replacement is recognised by its marker.
        shim._patch_gateway_module(module)
        self.assertIs(module._probe_gateway_health, shim._probe_gateway_health)

    def test_missing_target_leaves_the_module_alone(self):
        module = types.ModuleType("hermes_cli.web_server_gateway")
        with self.assertLogs(shim.logger, level="WARNING") as logs:
            shim._patch_gateway_module(module)
        self.assertFalse(hasattr(module, "_probe_gateway_health"))
        self.assertIn("not found", logs.output[0])


class DeferredPatchTest(_ShimState):
    """The meta-path finder patches the real module right after it is imported."""

    def setUp(self):
        super().setUp()
        self._tmp = tempfile.TemporaryDirectory()
        pkg = Path(self._tmp.name) / "hermes_cli"
        pkg.mkdir()
        (pkg / "__init__.py").write_text("")
        (pkg / "web_server.py").write_text(textwrap.dedent("""\
            _GATEWAY_HEALTH_URL = "http://gw:8642"
            _GATEWAY_HEALTH_TIMEOUT = 0.5
            """))
        (pkg / "web_server_gateway.py").write_text(textwrap.dedent("""\
            def _probe_gateway_health():
                return False, None

            def other():
                return "untouched"
            """))
        sys.path.insert(0, self._tmp.name)

    def tearDown(self):
        sys.path.remove(self._tmp.name)
        self._tmp.cleanup()
        super().tearDown()

    def test_import_after_install_is_patched(self):
        with mock.patch.dict(os.environ, {shim.KEY_ENV: KEY, shim.URL_ENV: "http://gw:8642"}):
            shim.install()
            import hermes_cli.web_server_gateway as gw  # noqa: E402
        self.assertIs(gw._probe_gateway_health, shim._probe_gateway_health)
        self.assertEqual(gw.other(), "untouched")
        self.assertIn("hermes_cli.web_server_gateway", shim._patched)

        # And the patched module's probe really does send the key, end to end.
        seen = []

        def urlopen(req, timeout=None):
            seen.append((req.full_url, dict(req.header_items()), timeout))
            return _fake_response({"status": "ok", "gateway_state": "running"})

        with mock.patch.dict(os.environ, {shim.KEY_ENV: KEY}), \
                mock.patch.object(shim.urllib.request, "urlopen", urlopen):
            self.assertEqual(gw._probe_gateway_health(), (True, {"status": "ok", "gateway_state": "running"}))
        self.assertEqual(seen, [("http://gw:8642/health/detailed", {"Authorization": f"Bearer {KEY}"}, 0.5)])

    def test_import_without_install_is_untouched(self):
        import hermes_cli.web_server_gateway as gw  # noqa: E402
        self.assertIsNot(gw._probe_gateway_health, shim._probe_gateway_health)
        self.assertEqual(gw._probe_gateway_health(), (False, None))


class ContractCheckTest(unittest.TestCase):
    """The static contract check against a minimal fake upstream tree."""

    PROBE = textwrap.dedent("""\
        import urllib.request

        def _probe_gateway_health() -> tuple[bool, dict | None]:
            from hermes_cli.web_server import _GATEWAY_HEALTH_TIMEOUT, _GATEWAY_HEALTH_URL
            return False, None
        """)
    SETTINGS = textwrap.dedent("""\
        import os
        _GATEWAY_HEALTH_URL = os.getenv("GATEWAY_HEALTH_URL")
        try:
            _GATEWAY_HEALTH_TIMEOUT = float(os.getenv("GATEWAY_HEALTH_TIMEOUT", "1"))
        except (ValueError, TypeError):
            _GATEWAY_HEALTH_TIMEOUT = 1.0
        """)
    API_SERVER = textwrap.dedent("""\
        class APIServerAdapter:
            def __init__(self):
                self._api_key = get_scoped_secret("API_SERVER_KEY", "")

            def _check_auth(self, request):
                auth_header = request.headers.get("Authorization", "")
                if auth_header.startswith("Bearer "):
                    return None
                return 401

            def _http_route_table(self):
                return [("GET", "/health", None), ("GET", "/health/detailed", None)]
        """)

    def _tree(self, probe=PROBE, settings=SETTINGS, api_server=API_SERVER):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / "hermes_cli").mkdir()
        (root / "gateway" / "platforms").mkdir(parents=True)
        (root / "hermes_cli" / "web_server_gateway.py").write_text(probe)
        (root / "hermes_cli" / "web_server.py").write_text(settings)
        (root / "gateway" / "platforms" / "api_server.py").write_text(api_server)
        return root

    def test_holds_on_the_expected_shape(self):
        self.assertEqual(contract.check(self._tree()), [])
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            self.assertEqual(contract.main(["--root", str(self._tree())]), 0)
        self.assertIn("present in", out.getvalue())

    def test_renamed_probe_is_drift(self):
        problems = contract.check(self._tree(probe=self.PROBE.replace("_probe_gateway_health", "_probe_gw")))
        self.assertEqual(len(problems), 1)
        self.assertIn("`_probe_gateway_health` is no longer bound", problems[0])

    def test_probe_growing_a_required_parameter_is_drift(self):
        problems = contract.check(self._tree(probe=self.PROBE.replace("_probe_gateway_health()",
                                                                       "_probe_gateway_health(url)")))
        self.assertEqual(len(problems), 1)
        self.assertIn("now takes parameters (url)", problems[0])

    def test_probe_growing_an_optional_parameter_is_fine(self):
        problems = contract.check(self._tree(probe=self.PROBE.replace("_probe_gateway_health()",
                                                                       "_probe_gateway_health(url=None)")))
        self.assertEqual(problems, [])

    def test_missing_setting_is_drift(self):
        problems = contract.check(self._tree(settings=self.SETTINGS.replace("_GATEWAY_HEALTH_URL", "_GW_URL")))
        self.assertEqual(problems, [f"{contract.SETTINGS_MODULE}: `_GATEWAY_HEALTH_URL` is no longer bound at module level"])

    def test_api_server_dropping_bearer_or_the_route_is_drift(self):
        problems = contract.check(self._tree(api_server=self.API_SERVER.replace('"Bearer "', '"Token "')))
        self.assertEqual(problems, [f"{contract.API_SERVER_MODULE}: literal 'Bearer ' no longer appears"])
        problems = contract.check(self._tree(api_server=self.API_SERVER.replace("/health/detailed", "/health/full")))
        self.assertEqual(problems, [f"{contract.API_SERVER_MODULE}: literal '/health/detailed' no longer appears"])
        problems = contract.check(self._tree(api_server=self.API_SERVER.replace("_check_auth", "_authorize")))
        self.assertEqual(problems, [f"{contract.API_SERVER_MODULE}: `_check_auth` not found"])

    def test_missing_file_is_drift_and_exit_1(self):
        root = self._tree()
        (root / "hermes_cli" / "web_server_gateway.py").unlink()
        problems = contract.check(root)
        self.assertEqual(problems, [f"{contract.PROBE_MODULE}: file missing"])
        with mock.patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(contract.main(["--root", str(root)]), 1)


if __name__ == "__main__":
    unittest.main()
