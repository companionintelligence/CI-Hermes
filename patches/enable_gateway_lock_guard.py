"""Keep the web container from deleting the live gateway's lock (a CI-Hermes build-time shim).

Loaded at interpreter startup via `ci-gateway-lock-guard.pth`. It installs a deferred
post-import patcher (same mechanism as enable_gateway_health_auth.py) that wraps
``gateway.status._cleanup_invalid_pid_path`` so it leaves ``gateway.pid`` and
``gateway.lock`` alone while some process still holds the gateway's runtime lock.

Why: on CI-Hermes the gateway runs in its own container (``ci-hermes-gateway``) and the
dashboard, the web terminal and any ``hermes`` command typed there run in the web
container. Both share ``/opt/data``, so the web container sees the gateway's identity
files and can probe its flock, but not its process: the PID in the record belongs to the
gateway's PID namespace. Upstream's unscoped ``get_running_pid()`` (used by
``hermes cron run``, ``hermes cron status`` and the dashboard) finds the lock held, fails
to match the record against a live gateway in *this* namespace, and runs its
poison-file housekeeping: it unlinks both files. The gateway keeps running and keeps
firing jobs, holding a lock on a deleted file, but from then on every liveness check
in the web container answers "not running": ``hermes cron list`` warns "Gateway is not
running" and tells people to install a second gateway.

A file whose flock another process holds is never stale, wherever that process lives,
so the wrapper only declines that case. With the lock free (the gateway really stopped)
it calls upstream's cleanup unchanged.

It engages only in a process with ``GATEWAY_HEALTH_URL`` set: that is the web container,
the one place that reaches the gateway over HTTP because the gateway is elsewhere
(compose sets it there and nowhere else). In the gateway container nothing changes.

Everything is wrapped in try/except and degrades to stock behaviour on any error, so a
bad patch can never break ``hermes``. check_gateway_lock_guard_contract.py turns a
silent upstream rename into a build failure.
"""

from __future__ import annotations

import logging
import os
import sys
import threading

logger = logging.getLogger("ci.gateway_lock_guard.shim")

URL_ENV = "GATEWAY_HEALTH_URL"
TARGET_MODULE = "gateway.status"
TARGET_NAME = "_cleanup_invalid_pid_path"

_META_PATH_LOCK = threading.Lock()


def _make_guard(module, orig):
    def _cleanup_invalid_pid_path(pid_path, *, cleanup_stale):
        """Upstream's cleanup, except while the runtime lock is held: then the record names a
        gateway this process cannot see (another PID namespace), not a dead one."""
        try:
            if cleanup_stale and module.is_gateway_runtime_lock_active(module._get_gateway_lock_path(pid_path)):
                module._clear_running_pid_cache()
                return None
        except Exception as exc:  # unknown state: fall back to upstream's behaviour
            logger.debug("CI gateway-lock-guard: lock probe failed (%s); upstream cleanup runs", exc)
        return orig(pid_path, cleanup_stale=cleanup_stale)

    _cleanup_invalid_pid_path._ci_gateway_lock_guard = True  # type: ignore[attr-defined]
    _cleanup_invalid_pid_path._ci_gateway_lock_guard_original = orig  # type: ignore[attr-defined]
    return _cleanup_invalid_pid_path


def _patch_status_module(module) -> None:
    """Swap the module-level function. ``get_running_pid`` resolves it by global name on every
    call, so the swap takes effect for every caller in the process."""
    orig = getattr(module, TARGET_NAME, None)
    if orig is None:
        logger.warning("CI gateway-lock-guard: %s.%s not found; upstream cleanup stays as is",
                       TARGET_MODULE, TARGET_NAME)
        return
    if getattr(orig, "_ci_gateway_lock_guard", False):
        return
    setattr(module, TARGET_NAME, _make_guard(module, orig))
    logger.info("CI gateway-lock-guard: %s.%s keeps a held gateway lock", TARGET_MODULE, TARGET_NAME)


_TARGETS = {TARGET_MODULE: _patch_status_module}
_patched: set = set()


def _apply(name: str, module) -> None:
    if name in _patched:
        return
    try:
        _TARGETS[name](module)
        _patched.add(name)
    except Exception as exc:  # never let a patch failure break startup
        logger.warning("CI gateway-lock-guard: patch for %s failed: %s", name, exc)
        _patched.add(name)  # don't retry on every import


class _PostImportPatcher:
    """A meta-path finder that patches the target module right after it loads, so nothing is
    imported at site initialization and processes that never load it are untouched."""

    def find_spec(self, fullname, path=None, target=None):
        if fullname not in _TARGETS or fullname in _patched:
            return None
        import importlib.util

        with _META_PATH_LOCK:
            try:
                idx = sys.meta_path.index(self)
            except ValueError:
                return None
            sys.meta_path.pop(idx)
            try:
                spec = importlib.util.find_spec(fullname)
            except Exception:
                spec = None
            finally:
                sys.meta_path.insert(idx, self)

        if spec is None or spec.loader is None or not hasattr(spec.loader, "exec_module"):
            return None

        orig_exec = spec.loader.exec_module

        def exec_module(module, _orig=orig_exec, _name=fullname):
            _orig(module)
            _apply(_name, module)

        try:
            spec.loader.exec_module = exec_module  # type: ignore[assignment]
        except Exception:
            return None
        return spec


def enabled() -> bool:
    """Only the web container reaches the gateway over HTTP, because the gateway is elsewhere."""
    return bool((os.environ.get(URL_ENV) or "").strip())


def install() -> None:
    if not enabled():
        return
    for name, module in list(sys.modules.items()):
        if name in _TARGETS and module is not None:
            _apply(name, module)
    if not any(isinstance(f, _PostImportPatcher) for f in sys.meta_path):
        sys.meta_path.insert(0, _PostImportPatcher())
    logger.info("CI gateway-lock-guard: post-import patcher installed")


try:
    install()
except Exception as exc:  # absolutely never break interpreter startup
    logging.getLogger("ci.gateway_lock_guard.shim").warning(
        "CI gateway-lock-guard: install() failed: %s", exc)
