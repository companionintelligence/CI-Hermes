"""Unit tests for enable_gateway_lock_guard: stdlib unittest, no dependencies.

Run from this directory:  python3 -m unittest discover -p '*_test.py' --verbose

Upstream's ``gateway.status`` is not importable here, so the tests use a small fake module
with the same names and a real ``fcntl.flock`` held by a child process, the way the gateway
in its own container holds it. The Docker build runs the static contract check against the
real tree.
"""

from __future__ import annotations

import fcntl
import os
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import check_gateway_lock_guard_contract as contract  # noqa: E402
import enable_gateway_lock_guard as shim  # noqa: E402


def _fake_status(home: Path):
    """A stand-in for gateway.status: upstream's cleanup and lock probe, reduced to the behaviour
    the wrapper depends on."""
    mod = types.ModuleType("gateway.status")
    mod.cache_clears = 0

    def _get_gateway_lock_path(pid_path=None):
        return (pid_path or home / "gateway.pid").with_name("gateway.lock")

    def is_gateway_runtime_lock_active(lock_path=None):
        lock_path = lock_path or _get_gateway_lock_path()
        if not lock_path.exists():
            return False
        with open(lock_path, "a+") as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return True
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            return False

    def _clear_running_pid_cache():
        mod.cache_clears += 1

    def _cleanup_invalid_pid_path(pid_path, *, cleanup_stale):
        if not cleanup_stale:
            return
        _clear_running_pid_cache()
        for path in (pid_path, _get_gateway_lock_path(pid_path)):
            path.unlink(missing_ok=True)

    mod._get_gateway_lock_path = _get_gateway_lock_path
    mod.is_gateway_runtime_lock_active = is_gateway_runtime_lock_active
    mod._clear_running_pid_cache = _clear_running_pid_cache
    mod._cleanup_invalid_pid_path = _cleanup_invalid_pid_path
    return mod


class _HeldLock:
    """A child process that holds an exclusive flock on the file, like the gateway does."""

    def __init__(self, path: Path):
        self.path = path

    def __enter__(self):
        code = textwrap.dedent(f"""
            import fcntl, sys
            h = open({str(self.path)!r}, "a+")
            fcntl.flock(h.fileno(), fcntl.LOCK_EX)
            print("held", flush=True)
            sys.stdin.read()
        """)
        self.proc = subprocess.Popen([sys.executable, "-c", code], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        # Not an assert: ``python -O`` would strip the readline and the test would race the child.
        if self.proc.stdout.readline().strip() != "held":
            self.__exit__()
            raise RuntimeError("lock-holding child did not take the lock")
        return self

    def __exit__(self, *exc):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)
        self.proc.stdout.close()


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.pid = self.home / "gateway.pid"
        self.lock = self.home / "gateway.lock"
        self.pid.write_text('{"pid": 1}')
        self.lock.write_text('{"pid": 1}')
        self.mod = _fake_status(self.home)
        shim._patched.discard(shim.TARGET_MODULE)
        shim._apply(shim.TARGET_MODULE, self.mod)

    def tearDown(self):
        shim._patched.discard(shim.TARGET_MODULE)
        self.tmp.cleanup()

    def test_keeps_files_while_another_process_holds_the_lock(self):
        with _HeldLock(self.lock):
            self.mod._cleanup_invalid_pid_path(self.pid, cleanup_stale=True)
            self.assertTrue(self.pid.exists())
            self.assertTrue(self.lock.exists())
            self.assertTrue(self.mod.is_gateway_runtime_lock_active(self.lock))
        self.assertEqual(self.mod.cache_clears, 0, "nothing changed on disk, so the cache stays")

    def test_still_removes_stale_files_once_the_lock_is_free(self):
        self.mod._cleanup_invalid_pid_path(self.pid, cleanup_stale=True)
        self.assertFalse(self.pid.exists())
        self.assertFalse(self.lock.exists())

    def test_cleanup_stale_false_is_left_to_upstream(self):
        with _HeldLock(self.lock):
            self.mod._cleanup_invalid_pid_path(self.pid, cleanup_stale=False)
        self.assertTrue(self.pid.exists())
        self.assertEqual(self.mod.cache_clears, 0)

    def test_a_failing_probe_falls_back_to_upstream_and_warns_once(self):
        self.mod.is_gateway_runtime_lock_active = mock.Mock(side_effect=RuntimeError("boom"))
        with mock.patch.object(shim, "_probe_failure_reported", False), \
                self.assertLogs(shim.logger, level="DEBUG") as logs:
            self.mod._cleanup_invalid_pid_path(self.pid, cleanup_stale=True)
            self.mod._cleanup_invalid_pid_path(self.pid, cleanup_stale=True)
        self.assertFalse(self.pid.exists())
        self.assertEqual([r.levelname for r in logs.records], ["WARNING", "DEBUG"])

    def test_wraps_once(self):
        wrapped = self.mod._cleanup_invalid_pid_path
        shim._patched.discard(shim.TARGET_MODULE)
        shim._apply(shim.TARGET_MODULE, self.mod)
        self.assertIs(self.mod._cleanup_invalid_pid_path, wrapped)
        self.assertTrue(getattr(wrapped, "_ci_gateway_lock_guard", False))


