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
  * Hook 3 (with the main flag): `providers.get_provider_profile` — resolve a named
    custom instance ("custom:<name>") to the "custom" profile so per-request num_ctx
    is injected for it (the profile lookup is an exact match, so "custom:<name>"
    otherwise drops num_ctx on the legacy request-build path and the native client
    would run at Ollama's 4096 default).

Everything is wrapped in try/except and degrades to stock behavior on any error,
so a bad patch can never crash agent startup — it just reverts to /v1.
"""

from __future__ import annotations

import logging
import os
import sys
import threading

logger = logging.getLogger("ci.ollama_native.shim")

_FLAG = "CI_HERMES_OLLAMA_NATIVE"
_FLAG_AUX = "CI_HERMES_OLLAMA_NATIVE_AUX"

# Serializes the meta-path finder's self-removal during spec resolution so two
# concurrent target imports can't lose a hook or corrupt sys.meta_path.
_META_PATH_LOCK = threading.Lock()


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
            # Defensive: only inspect client_kwargs when it's actually a dict. If an
            # upstream change ever passes a non-dict here, skip native routing and
            # fall through to the original unchanged (no exception, no warning spam).
            if isinstance(client_kwargs, dict):
                base_url = str(client_kwargs.get("base_url", "") or "")
                # Give the probe the same auth material and TLS trust the real
                # client will use — an unauthenticated / default-trust probe would
                # 401 or SSLError behind an authenticated proxy or a private CA
                # and native routing would silently never engage. Resolve verify
                # unconditionally (like stock create_openai_client): the resolver
                # also honors the HERMES_CA_BUNDLE / SSL_CERT_FILE / *_CA_BUNDLE
                # env vars, which never appear in client_kwargs, and it only
                # warns when ssl_verify is explicitly disabled.
                verify = None
                if base_url:
                    try:
                        from agent.ssl_verify import resolve_httpx_verify

                        verify = resolve_httpx_verify(
                            ca_bundle=client_kwargs.get("ssl_ca_cert"),
                            ssl_verify=client_kwargs.get("ssl_verify"),
                            base_url=base_url,
                        )
                    except Exception:
                        verify = None
                if base_url and is_native_ollama_base_url(
                    base_url,
                    api_key=client_kwargs.get("api_key"),
                    default_headers=client_kwargs.get("default_headers"),
                    default_query=client_kwargs.get("default_query"),
                    verify=verify,
                ):
                    safe = {
                        k: v
                        for k, v in client_kwargs.items()
                        if k
                        in {
                            "api_key",
                            "base_url",
                            "default_headers",
                            "default_query",
                            "timeout",
                            "http_client",
                        }
                    }
                    # Mirror stock create_openai_client: give the native client the
                    # agent's keepalive http_client (TCP keepalives → dead-peer
                    # detection in ~60s) when we aren't already carrying one. Safe with
                    # the adapter's own per-request long read timeout, so the keepalive
                    # client's short default timeout can't shorten local-model calls.
                    if "http_client" not in safe:
                        try:
                            builder = getattr(agent, "_build_keepalive_http_client", None)
                            keepalive = None
                            if callable(builder):
                                # The REAL client must carry the same TLS trust
                                # the probe used — otherwise a private-CA endpoint
                                # passes the probe and then SSLErrors on every
                                # request. Detect older builder signatures by
                                # inspection instead of catching TypeError, which
                                # would also swallow a TypeError raised inside the
                                # builder and silently drop the custom trust.
                                import inspect

                                try:
                                    accepts_verify = (
                                        "verify" in inspect.signature(builder).parameters
                                    )
                                except (TypeError, ValueError):
                                    accepts_verify = False
                                keepalive = (
                                    builder(base_url, verify=verify)
                                    if (verify is not None and accepts_verify)
                                    else builder(base_url)
                                )
                            if keepalive is not None:
                                safe["http_client"] = keepalive
                        except Exception:
                            pass
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
    api_key = getattr(client, "api_key", None)
    if not isinstance(api_key, str) or not api_key:
        api_key = "ollama"
    probe_headers = getattr(client, "default_headers", None)
    if not isinstance(probe_headers, dict):
        probe_headers = None
    # The OpenAI SDK stores default_query privately as _custom_query — forward it
    # so URL-token auth reaches both the probe and every aux native request.
    probe_query = getattr(client, "_custom_query", None)
    if not isinstance(probe_query, dict):
        probe_query = None
    if not base or not is_native_ollama_base_url(
        base, api_key=api_key, default_headers=probe_headers, default_query=probe_query
    ):
        return None
    is_async = False
    try:
        import openai
        is_async = isinstance(client, openai.AsyncOpenAI)
    except Exception:
        is_async = "Async" in type(client).__name__
    # Preserve the original client's timeout + custom headers so aux side-tasks
    # behave like the main-chat path (Hook 1) — same timeout budget, same headers —
    # instead of silently falling back to the adapter's defaults. Guarded so an SDK
    # sentinel / unexpected type can never break native client construction.
    import httpx as _httpx
    timeout = getattr(client, "timeout", None)
    if not isinstance(timeout, (_httpx.Timeout, int, float)):
        timeout = None
    default_headers = getattr(client, "default_headers", None)
    if not isinstance(default_headers, dict):
        default_headers = None
    sync = OllamaNativeClient(
        base_url=base,
        api_key=api_key,
        timeout=timeout,
        default_headers=default_headers,
        default_query=probe_query,
    )
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
            result = orig(*a, **k)
            # Unpack + swap inside try so an unexpected return arity (a future
            # upstream change) degrades to the original result instead of raising.
            try:
                client, model = result
                native = _native_swap(client)
                if native is not None:
                    logger.info("CI ollama-native: aux text client via /api/chat")
                    return native, model
            except Exception as exc:
                logger.warning("CI ollama-native Hook 2 (text) failed; using original: %s", exc)
            return result

        wrapped._ci_ollama_wrapped = True  # type: ignore[attr-defined]
        return wrapped

    def _wrap_vision(orig):
        if getattr(orig, "_ci_ollama_wrapped", False):
            return orig

        def wrapped(*a, **k):
            result = orig(*a, **k)
            try:
                provider, client, model = result
                native = _native_swap(client)
                if native is not None:
                    logger.info("CI ollama-native: aux vision client via /api/chat")
                    return provider, native, model
            except Exception as exc:
                logger.warning("CI ollama-native Hook 2 (vision) failed; using original: %s", exc)
            return result

        wrapped._ci_ollama_wrapped = True  # type: ignore[attr-defined]
        return wrapped

    for fname, wrapper in (("resolve_provider_client", _wrap_text),
                           ("resolve_vision_provider_client", _wrap_vision)):
        orig = getattr(module, fname, None)
        if orig is not None and not getattr(orig, "_ci_ollama_wrapped", False):
            setattr(module, fname, wrapper(orig))
            logger.info("CI ollama-native: Hook 2 installed (%s)", fname)


def _named_custom_is_ollama(name: str) -> bool:
    """Best-effort: is the "custom:<slug>" instance's endpoint actually Ollama?

    Resolves the slug to its config.yaml `custom_providers` entry, then runs the
    cached /api/version probe on its base_url. Fails OPEN (True) when the config
    or entry can't be resolved — this shim is an explicit Ollama opt-in, so an
    unresolvable instance is far more likely an Ollama one than not — and fails
    CLOSED only on a positive "this endpoint is not Ollama" probe answer.
    """
    try:
        from hermes_cli.config import load_config_readonly
        from hermes_cli.providers import custom_provider_slug

        import ollama_native_adapter as adapter
        from ollama_native_adapter import is_native_ollama_base_url

        name = str(name).strip().lower()  # match upstream's normalized slugs
        cfg = load_config_readonly() or {}
        # Prefer upstream's schema-merging accessor (legacy custom_providers list
        # + the keyed providers: form); fall back to the raw legacy list.
        try:
            from hermes_cli.config import get_compatible_custom_providers

            entries = get_compatible_custom_providers(cfg) or []
        except Exception:
            entries = cfg.get("custom_providers") or []
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            if custom_provider_slug(str(entry.get("name") or "")) != name:
                continue
            base = str(entry.get("base_url") or entry.get("url") or entry.get("api") or "")
            if not base:
                break
            # A config base_url may carry query params (URL-token auth) — split
            # them off so the probe URL stays well-formed and the token still
            # reaches the probe as query params (mirrors agent_init's query
            # extraction for the real client; native_root() only strips /v1).
            query = None
            if "?" in base:
                from urllib.parse import parse_qsl, urlsplit

                parts = urlsplit(base)
                query = dict(parse_qsl(parts.query)) or None
                base = parts._replace(query="", fragment="").geturl()
            # Use the entry's full auth material: api_key (or its key_env
            # env var) and any extra_headers (Cloudflare Access / proxy auth).
            api_key = str(entry.get("api_key") or "") or None
            if not api_key and entry.get("key_env"):
                api_key = os.environ.get(str(entry.get("key_env"))) or None
            extra_headers = entry.get("extra_headers")
            # TLS trust: the entry's own ssl fields, falling back to the
            # HERMES_CA_BUNDLE / SSL_CERT_FILE / *_CA_BUNDLE env vars the
            # resolver reads — a private-CA endpoint must not probe-fail as
            # indeterminate on every get_provider_profile call.
            verify = None
            try:
                from agent.ssl_verify import resolve_httpx_verify

                verify = resolve_httpx_verify(
                    ca_bundle=entry.get("ssl_ca_cert"),
                    ssl_verify=entry.get("ssl_verify"),
                    base_url=base,
                )
            except Exception:
                verify = None
            ok = is_native_ollama_base_url(
                base,
                api_key=api_key,
                default_headers=extra_headers if isinstance(extra_headers, dict) else None,
                default_query=query,
                verify=verify,
            )
            if ok:
                return True
            # A negative can be definitive (404 / wrong-shape 200 → long TTL) or
            # indeterminate (auth/TLS/transport failure → short TTL). Fail CLOSED
            # only on definitive "not Ollama"; stay open on indeterminate so an
            # authenticated instance this helper can't fully authenticate against
            # doesn't lose its num_ctx injection.
            entry_cached = adapter._OLLAMA_PROBE_CACHE.get(adapter.native_root(base))
            if entry_cached is not None:
                _, expires_at = entry_cached
                remaining = (expires_at or 0) - adapter.time.monotonic()
                if remaining > adapter._NEG_PROBE_TTL:
                    return False  # definitive non-Ollama
            return True
    except Exception:
        pass
    return True


def _patch_profiles(module) -> None:
    """Hook 3 — resolve a named custom instance ("custom:<name>") to the "custom"
    provider profile so the request-builder injects num_ctx for it.

    The registry lookup is an exact name/alias match, so "custom:ollama-2" returns
    None → the legacy request-build path runs → num_ctx is never placed in
    extra_body.options and the native client loads the model at Ollama's 4096 default.
    Gated per-call on the flag so it's a no-op when native mode is off.
    """
    orig = getattr(module, "get_provider_profile", None)
    if orig is None or getattr(orig, "_ci_ollama_wrapped", False):
        return

    def wrapped(name, *a, **k):
        profile = orig(name, *a, **k)
        try:
            if profile is None and _truthy(_FLAG) and str(name).startswith("custom:"):
                # Only resolve to the "custom" profile when the named instance's
                # endpoint actually is Ollama: the profile injects
                # max_tokens/reasoning fields that non-Ollama /v1 gateways
                # (vLLM, corp proxies) reject with HTTP 400. Best-effort: if the
                # instance's base_url can't be resolved from config, fail open
                # toward Ollama (this shim is an Ollama-targeting opt-in).
                if _named_custom_is_ollama(str(name)):
                    return orig("custom", *a, **k)
        except Exception as exc:
            logger.warning("CI ollama-native Hook 3 failed; using original: %s", exc)
        return profile

    wrapped._ci_ollama_wrapped = True  # type: ignore[attr-defined]
    module.get_provider_profile = wrapped
    logger.info("CI ollama-native: Hook 3 installed (get_provider_profile)")


_TARGETS = {
    "agent.agent_runtime_helpers": _patch_runtime,
    "agent.auxiliary_client": _patch_aux,
    "providers": _patch_profiles,
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

        # Serialize the self-removal/re-insertion so a concurrent import of another
        # target can't observe a half-mutated meta_path (or double-pop us).
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
            # A loader that forbids attribute assignment (immutable / some C loaders):
            # don't claim this spec — let the module import normally, just unpatched.
            return None
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
