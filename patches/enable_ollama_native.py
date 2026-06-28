"""Wire OllamaNativeClient into Hermes Agent — CI-Hermes build-time shim.

Loaded at interpreter startup via `ci-ollama-native.pth`. It installs a deferred
post-import patcher so the agent's client-construction chokepoints route local
Ollama through the native `/api/chat` adapter (which honors `num_ctx`) instead of
the OpenAI-compat `/v1` endpoint (which silently drops it).

Hooks (see specs/ci/ci-hermes-ollama-native-api-plan.md §11):
  * Hook 1 (always, when CI_HERMES_OLLAMA_NATIVE on): the single chat chokepoint
    `agent.agent_runtime_helpers.create_openai_client` — covers the primary client
    AND the per-request sync + stream clients.
  * Hook 2 (phase 2, on by default with the main flag; set CI_HERMES_OLLAMA_NATIVE_AUX=0
    to disable): the auxiliary side-task routers `resolve_provider_client` (compression,
    title, web-extract, …) and `resolve_vision_provider_client` (vision) in
    `agent.auxiliary_client`. We wrap the ROUTERS and post-swap the returned client —
    we deliberately do NOT touch the `OpenAI` symbol (it's used in isinstance checks).
    Safe by construction: Gemini native clients already flow through these routers, so
    the aux consumers already handle non-OpenAI native clients.

Everything is wrapped in try/except and degrades to stock behavior on any error,
so a bad patch can never crash agent startup — it just reverts to /v1.
"""

from __future__ import annotations

import logging
import os
import sys

logger = logging.getLogger("ci.ollama_native.shim")

_FLAG = "CI_HERMES_OLLAMA_NATIVE"
_FLAG_AUX = "CI_HERMES_OLLAMA_NATIVE_AUX"


def _truthy(name: str) -> bool:
    return str(os.environ.get(name, "")).strip().lower() in ("1", "true", "yes", "on")


def _patch_runtime(module) -> None:
    """Hook 1 — wrap create_openai_client to return OllamaNativeClient for native Ollama."""
    orig = getattr(module, "create_openai_client", None)
    if orig is None or getattr(orig, "_ci_ollama_wrapped", False):
        return
    from ollama_native_adapter import OllamaNativeClient, is_native_ollama_base_url

    # Signature-flexible: forward *args/**kwargs verbatim so an upstream change to
    # create_openai_client's params can't break the wrapper (it'd just pass through).
    def wrapped(agent, client_kwargs, *args, **kwargs):
        try:
            base_url = str((client_kwargs or {}).get("base_url", "") or "")
            if base_url and is_native_ollama_base_url(base_url):
                safe = {
                    k: v
                    for k, v in client_kwargs.items()
                    if k in {"api_key", "base_url", "default_headers", "timeout", "http_client"}
                }
                logger.info(
                    "CI ollama-native: chat client via /api/chat (reason=%s, base=%s)",
                    kwargs.get("reason"), base_url,
                )
                return OllamaNativeClient(**safe)
        except Exception as exc:
            logger.warning("CI ollama-native Hook 1 failed; falling back to /v1: %s", exc)
        return orig(agent, client_kwargs, *args, **kwargs)

    wrapped._ci_ollama_wrapped = True  # type: ignore[attr-defined]
    module.create_openai_client = wrapped
    logger.info("CI ollama-native: Hook 1 installed (create_openai_client)")


def _aux_enabled() -> bool:
    """Hook 2 (aux side-tasks) is ON by default with the main flag; set
    CI_HERMES_OLLAMA_NATIVE_AUX=0 to disable just the aux coverage."""
    v = os.environ.get(_FLAG_AUX)
    if v is None:
        return True
    return str(v).strip().lower() in ("1", "true", "yes", "on")


def _native_swap(client):
    """Return an Ollama-native client mirroring `client` when it targets native
    Ollama (sync→OllamaNativeClient, async→AsyncOllamaNativeClient); else None.

    Non-Ollama clients (cloud OpenAI, Gemini/Codex/Anthropic native wrappers) have
    a non-Ollama base_url, so the /api/version probe fails and we return None —
    leaving them untouched.
    """
    from ollama_native_adapter import (
        AsyncOllamaNativeClient,
        OllamaNativeClient,
        is_native_ollama_base_url,
    )

    if client is None:
        return None
    try:
        base = str(getattr(client, "base_url", "") or "")
    except Exception:
        base = ""
    if not base or not is_native_ollama_base_url(base):
        return None
    api_key = getattr(client, "api_key", None)
    if not isinstance(api_key, str) or not api_key:
        api_key = "ollama"
    is_async = False
    try:
        import openai
        is_async = isinstance(client, openai.AsyncOpenAI)
    except Exception:
        is_async = "Async" in type(client).__name__
    sync = OllamaNativeClient(base_url=base, api_key=api_key)
    return AsyncOllamaNativeClient(sync) if is_async else sync