class EnabledTest(unittest.TestCase):
    def test_only_where_the_gateway_is_reached_over_http(self):
        with mock.patch.dict(os.environ, {"GATEWAY_HEALTH_URL": "http://ci-hermes-gateway:8642"}):
            self.assertTrue(shim.enabled())
        with mock.patch.dict(os.environ, {"GATEWAY_HEALTH_URL": "  "}):
            self.assertFalse(shim.enabled())
        env = {k: v for k, v in os.environ.items() if k != "GATEWAY_HEALTH_URL"}
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertFalse(shim.enabled())


class InstallTest(unittest.TestCase):
    """The path the image runs: the .pth calls install() and a later ``import gateway.status``
    goes through the meta-path finder, which wraps the freshly loaded module."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / "gateway").mkdir()
        (root / "gateway" / "__init__.py").write_text("")
        (root / "gateway" / "status.py").write_text(textwrap.dedent("""
            def _get_gateway_lock_path(pid_path=None): return pid_path.with_name("gateway.lock")
            def is_gateway_runtime_lock_active(lock_path=None): return True
            def _cleanup_invalid_pid_path(pid_path, *, cleanup_stale): raise AssertionError("unlinked")
        """))
        saved_modules = {name: sys.modules.pop(name) for name in ("gateway", "gateway.status") if name in sys.modules}
        saved_meta_path = list(sys.meta_path)
        sys.path.insert(0, str(root))
        shim._patched.discard(shim.TARGET_MODULE)

        def restore():
            sys.path.remove(str(root))
            sys.meta_path[:] = saved_meta_path
            for name in ("gateway", "gateway.status"):
                sys.modules.pop(name, None)
            sys.modules.update(saved_modules)
            shim._patched.discard(shim.TARGET_MODULE)
        self.addCleanup(restore)

    def test_import_after_install_is_wrapped(self):
        with mock.patch.dict(os.environ, {shim.URL_ENV: "http://ci-hermes-gateway:8642"}):
            shim.install()
        import gateway.status as status  # noqa: E402

        self.assertTrue(getattr(status._cleanup_invalid_pid_path, "_ci_gateway_lock_guard", False))
        status._cleanup_invalid_pid_path(Path("/nonexistent/gateway.pid"), cleanup_stale=True)

    def test_without_the_url_nothing_is_installed(self):
        env = {k: v for k, v in os.environ.items() if k != shim.URL_ENV}
        with mock.patch.dict(os.environ, env, clear=True):
            shim.install()
        self.assertFalse(any(isinstance(f, shim._PostImportPatcher) for f in sys.meta_path))
        import gateway.status as status  # noqa: E402

        self.assertFalse(getattr(status._cleanup_invalid_pid_path, "_ci_gateway_lock_guard", False))


class ContractTest(unittest.TestCase):
    STATUS = textwrap.dedent("""
        def _get_gateway_lock_path(pid_path=None): ...
        def is_gateway_runtime_lock_active(lock_path=None): ...
        def _clear_running_pid_cache(): ...
        def _cleanup_invalid_pid_path(pid_path, *, cleanup_stale): ...
        def get_running_pid(pid_path=None, *, cleanup_stale=True):
            _cleanup_invalid_pid_path(pid_path, cleanup_stale=cleanup_stale)
    """)
    CRON = textwrap.dedent("""
        def _builtin_gateway_liveness():
            from gateway.status import is_gateway_runtime_lock_active
            return is_gateway_runtime_lock_active()
    """)

    def _tree(self, status=STATUS, cron=CRON):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / "gateway").mkdir()
        (root / "hermes_cli").mkdir()
        (root / "gateway" / "status.py").write_text(status)
        (root / "hermes_cli" / "cron.py").write_text(cron)
        return root

    def test_holds_on_the_expected_tree(self):
        self.assertEqual(contract.check(self._tree()), [])

    def test_reports_a_renamed_target(self):
        problems = contract.check(self._tree(status=self.STATUS.replace("_cleanup_invalid_pid_path", "_cleanup_pid")))
        self.assertTrue(any("_cleanup_invalid_pid_path" in p for p in problems), problems)

    def test_reports_a_changed_signature(self):
        status = self.STATUS.replace("def _cleanup_invalid_pid_path(pid_path, *, cleanup_stale)",
                                     "def _cleanup_invalid_pid_path(pid_path, cleanup_stale)")
        problems = contract.check(self._tree(status=status))
        self.assertTrue(any("signature" in p for p in problems), problems)

    def test_reports_a_caller_that_stopped_calling_it(self):
        status = self.STATUS.replace("    _cleanup_invalid_pid_path(pid_path, cleanup_stale=cleanup_stale)", "    return None")
        problems = contract.check(self._tree(status=status))
        self.assertTrue(any("no longer calls" in p for p in problems), problems)

    def test_reports_a_caller_that_calls_it_through_an_attribute(self):
        status = self.STATUS.replace("    _cleanup_invalid_pid_path(pid_path", "    helpers._cleanup_invalid_pid_path(pid_path")
        problems = contract.check(self._tree(status=status))
        self.assertTrue(any("by bare name" in p for p in problems), problems)

    def test_reports_a_missing_helper(self):
        problems = contract.check(self._tree(status=self.STATUS.replace("def is_gateway_runtime_lock_active",
                                                                        "def is_lock_active")))
        self.assertTrue(any("is_gateway_runtime_lock_active" in p for p in problems), problems)

    def test_reports_a_helper_that_lost_its_parameter(self):
        status = self.STATUS.replace("def _get_gateway_lock_path(pid_path=None)", "def _get_gateway_lock_path()")
        problems = contract.check(self._tree(status=status))
        self.assertTrue(any("_get_gateway_lock_path` signature changed" in p for p in problems), problems)

    def test_reports_a_helper_that_grew_a_required_parameter(self):
        status = self.STATUS.replace("def is_gateway_runtime_lock_active(lock_path=None)",
                                     "def is_gateway_runtime_lock_active(lock_path, *, strict)")
        problems = contract.check(self._tree(status=status))
        self.assertTrue(any("is_gateway_runtime_lock_active` signature changed" in p for p in problems), problems)

    def test_reports_cron_liveness_without_the_lock_probe(self):
        problems = contract.check(self._tree(cron="def _builtin_gateway_liveness():\n    return None\n"))
        self.assertTrue(any("_builtin_gateway_liveness" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
