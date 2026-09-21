"""Send the gateway's API key with the dashboard's health probe — CI-Hermes build-time shim.

Loaded at interpreter startup via `ci-gateway-health-auth.pth`. It installs a deferred
post-import patcher (same mechanism as enable_ollama_native.py) that replaces
``hermes_cli.web_server_gateway._probe_gateway_health`` with a copy that sends
``Authorization: Bearer $API_SERVER_KEY``.

Why: with the dashboard and the gateway in separate containers, upstream's dashboard
probes the gateway over HTTP (``GATEWAY_HEALTH_URL``) instead of by PID. The probe tries
``/health/detailed`` first and falls back to ``/health`` — but it sends no credentials,
and ``/health/detailed`` is Bearer-authenticated (the API server refuses to bind to
0.0.0.0 without a key). So every ``/api/status`` poll (~10 s while the UI is open) 401s
on the first leg, the gateway logs ``API server rejected invalid API key``, and the
dashboard settles for the bare ``/health`` body — no readiness, platforms or state.
Upstream marks the env-driven probe DEPRECATED (v0.21.x) and has not fixed it.

The key is read from ``API_SERVER_KEY`` in this process's environment — the same
variable the gateway validates against — so the compose has to pass it to the web
container as well as the gateway (docker-compose.yml here; the marketplace manifest
for an appliance install). Without it, or without ``GATEWAY_HEALTH_URL``, install()
does nothing and the stock probe runs.

Everything is wrapped in try/except and degrades to stock behaviour on any error, so
a bad patch can never crash the dashboard — it just goes back to the unauthenticated
probe. check_gateway_health_auth_contract.py turns a silent upstream rename into a
build failure.
"""

from __future__ import annotations

import json
import logging
import os
import re
import sys
import threading
import urllib.request

logger = logging.getLogger("ci.gateway_health_auth.shim")

KEY_ENV = "API_SERVER_KEY"
URL_ENV = "GATEWAY_HEALTH_URL"
TARGET_MODULE = "hermes_cli.web_server_gateway"
TARGET_NAME = "_probe_gateway_health"

# Serializes the meta-path finder's self-removal during spec resolution so two
# concurrent target imports can't lose a hook or corrupt sys.meta_path.
_META_PATH_LOCK = threading.Lock()


def gateway_api_key() -> str:
    """The key the gateway's API server validates: ``API_SERVER_KEY`` from the process
    env (upstream's own resolution for a single-profile install). Empty when unset."""
    return (os.environ.get(KEY_ENV) or "").strip()


def auth_headers() -> dict:
    key = gateway_api_key()
    return {"Authorization": f"Bearer {key}"} if key else {}


def _probe_gateway_health() -> tuple:
    """Upstream ``_probe_gateway_health`` (hermes_cli/web_server_gateway.py, v0.21.x) with
    one change: the request carries the Bearer key. Same URL normalisation, same
    ``/health/detailed`` → ``/health`` ladder, same ``(ok, body)`` return, same silence on
    any failure, and the timeout/URL still come from ``hermes_cli.web_server`` so
    ``GATEWAY_HEALTH_TIMEOUT`` and the test seams there keep working."""
    from hermes_cli.web_server import _GATEWAY_HEALTH_TIMEOUT, _GATEWAY_HEALTH_URL

    if not _GATEWAY_HEALTH_URL:
        return False, None
    base = re.sub(r"/health(/detailed)?$", "", _GATEWAY_HEALTH_URL.rstrip("/"))
    headers = auth_headers()
    for path in (f"{base}/health/detailed", f"{base}/health"):
        try:
            req = urllib.request.Request(path, method="GET", headers=headers)
            with urllib.request.urlopen(req, timeout=_GATEWAY_HEALTH_TIMEOUT) as resp:
                if resp.status == 200:
                    return True, json.loads(resp.read())
        except Exception:
            continue
    return False, None


_probe_gateway_health._ci_health_auth_wrapped = True  # type: ignore[attr-defined]


def _patch_gateway_module(module) -> None:
    """Swap the module-level probe. Callers bind it late (``web_deps.late`` resolves the
    attribute on every call), so the swap takes effect whether or not the routers were
    imported first. The original is kept on the replacement for tests and diagnosis."""
    orig = getattr(module, TARGET_NAME, None)
    if orig is None:
        logger.warning("CI gateway-health-auth: %s.%s not found; probe stays unauthenticated",
                       TARGET_MODULE, TARGET_NAME)
        return
    if getattr(orig, "_ci_health_auth_wrapped", False):
        return
    _probe_gateway_health._ci_health_auth_original = orig  # type: ignore[attr-defined]
    setattr(module, TARGET_NAME, _probe_gateway_health)
    logger.info("CI gateway-health-auth: %s.%s sends Bearer %s", TARGET_MODULE, TARGET_NAME, KEY_ENV)


_TARGETS = {TARGET_MODULE: _patch_gateway_module}
_patched: set = set()


def _apply(name: str, module) -> None:
    if name in _patched:
        return
    try:
        _TARGETS[name](module)
        _patched.add(name)
    except Exception as exc:  # never let a patch failure break startup
        logger.warning("CI gateway-health-auth: patch for %s failed: %s", name, exc)
        _patched.add(name)  # don't retry on every import


class _PostImportPatcher:
    """A meta-path finder that patches the target module right after it loads.

    Deferring to natural import time avoids importing the dashboard during site
    initialization (when this shim runs) — and in processes that never import it
    (the gateway, the agent's terminal sessions) nothing happens at all.
    """

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
            # A loader that forbids attribute assignment: let the module import
            # normally, just unpatched.
            return None
        return spec


def enabled() -> bool:
    """Only a process that both probes over HTTP and holds the key has anything to fix."""
    return bool(gateway_api_key()) and bool((os.environ.get(URL_ENV) or "").strip())


def install() -> None:
    if not enabled():
        return
    for name, module in list(sys.modules.items()):
        if name in _TARGETS and module is not None:
            _apply(name, module)
    if not any(isinstance(f, _PostImportPatcher) for f in sys.meta_path):
        sys.meta_path.insert(0, _PostImportPatcher())
    logger.info("CI gateway-health-auth: post-import patcher installed")


try:
    install()
except Exception as exc:  # absolutely never break interpreter startup
    logging.getLogger("ci.gateway_health_auth.shim").warning(
        "CI gateway-health-auth: install() failed: %s", exc)