def _patch_aux(module) -> None:
    """Hook 2 — route auxiliary side-tasks (compression/title/vision) through native
    Ollama by wrapping the resolver functions and post-swapping the returned client.

    We wrap the routers (not the isinstance-checked `OpenAI` symbol), so existing
    isinstance(x, OpenAI) checks inside the resolvers run on the real client during
    construction; the swap happens only at the boundary, mirroring how Gemini native
    clients already traverse this path.
    """
    if not _aux_enabled():
        return

    def _wrap_text(orig):
        if getattr(orig, "_ci_ollama_wrapped", False):
            return orig

        def wrapped(*a, **k):
            client, model = orig(*a, **k)
            try:
                native = _native_swap(client)
                if native is not None:
                    logger.info("CI ollama-native: aux text client via /api/chat")
                    return native, model
            except Exception as exc:
                logger.warning("CI ollama-native Hook 2 (text) failed; using original: %s", exc)
            return client, model

        wrapped._ci_ollama_wrapped = True  # type: ignore[attr-defined]
        return wrapped

    def _wrap_vision(orig):
        if getattr(orig, "_ci_ollama_wrapped", False):
            return orig

        def wrapped(*a, **k):
            provider, client, model = orig(*a, **k)
            try:
                native = _native_swap(client)
                if native is not None:
                    logger.info("CI ollama-native: aux vision client via /api/chat")
                    return provider, native, model
            except Exception as exc:
                logger.warning("CI ollama-native Hook 2 (vision) failed; using original: %s", exc)
            return provider, client, model

        wrapped._ci_ollama_wrapped = True  # type: ignore[attr-defined]
        return wrapped

    for fname, wrapper in (("resolve_provider_client", _wrap_text),
                           ("resolve_vision_provider_client", _wrap_vision)):
        orig = getattr(module, fname, None)
        if orig is not None and not getattr(orig, "_ci_ollama_wrapped", False):
            setattr(module, fname, wrapper(orig))
            logger.info("CI ollama-native: Hook 2 installed (%s)", fname)


_TARGETS = {
    "agent.agent_runtime_helpers": _patch_runtime,
    "agent.auxiliary_client": _patch_aux,
}
_patched: set = set()


def _apply(name: str, module) -> None:
    if name in _patched:
        return
    try:
        _TARGETS[name](module)
        _patched.add(name)
    except Exception as exc:  # never let a patch failure break startup
        logger.warning("CI ollama-native: patch for %s failed: %s", name, exc)
        _patched.add(name)  # don't retry on every import


class _PostImportPatcher:
    """A meta-path finder that patches our target modules right after they load.

    Deferring to natural import time avoids importing heavy agent modules during
    site initialization (when this shim runs).
    """

    def find_spec(self, fullname, path=None, target=None):
        if fullname not in _TARGETS or fullname in _patched:
            return None
        import importlib.util

        # Remove ourselves while resolving the real spec to avoid recursion.
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

        spec.loader.exec_module = exec_module  # type: ignore[assignment]
        return spec


def install() -> None:
    if not _truthy(_FLAG):
        return  # native mode disabled → leave the agent entirely on /v1
    # Patch any targets already imported (defensive — unlikely at .pth time).
    for name, module in list(sys.modules.items()):
        if name in _TARGETS and module is not None:
            _apply(name, module)
    # Defer the rest to import time.
    if not any(isinstance(f, _PostImportPatcher) for f in sys.meta_path):
        sys.meta_path.insert(0, _PostImportPatcher())
    logger.info("CI ollama-native: post-import patcher installed (flag on)")


try:
    install()
except Exception as exc:  # absolutely never break interpreter startup
    logging.getLogger("ci.ollama_native.shim").warning("CI ollama-native: install() failed: %s", exc)
