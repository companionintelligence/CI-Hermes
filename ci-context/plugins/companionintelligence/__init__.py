"""Companion Intelligence memory plugin.

Passively ingests each conversation turn into the CI-Server knowledge graph
and injects relevant context back into the agent at the right moments:

  system_prompt_block()  — L0 user profile (name, relationships, preferences)
                           fetched once at session start, stable for the session
  prefetch()             — L1 hybrid search results for the message the user
                           just sent, recalled live and bounded so a slow server
                           can never hold a turn (see CI_MEMORY_RECALL_SYNC)
  recall_status()        — what the last prefetch injected, for the recall
                           indicator the host shows next to the reply
  get_tool_schemas()     — CI-Server's curated intent catalog exposed as callable
                           tools (read-only, appliance-local intents only)
  handle_tool_call()     — executes an intent via CI-Server's generic REST
                           executor (POST /api/intents/:name/execute)

Config (set by `hermes memory setup` or environment):
  CI_SERVER_URL    — Base URL of your CI-Server instance (e.g. http://ci-server:8642)
  CI_SERVER_TOKEN  — API key generated from the CI-Server admin panel
"""

from __future__ import annotations

import ipaddress
import json
import logging
import os
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

from agent.memory_provider import MemoryProvider

try:  # v0.21+: the host renders a recall indicator from this
    from agent.memory_provider import RecallStatus
except ImportError:  # older host — no indicator, nothing else changes
    RecallStatus = None  # type: ignore[assignment,misc]

from .intent_catalog import (
    describe_catalog_for_prompt,
    execute_path_candidates,
    fetch_intent_manifest,
    manifest_to_tool_schemas,
)

logger = logging.getLogger(__name__)


def _warn_catalog_unavailable(failures: list) -> None:
    """Say out loud that the curated intent catalog could not be reached.

    Without this the agent quietly loses every privacy-labelled intent and
    falls back to raw CRUD, which is exactly how CI-Server#1684 went unnoticed:
    both candidate paths 404'd through the gateway and nothing logged it.
    """
    logger.warning(
        "CI-Server intent catalog unavailable — the agent falls back to raw CRUD "
        "instead of the curated, privacy-labelled intents. Tried %s",
        "; ".join(failures),
    )

_REQUEST_TIMEOUT = 10.0   # seconds for write calls (absorb)
_PREFETCH_TIMEOUT = 5.0   # seconds to wait for a queued prefetch result (legacy path)
# Bound on a live recall. The host abandons an external prefetch after 8s and
# skips the provider until it returns; staying well under that keeps one slow
# search from costing the NEXT turn's recall too.
_RECALL_TIMEOUT = 4.0
_RECALL_LABEL = "Companion Memory"   # provider_label on the recall indicator
_MAX_TURN_CONTENT_CHARS = 4000   # max chars persisted per message (matches CI-OpenClaw)
_MAX_RECALL_RESULTS = 20         # cap on L1 recall breadth (matches CI-OpenClaw)


def _extract_block(resp: dict) -> str:
    """Read the text payload of a context/recall response.

    Tolerates the server returning the text under ``block``, ``text`` or
    ``context`` — matching CI-OpenClaw so both harnesses behave identically.
    """
    if not isinstance(resp, dict):
        return ""
    return resp.get("block") or resp.get("text") or resp.get("context") or ""


# ---------------------------------------------------------------------------
# API-system feature flags
# ---------------------------------------------------------------------------
# Each CI-Server API the plugin uses can be turned on/off independently via an
# env var (default on). Flag names match CI-OpenClaw:
#   CI_MEMORY_CONTEXT_ENABLED  — L0 profile injection (/api/memory/context)
#   CI_MEMORY_RECALL_ENABLED   — L1 per-turn recall (/api/memory/recall)
#   CI_MEMORY_RECALL_SYNC      — recall against the message the user just sent
#                                (default). Off = the host's queued model: the
#                                recall for turn N is what turn N+1 receives,
#                                and the first turn of a session gets nothing.
#   CI_MEMORY_TURN_ENABLED     — turn-sync ingestion (/api/memory/turn)
#   CI_MEMORY_WRITE_ENABLED    — durable note writes (/api/memory/write)
#   CI_INTENTS_ENABLED         — intent catalog (/api/agent/intents)
#   CI_INTENT_TOOLS_ENABLED    — register catalog intents as callable tools
#                                (POST /api/intents/:name/execute); also
#                                requires CI_INTENTS_ENABLED
_FALSY = {"0", "false", "no", "off"}


def _feature_enabled(env_name: str, default: bool = True) -> bool:
    raw = os.environ.get(env_name)
    if raw is None or not raw.strip():
        return default
    return raw.strip().lower() not in _FALSY


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def _load_config() -> dict:
    # Start with env vars as the base, then let config.json override.
    # This ensures CI_SERVER_TOKEN (written to .env by setup) is always
    # picked up even when the config.json only stores the URL.
    config = {
        "url": os.environ.get("CI_SERVER_URL", "").strip(),
        "token": os.environ.get("CI_SERVER_TOKEN", "").strip(),
    }
    try:
        from hermes_constants import get_hermes_home
        config_path = get_hermes_home() / "companionintelligence" / "config.json"
        if config_path.exists():
            # utf-8-sig so a BOM-prefixed file (Notepad's default on Windows) parses
            # rather than failing into the except below and leaving the plugin on
            # env vars alone. Matches save_config, and Hermes' own plugin.yaml read.
            file_cfg = json.loads(config_path.read_text(encoding="utf-8-sig"))
            config.update({k: v for k, v in file_cfg.items() if v})
    except Exception:
        pass
    return config


def _normalize_base_url(base_url: str) -> str:
    """Return the CI-Server gateway base URL, accepting the old MCP URL value."""
    base = base_url.strip().rstrip("/")
    if base.endswith("/api/mcp"):
        return base[: -len("/api/mcp")]
    return base


# ---------------------------------------------------------------------------
# HTTP client — urllib only, zero extra dependencies
# ---------------------------------------------------------------------------

def _plugin_version() -> str:
    """The version stamped into ``plugin.yaml``, or ``"unknown"``.

    Read with a line match rather than a YAML parser: this plugin declares no pip
    dependencies, so PyYAML is not guaranteed to be importable, and
    ``scripts/pack-memory-plugin.sh`` writes the field as a plain ``version: <x>``
    line at pack time. Never raises — an unreadable manifest must cost the
    User-Agent its version, not break every request.
    """
    try:
        manifest = Path(__file__).with_name("plugin.yaml")
        for line in manifest.read_text(encoding="utf-8").splitlines():
            if line.startswith("version:"):
                value = line.split(":", 1)[1].strip().strip("\"'")
                if value:
                    return value
    except Exception:
        pass
    return "unknown"


# Every request names itself. urllib's default is ``Python-urllib/<x.y>``, and edge
# proxies in front of a CI-Server deployment block that signature as a scripted client:
# Cloudflare's managed rules answer it 403 ("Error 1010") before the request reaches the
# server at all. Nothing in this plugin would surface that. Writes are swallowed rather
# than allowed to break a session, so a blocked plugin is indistinguishable from a
# working one with nothing to say — setup passes, and memory simply never accumulates.
# Naming the client clears those rules and makes the plugin identifiable in an
# operator's access log.
_USER_AGENT = f"companionintelligence-hermes-memory/{_plugin_version()}"


# Requests to an address a proxy cannot serve go direct.
#
# ``urlopen`` uses the default opener, which installs a ProxyHandler built from
# ``getproxies()``. On Windows that falls back to the WinINET registry proxy when no
# ``*_proxy`` env vars are set, and its "bypass local addresses" rule
# (``proxy_bypass_registry``) only exempts DOTLESS hostnames — so ``127.0.0.1``, the
# default CI-Server address this plugin ships with, is NOT bypassed. On a corporate
# laptop with a static proxy configured, requests to a CI-Server running on the same
# machine get handed to the proxy as an absolute-URI GET and never arrive. macOS has
# the analogous behaviour via ``getproxies_macosx_sysconf``.
#
# That failure is invisible: capture errors are swallowed rather than allowed to break
# a session (see the User-Agent note above), so setup passes and memory just never
# accumulates.
#
# The bypass is SCOPED rather than blanket, and the distinction matters. CI-Server can
# legitimately be reached at a public domain — the app's "Expose app" setting is a
# documented deployment — and on a corporate laptop the proxy is then the only route
# out. Ignoring proxies outright would fix the loopback case by breaking that one. So:
# addresses no proxy can resolve or route (loopback, RFC1918, link-local, the
# appliance's own local/VPN suffixes, and dotless hosts, which is what ``<local>`` was
# always meant to cover) go direct; everything else keeps stock urllib behaviour.
_DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# ``.lan`` is the appliance's default local domain and ``.ts.net`` a tailnet: both name
# hosts that exist only on the near side of any proxy.
_DIRECT_HOST_SUFFIXES = (".local", ".lan", ".internal", ".home.arpa", ".ts.net")

# Tailscale hands out addresses from the CGNAT range, which ``ipaddress`` does not
# classify as private — it is carrier space, publicly allocated. A tailnet address is
# still reachable only from inside the tailnet, so a proxy cannot serve it.
_DIRECT_NETWORKS = (
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("fd7a:115c:a1e0::/48"),
)


def _is_direct_host(host: str) -> bool:
    """True when *host* is one no proxy could usefully be asked about."""
    host = (host or "").strip().strip("[]").rstrip(".").lower()
    if not host:
        return False
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        # A dotless name is single-label, so it resolves on the local network only —
        # exactly the case ``<local>`` names, and the one Windows gets right.
        return "." not in host or host.endswith(_DIRECT_HOST_SUFFIXES)
    if ip.is_loopback or ip.is_private or ip.is_link_local:
        return True
    return any(ip in net for net in _DIRECT_NETWORKS if ip.version == net.version)


def _urlopen(req: urllib.request.Request, timeout: float):
    """Open *req*, bypassing any system/environment proxy for local addresses."""
    if _is_direct_host(urllib.parse.urlsplit(req.full_url).hostname or ""):
        return _DIRECT_OPENER.open(req, timeout=timeout)
    # Built per call rather than cached: a cached opener freezes the proxy settings at
    # import time, and this plugin is loaded once for the life of a long-running agent
    # that can move between networks. This path is the rare one — the shipped default
    # is loopback — so the cost is not on the hot route.
    return urllib.request.build_opener().open(req, timeout=timeout)


# ---------------------------------------------------------------------------
# Console output — the setup wizard must survive a non-UTF-8 stdout
# ---------------------------------------------------------------------------
# `hermes memory setup` is run from a terminal, and on Windows that terminal is
# frequently Git Bash / mintty — where Python sees a PIPE rather than a console and
# falls back to the ANSI code page (cp1252 on a typical machine) instead of UTF-8.
# None of ``─ ✓ ✗`` exist in cp1252, so the wizard used to die with
# UnicodeEncodeError on its second print: a traceback before the first prompt,
# with nothing configured and no hint why.

def _console_glyphs() -> tuple:
    """Return ``(ok, no, rule)`` glyphs stdout can actually encode."""
    encoding = getattr(sys.stdout, "encoding", None) or "ascii"
    try:
        "─✓✗—".encode(encoding)
    except (UnicodeEncodeError, LookupError):
        return "[ok]", "[!]", "-"
    return "✓", "✗", "─"


def _redact(text: str, secret: str) -> str:
    """Replace *secret* (and its repr-escaped form) in *text* with a masked stub."""
    if not secret:
        return text
    masked = f"<api key ...{secret[-4:]}>" if len(secret) > 4 else "<api key>"
    out = text.replace(secret, masked)
    # http.client formats the offending header through repr(), so the key can also
    # appear escaped — b'sk-live-...\r' — which a plain replace would miss.
    escaped = repr(secret)[1:-1]
    if escaped != secret:
        out = out.replace(escaped, masked)
    return out


def _say(text: str = "") -> None:
    """``print`` that cannot kill the wizard on a narrow console.

    The glyph constants above cover what this module writes deliberately; this is
    the backstop for everything else that reaches stdout — em dashes in prose, and
    server-supplied strings such as an error body echoed back to the user.
    """
    try:
        print(text)
    except UnicodeEncodeError:
        encoding = getattr(sys.stdout, "encoding", None) or "ascii"
        print(text.encode(encoding, errors="replace").decode(encoding, errors="replace"))


def _build_request(
    url: str,
    token: str,
    *,
    method: str,
    data: Optional[bytes] = None,
) -> urllib.request.Request:
    """Build a CI-Server request carrying the full standard header set.

    Every outbound call in this module goes through here, so a header can never be
    added on one path and forgotten on another — which is exactly how the
    User-Agent came to be missing from all four of them.
    """
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("x-api-key", token)
    req.add_header("Accept", "application/json")
    # urllib tests for its own default under the capitalized key, and add_header
    # stores "User-Agent" as "User-agent" — which is why setting it here is what
    # suppresses Python-urllib/x.y rather than sitting alongside it.
    req.add_header("User-Agent", _USER_AGENT)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    return req



#: CI-Server's marker for "the owner must approve this before it runs".
#:
#: It arrives inside a normal HTTP 200 body rather than as a 4xx, which is why it
#: has to be recognised explicitly instead of falling out of the error path.
_QUEUED_ERROR_CODE = "TOOL_QUEUED"


def _queued_action(result: Any) -> Optional[str]:
    """The pending-action id if this result is an approval request, else ``None``.

    Returns the id (possibly an empty string) only when the marker is present, so
    a server that omits the id still produces the right ANSWER — the agent must
    stop and report either way.

    The id lives under ``error.details``. CI-Server's ``ToolError`` is
    ``{code, message, retryable, details}`` and the queue metadata goes in
    ``details``; the type has no top-level slot for it. This read was
    ``error["pendingActionId"]``, which is always absent, so every queued call
    reported an empty id and the agent could never name the card it had just
    raised. Keying on the MARKER rather than the id is what kept the *answer*
    correct while the id was silently lost.

    The flat form is still accepted, because the two ends release
    independently: a 90-day connect key outlives a server upgrade, so a harness
    can be older or newer than the appliance it is talking to.
    """
    if not isinstance(result, dict):
        return None
    error = result.get("error")
    if not isinstance(error, dict) or error.get("code") != _QUEUED_ERROR_CODE:
        return None
    details = error.get("details")
    if isinstance(details, dict) and details.get("pendingActionId"):
        return str(details["pendingActionId"])
    return str(error.get("pendingActionId") or "")


def _queued_expiry(result: Any) -> Optional[str]:
    """When the owner's window to answer closes, if the server said.

    Separate from :func:`_queued_action` so that function keeps its narrow
    contract — "present, and here is the id" — which the empty-string case
    depends on.
    """
    if not isinstance(result, dict):
        return None
    error = result.get("error")
    if not isinstance(error, dict):
        return None
    details = error.get("details")
    if not isinstance(details, dict):
        return None
    expires = details.get("expiresAt")
    return str(expires) if expires else None

class _CIClient:
    def __init__(self, base_url: str, token: str, timeout: float = _REQUEST_TIMEOUT):
        self._base = _normalize_base_url(base_url)
        self._token = token
        self._timeout = timeout

    # ── Retrieval ────────────────────────────────────────────────────────────

    def context(self) -> dict:
        """L0 — static user profile block for the system prompt."""
        return self._get("/api/memory/context")

    def recall(self, query: str, max_results: int = 5) -> dict:
        """L1 — per-turn hybrid search against the knowledge graph."""
        capped = max(1, min(_MAX_RECALL_RESULTS, int(max_results or 5)))
        return self._post("/api/memory/recall", {"query": query, "maxResults": capped})

    # ── Ingestion ─────────────────────────────────────────────────────────────

    def turn(self, messages: list, session_id: str = "", platform: str = "") -> dict:
        """Ingest a conversation turn into the database."""
        payload: dict = {"messages": messages}
        if session_id:
            payload["sessionId"] = session_id
        if platform:
            payload["platform"] = platform
        return self._post("/api/memory/turn", payload)

    def write(self, content: str, source: str = "", title: str = "", session_id: str = "") -> dict:
        """Store a raw agent memory fragment in ci.agent_memory for later graph extraction."""
        payload: dict = {"content": content}
        if source:
            payload["source"] = source
        if title:
            payload["title"] = title
        if session_id:
            payload["sessionId"] = session_id
        # No 404 fallback: ``/api/memory/note`` was renamed to ``/write`` in
        # CI-Server on 2026-06-03 and no longer exists, so the fallback turned
        # one 404 into two and raised the second. Let a 404 surface as itself.
        return self._post("/api/memory/write", payload)

    # ── Intent execution ──────────────────────────────────────────────────────

    def invoke_intent(self, name: str, arguments: Optional[dict] = None) -> dict:
        """Execute a curated intent via CI-Server's generic REST executor.

        POSTs the tool input to the canonical execute path, falling through to
        the legacy ``/api/intents`` alias on a route-miss 404 — the same
        canonical-then-legacy ordering the catalog fetch uses. Returns the
        server's structured ToolResult JSON. Raises on transport/HTTP errors;
        the provider's ``handle_tool_call`` converts those to structured error
        strings so nothing propagates into the agent loop.
        """
        last_exc: Optional[urllib.error.HTTPError] = None
        for path in execute_path_candidates(name):
            try:
                return self._post(path, arguments or {})
            except urllib.error.HTTPError as exc:
                # 404 is both "route not deployed" and "unknown intent"; either
                # way trying the next candidate is safe (it 404s identically on
                # an unknown intent).
                if exc.code == 404:
                    last_exc = exc
                    continue
                raise
        if last_exc is not None:
            raise last_exc
        raise ValueError(f"invalid intent name: {name!r}")

    # ── Health ────────────────────────────────────────────────────────────────

    def health(self) -> bool:
        try:
            req = _build_request(f"{self._base}/api/health", self._token, method="GET")
            with _urlopen(req, timeout=3.0) as resp:
                return resp.status == 200
        except Exception:
            return False

    # ── Transport ─────────────────────────────────────────────────────────────

    def _get(self, path: str) -> dict:
        url = f"{self._base}{path}"
        req = _build_request(url, self._token, method="GET")
        try:
            with _urlopen(req, timeout=self._timeout) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
            logger.debug("CI-Server GET %s → HTTP %s: %s", path, exc.code, body[:200])
            raise
        except Exception as exc:
            logger.debug("CI-Server GET %s failed: %s", path, exc)
            raise

    def _post(self, path: str, payload: dict) -> dict:
        url = f"{self._base}{path}"
        data = json.dumps(payload).encode("utf-8")
        req = _build_request(url, self._token, method="POST", data=data)
        try:
            with _urlopen(req, timeout=self._timeout) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
            logger.debug("CI-Server POST %s → HTTP %s: %s", path, exc.code, body[:200])
            # The response body is consumed by the read above; stash it so
            # handle_tool_call can surface the server's error message (e.g. an
            # input-validation detail) to the agent.
            exc.ci_body = body  # type: ignore[attr-defined]
            raise
        except Exception as exc:
            logger.debug("CI-Server POST %s failed: %s", path, exc)
            raise


# ---------------------------------------------------------------------------
# MemoryProvider implementation
# ---------------------------------------------------------------------------

class CompanionIntelligenceProvider(MemoryProvider):
    """Injects CI-Server knowledge graph context into Hermes agent sessions."""

    def __init__(self):
        self._client: Optional[_CIClient] = None
        self._session_id = ""
        self._platform = ""
        self._sync_thread: Optional[threading.Thread] = None
        # Prefetch state — reset each turn by queue_prefetch (legacy queued path)
        self._prefetch_event: Optional[threading.Event] = None
        self._prefetch_result: Optional[str] = None
        self._prefetch_count: Optional[int] = None
        # What the last prefetch injected, for recall_status(). A count of None
        # means "nothing injected"; 0 means content without a discrete count.
        self._last_recall_count: Optional[int] = None
        # The live-recall path remembers its last answer so a retried message
        # (an interrupted turn re-sent) does not pay for the same search twice.
        self._last_recall_query = ""
        self._last_recall_block = ""
        self._last_recall_cached_count: Optional[int] = None
        # Intent tool schemas — fetched once per session on the first
        # get_tool_schemas() call, then cached (None = not fetched yet).
        self._tool_schemas: Optional[List[Dict[str, Any]]] = None

    @property
    def name(self) -> str:
        return "companionintelligence"

    def is_available(self) -> bool:
        cfg = _load_config()
        return bool(cfg.get("url") and cfg.get("token"))

    def save_config(self, values: dict, hermes_home: str) -> None:
        config_dir = Path(hermes_home) / "companionintelligence"
        config_dir.mkdir(parents=True, exist_ok=True)
        config_path = config_dir / "config.json"
        existing = {}
        if config_path.exists():
            try:
                # utf-8-sig, matching _load_config's utf-8 read (and tolerating a
                # BOM). Reading with the locale codec instead — cp1252 on Windows —
                # made a hand-edited config with any non-ASCII value raise, and the
                # `except` below then treated it as "no existing config" and wrote
                # back ONLY the keys being saved, silently dropping every other
                # setting the user had. On Linux the locale is UTF-8, so the
                # divergence never showed up there.
                existing = json.loads(config_path.read_text(encoding="utf-8-sig"))
            except Exception:
                pass
        existing.update(values)
        config_path.write_text(json.dumps(existing, indent=2), encoding="utf-8")

    def get_config_schema(self) -> List[Dict[str, Any]]:
        return [
            {
                "key": "url",
                "description": "CI-Server base URL",
                "required": True,
                "default": "http://127.0.0.1:8642",
                "env_var": "CI_SERVER_URL",
            },
            {
                "key": "token",
                "description": "CI-Server API key (generate in the CI-Server admin panel)",
                "required": True,
                "secret": True,
                "env_var": "CI_SERVER_TOKEN",
            },
        ]

    def post_setup(self, hermes_home: str, config: dict) -> None:
        """Interactive setup wizard with connection verification.

        Called by `hermes memory setup` instead of the generic schema-based
        flow when this method is present.  Handles prompting, connection test,
        and config persistence itself — nothing is saved if the health check
        fails.
        """
        import stat

        ok, no, rule = _console_glyphs()

        try:
            from hermes_cli.config import save_config as hermes_save_config
        except ImportError:
            _say(f"  {no} Could not import hermes config module — run from inside a Hermes install.\n")
            return

        hermes_home_path = Path(hermes_home)
        existing = _load_config()

        _say("\n  Companion Intelligence setup")
        _say(f"  {rule * 41}")
        _say("  Generate an API key in the CI-Server admin panel first.\n")

        # ── URL ──────────────────────────────────────────────────────────────
        default_url = existing.get("url") or "http://127.0.0.1:8642"
        sys.stdout.write(f"  CI-Server URL [{default_url}]: ")
        sys.stdout.flush()
        url = sys.stdin.readline().strip() or default_url
        if url and "://" not in url:
            url = f"http://{url}"

        # ── API key ───────────────────────────────────────────────────────────
        # Stripped: on Windows an env file written with CRLF (or hand-edited) hands
        # back a token with a trailing \r, and a \r in a header value makes
        # http.client raise ValueError — which the generic handler below would then
        # print, echoing the whole key to the terminal.
        existing_token = os.environ.get("CI_SERVER_TOKEN", "").strip()
        if existing_token:
            masked = f"...{existing_token[-4:]}" if len(existing_token) > 4 else "set"
            sys.stdout.write(f"  API key (current: {masked}, blank to keep): ")
        else:
            sys.stdout.write("  API key: ")
        sys.stdout.flush()

        token = sys.stdin.readline().strip()

        if not token:
            token = existing_token  # keep existing if blank

        if not url or not token:
            _say(f"\n  {no} Both URL and API key are required. Setup cancelled.\n")
            return

        # ── Connection test ───────────────────────────────────────────────────
        health_url = f"{url.rstrip('/')}/api/health"
        _say(f"\n  Testing connection: GET {health_url} ...")

        try:
            req = _build_request(health_url, token, method="GET")
            with _urlopen(req, timeout=6.0) as resp:
                status = resp.status
                body = resp.read().decode("utf-8", errors="replace")[:200]
            if status == 200:
                _say(f"  {ok} Connected  (HTTP {status}: {body})")
            else:
                _say(f"  {no} Unexpected response  HTTP {status}: {body}")
                _say("  Nothing was saved — run 'hermes memory setup' again when ready.\n")
                return
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")[:200] if exc.fp else ""
            _say(f"  {no} HTTP {exc.code} {exc.reason}")
            if body:
                _say(f"    {body}")
            # CI-Server answers in JSON. An HTML error body means something in front of
            # it refused the request and the server never saw it — the distinction that
            # decides whether to go re-mint the key or change the address.
            if "<html" in body.lower():
                _say("    That is an HTML error page, so it came from a CDN or proxy in front of")
                _say("    CI-Server rather than from CI-Server itself. Your key is not the problem;")
                _say("    try the server's LAN or VPN address instead of its public URL.")
            _say("  Nothing was saved — run 'hermes memory setup' again when ready.\n")
            return
        except urllib.error.URLError as exc:
            _say(f"  {no} Could not reach {url}")
            _say(f"    {exc.reason}")
            _say("  Nothing was saved — run 'hermes memory setup' again when ready.\n")
            return
        except Exception as exc:
            # Redacted: this catches ValueError from http.client, whose message quotes
            # the offending header value verbatim — i.e. the API key. Printing the
            # exception unfiltered wrote the user's live credential to the terminal
            # (and into any transcript or screenshot of it).
            _say(f"  {no} Unexpected error: {_redact(str(exc), token)}")
            _say("  Nothing was saved — run 'hermes memory setup' again when ready.\n")
            return

        _say(f"  {ok} Connected successfully\n")

        # ── Persist URL to config.json ────────────────────────────────────────
        self.save_config({"url": url}, hermes_home)

        # ── Persist token to .env (0600) ──────────────────────────────────────
        env_path = hermes_home_path / ".env"
        env_path.parent.mkdir(parents=True, exist_ok=True)
        # utf-8-sig, not utf-8: a Windows editor (Notepad's long-standing default)
        # saves this file with a BOM, which would otherwise stay glued to the first
        # line — so a leading CI_SERVER_TOKEN would not match the key comparison
        # below, and we would append a SECOND token line rather than replacing it.
        # The wizard would report success while a stale key kept being used.
        existing_lines = (
            env_path.read_text(encoding="utf-8-sig").splitlines()
            if env_path.exists()
            else []
        )
        new_lines: List[str] = []
        token_written = False
        for line in existing_lines:
            key = line.split("=", 1)[0].strip() if "=" in line else ""
            if key == "CI_SERVER_TOKEN":
                new_lines.append(f"CI_SERVER_TOKEN={token}")
                token_written = True
            else:
                new_lines.append(line)
        if not token_written:
            new_lines.append(f"CI_SERVER_TOKEN={token}")
        # newline="\n" so the file is LF on every platform. Without it, text mode
        # translates to os.linesep and this file goes out CRLF on Windows — and a
        # shell-side consumer that `source`s an env file then exports the token with
        # a trailing \r, which is rejected as a header value further down the line.
        env_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8", newline="\n")
        try:
            # POSIX only. On Windows this maps onto the read-only attribute and
            # cannot restrict group/other at all — the file is left to inherit the
            # profile directory's ACLs, which are user-private by default.
            env_path.chmod(stat.S_IRUSR | stat.S_IWUSR)  # 0600
        except OSError:
            pass

        # ── Activate provider in config.yaml ─────────────────────────────────
        if not isinstance(config.get("memory"), dict):
            config["memory"] = {}
        config["memory"]["provider"] = self.name
        hermes_save_config(config)

        _say(f"  {ok} API key saved to .env")
        _say(f"  {ok} URL saved to companionintelligence/config.json")
        _say(f"  {ok} memory.provider: companionintelligence activated in config.yaml")
        _say()
        _say("  Start a new Hermes session to activate.\n")

    # ---------------------------------------------------------------------------
    # Lifecycle
    # ---------------------------------------------------------------------------

    def initialize(self, session_id: str, **kwargs) -> None:
        cfg = _load_config()
        # Accept session_key as a fallback so a runtime that reports the id under
        # that name still tags turns correctly (matches CI-OpenClaw's handling).
        self._session_id = str(session_id or kwargs.get("session_key") or "").strip()
        # Hardcode the platform as "hermes" so CI-Server labels turns as
        # "hermes conversation" instead of the generic "tui conversation" the
        # opencode runtime reports. Mirrors how CI-OpenClaw hardcodes "openclaw".
        self._platform = "hermes"

        url = cfg.get("url") or os.environ.get("CI_SERVER_URL", "")
        token = cfg.get("token") or os.environ.get("CI_SERVER_TOKEN", "")

        if not url or not token:
            logger.warning("CI-Server URL or token missing — provider disabled")
            self._client = None
            return

        self._client = _CIClient(url, token)
        logger.warning("CI-Server provider ready  url=%s  session=%s", url, self._session_id)

    # ---------------------------------------------------------------------------
    # Context injection
    # ---------------------------------------------------------------------------

    def system_prompt_block(self) -> str:
        """L0 — fetch and return the user profile block + the CI Intent catalog.

        Called once at session start. Blocks briefly while the server responds,
        but this happens before the first user message so latency is invisible.
        """
        if not self._client:
            return ""

        blocks: List[str] = []

        if _feature_enabled("CI_MEMORY_CONTEXT_ENABLED"):
            try:
                resp = self._client.context()
                block = _extract_block(resp)
                if block:
                    blocks.append(block)
                logger.debug("CI-Server system_prompt_block: %d chars", len(block))
            except Exception as exc:
                logger.warning("CI-Server system_prompt_block failed: %s", exc)

        # Append the curated CI Intent catalog so the agent prefers the typed,
        # privacy-labelled intents over raw CRUD. Mirrors how CI-OpenClaw consumes
        # the same shared catalog; degrades silently if CI-Server lacks the endpoint.
        if _feature_enabled("CI_INTENTS_ENABLED"):
            catalog = describe_catalog_for_prompt(
                fetch_intent_manifest(self._client._get, _warn_catalog_unavailable)
            )
            if catalog:
                # When the catalog is also registered as callable tools (see
                # get_tool_schemas), tell the agent it can invoke these intents
                # mid-session instead of treating the catalog as descriptive only.
                if self.get_tool_schemas():
                    catalog += (
                        "\n\nIntents from this catalog are registered as callable tools in this "
                        "session — invoke them directly by tool name. Any marked destructive or "
                        "external needs the owner's approval: calling one asks, it does not act."
                    )
                blocks.append(catalog)

        return "\n\n".join(blocks)

    def _recall_sync(self) -> bool:
        return _feature_enabled("CI_MEMORY_RECALL_SYNC")

    def _do_recall(self, query: str):
        """One recall round-trip → ``(block, count)``; ``("", None)`` on failure."""
        try:
            resp = self._client.recall(query)
        except Exception as exc:
            logger.debug("CI-Server recall failed: %s", exc)
            return "", None
        block = _extract_block(resp)
        if not block:
            return "", None
        count = resp.get("resultCount") if isinstance(resp, dict) else None
        try:
            count = int(count)
        except (TypeError, ValueError):
            count = 0  # an older server: content, no discrete count
        return block, max(0, count)

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        """Legacy queued recall: the host calls this after turn N with turn N's
        message and consumes the answer at turn N+1.

        With CI_MEMORY_RECALL_SYNC (the default) this is a no-op — the search
        would be for a message the user has already had answered, and prefetch()
        recalls for the one they are sending now. Off, it keeps the host's model:
        the HTTP call runs in a background thread and prefetch() waits for it.
        """
        if not self._client or not _feature_enabled("CI_MEMORY_RECALL_ENABLED"):
            return
        if self._recall_sync():
            return

        self._prefetch_result = None
        self._prefetch_count = None
        self._prefetch_event = threading.Event()

        def _run() -> None:
            try:
                self._prefetch_result, self._prefetch_count = self._do_recall(query)
            finally:
                self._prefetch_event.set()

        t = threading.Thread(target=_run, daemon=True, name="ci-prefetch")
        t.start()

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        """Return the L1 context to inject for *query*, the message the user just sent.

        Default (CI_MEMORY_RECALL_SYNC on): recall live against *query*, bounded by
        _RECALL_TIMEOUT. The host's queued model hands turn N+1 the recall for
        turn N — one turn stale, and nothing at all on the first turn of a
        session, which is where "what's on today?" lands. A companion memory is
        only worth its tokens when what it recalls is about the message in hand.
        The search runs on a daemon thread and the wait is bounded, so a slow
        server costs at most the timeout and never the turn; a search that
        overruns is dropped, not injected late into a later turn.

        Legacy (flag off): the result queue_prefetch() started for the previous
        turn, waiting up to _PREFETCH_TIMEOUT for it.
        """
        self._last_recall_count = None
        if not self._client or not _feature_enabled("CI_MEMORY_RECALL_ENABLED"):
            return ""

        if not self._recall_sync():
            if self._prefetch_event is None:
                return ""
            self._prefetch_event.wait(timeout=_PREFETCH_TIMEOUT)
            block = self._prefetch_result or ""
            self._last_recall_count = self._prefetch_count if block else None
            return block

        query = (query or "").strip()
        if not query:
            return ""
        if query == self._last_recall_query and self._last_recall_block:
            self._last_recall_count = self._last_recall_cached_count
            return self._last_recall_block

        box: Dict[str, Any] = {}
        done = threading.Event()

        def _run() -> None:
            try:
                box["block"], box["count"] = self._do_recall(query)
            finally:
                done.set()

        threading.Thread(target=_run, daemon=True, name="ci-recall").start()
        if not done.wait(timeout=_RECALL_TIMEOUT):
            logger.warning("CI-Server recall took over %.1fs; this turn goes without it", _RECALL_TIMEOUT)
            return ""
        block = box.get("block") or ""
        if not block:
            return ""
        self._last_recall_query = query
        self._last_recall_block = block
        self._last_recall_cached_count = box.get("count")
        self._last_recall_count = box.get("count")
        return block

    def recall_status(self):
        """What the last prefetch injected — the host shows it beside the reply as
        ``🧠 Companion Memory — recalled N memories``, so the user can see memory
        was used even when the model does not say so. ``None`` when nothing was
        injected, or on a host without the indicator."""
        if RecallStatus is None or self._last_recall_count is None:
            return None
        return RecallStatus(provider_label=_RECALL_LABEL, count=self._last_recall_count)

    # ---------------------------------------------------------------------------
    # Turn sync — non-blocking write after each turn
    # ---------------------------------------------------------------------------

    def sync_turn(self, user_content: str, assistant_content: str, *,
                  session_id: str = "") -> None:
        if not self._client or not _feature_enabled("CI_MEMORY_TURN_ENABLED"):
            return

        messages = [
            {"role": "user",      "content": (user_content or "")[:_MAX_TURN_CONTENT_CHARS]},
            {"role": "assistant", "content": (assistant_content or "")[:_MAX_TURN_CONTENT_CHARS]},
        ]
        sid = session_id or self._session_id

        def _run() -> None:
            try:
                self._client.turn(messages, session_id=sid, platform=self._platform)
                logger.debug("CI-Server sync_turn ok  session=%s", sid)
            except Exception as exc:
                logger.warning("CI-Server sync_turn failed: %s", exc)

        # Wait for any prior sync to finish before starting a new one
        # (prevents out-of-order writes to the same session)
        if self._sync_thread and self._sync_thread.is_alive():
            self._sync_thread.join(timeout=5.0)

        self._sync_thread = threading.Thread(target=_run, daemon=True, name="ci-sync")
        self._sync_thread.start()

    # ---------------------------------------------------------------------------
    # Optional hooks
    # ---------------------------------------------------------------------------

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        """Flush the full session transcript on close."""
        if not self._client or not messages or not _feature_enabled("CI_MEMORY_TURN_ENABLED"):
            return

        # Wait for any in-flight sync before sending the final turn
        if self._sync_thread and self._sync_thread.is_alive():
            self._sync_thread.join(timeout=10.0)

        serialized = [
            {"role": m.get("role", "user"), "content": str(m.get("content", ""))[:_MAX_TURN_CONTENT_CHARS]}
            for m in messages
            if m.get("role") in ("user", "assistant")
        ]
        if not serialized:
            return

        try:
            self._client.turn(serialized, session_id=self._session_id,
                              platform=self._platform)
            logger.info("CI-Server session flushed (%d messages)", len(serialized))
        except Exception as exc:
            logger.warning("CI-Server on_session_end failed: %s", exc)

    def on_pre_compress(self, messages: List[Dict[str, Any]]) -> str:
        """Flush messages that are about to be dropped from the context window."""
        if not self._client or not messages or not _feature_enabled("CI_MEMORY_TURN_ENABLED"):
            return ""

        serialized = [
            {"role": m.get("role", "user"), "content": str(m.get("content", ""))[:_MAX_TURN_CONTENT_CHARS]}
            for m in messages
            if m.get("role") in ("user", "assistant")
        ]
        if not serialized:
            return ""

        def _run() -> None:
            try:
                self._client.turn(serialized, session_id=self._session_id,
                                  platform=self._platform)
            except Exception as exc:
                logger.debug("CI-Server on_pre_compress failed: %s", exc)

        t = threading.Thread(target=_run, daemon=True, name="ci-compress")
        t.start()
        return ""

    # ---------------------------------------------------------------------------
    # Memory write mirroring
    # ---------------------------------------------------------------------------

    def on_memory_write(self, action: str, target: str, content: str) -> None:
        """Mirror Hermes memory writes (MEMORY.md / USER.md) to ci.agent_memory.

        Called by the Hermes framework whenever it writes to one of its built-in
        memory files.  We store the fragment verbatim so the compaction cron can
        promote it into structured graph entities.

        Runs in a background thread so the agent is never blocked by the write.
        """
        if not self._client or not content.strip() or not _feature_enabled("CI_MEMORY_WRITE_ENABLED"):
            return

        # Skip clears — there is nothing meaningful to store.
        if action == "clear":
            return

        client = self._client
        source = target or "memory"
        # Capture session_id before spawning the thread (instance attr may change).
        session_id = self._session_id

        def _run() -> None:
            try:
                client.write(content, source=source, session_id=session_id)
                logger.debug("CI-Server on_memory_write stored  action=%s target=%s session=%s",
                             action, target, session_id)
            except Exception as exc:
                logger.debug("CI-Server on_memory_write failed: %s", exc)

        t = threading.Thread(target=_run, daemon=True, name="ci-memory-write")
        t.start()

    # ---------------------------------------------------------------------------
    # Tools — CI intents as callable tools
    # ---------------------------------------------------------------------------

    def _tools_client(self) -> Optional[_CIClient]:
        """The session client when initialized, else one built from config.

        The Hermes MemoryManager calls ``get_tool_schemas()`` at provider
        registration (``add_provider``) — BEFORE ``initialize()`` creates the
        session client — so tool discovery must be able to stand up its own
        client. ``is_available()`` already guaranteed URL + token exist for a
        registered provider.
        """
        if self._client:
            return self._client
        cfg = _load_config()
        url, token = cfg.get("url"), cfg.get("token")
        if url and token:
            return _CIClient(url, token)
        return None

    def _intent_tools_enabled(self) -> bool:
        # CI_INTENTS_ENABLED is the master switch for the intent-catalog
        # integration; CI_INTENT_TOOLS_ENABLED scopes the callable-tool half.
        # Both default on, matching every other CI_* flag in this plugin.
        return _feature_enabled("CI_INTENTS_ENABLED") and _feature_enabled("CI_INTENT_TOOLS_ENABLED")

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        """Expose CI-Server's curated intents as callable tools.

        Fetched from the intent catalog on the first call of the session and
        cached — the MemoryManager builds its tool→provider routing table from
        the first call, so later calls must return the same answer or it would
        advertise tools it cannot route. Only read-only, appliance-local
        intents are exposed (destructive/external intents are filtered here
        and rejected server-side with a 403). Never raises: an unreachable
        catalog degrades to no tools for the session, with a debug log.
        """
        if not self._intent_tools_enabled():
            return []
        if self._tool_schemas is not None:
            return self._tool_schemas

        client = self._tools_client()
        if client is None:
            logger.debug("CI intent tools: no CI-Server client configured; exposing no tools")
            self._tool_schemas = []
            return self._tool_schemas

        manifest = fetch_intent_manifest(client._get, _warn_catalog_unavailable)
        if manifest is None:
            logger.debug("CI intent tools: intent catalog unreachable; exposing no tools this session")
            self._tool_schemas = []
            return self._tool_schemas

        self._tool_schemas = manifest_to_tool_schemas(manifest)
        logger.debug("CI intent tools: %d callable intents registered", len(self._tool_schemas))
        return self._tool_schemas

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        """Execute a CI intent tool call via the generic REST executor.

        The runtime routes only tool names returned by ``get_tool_schemas()``
        here. Per the MemoryProvider contract this returns a JSON string — the
        server's structured ToolResult on success, or a structured error
        object on failure. Never raises into the agent loop.
        """
        client = self._tools_client()
        if client is None:
            return json.dumps({"success": False, "error": "CI-Server client is not configured"})
        try:
            result = client.invoke_intent(tool_name, args or {})

            # A queue is not a failure and must not read like one. CI-Server
            # answers a gated intent with a normal HTTP 200 carrying
            # ``error.code == TOOL_QUEUED`` — so it never reaches the except
            # branch below, and handed to the model raw it looks like something
            # to retry. Said plainly instead, with ``retry: false`` carried
            # explicitly so the instruction survives summarisation into a later
            # turn.
            queued = _queued_action(result)
            if queued is not None:
                return json.dumps(
                    {
                        "status": "awaiting_owner_approval",
                        "intent": tool_name,
                        "pendingActionId": queued,
                        # The owner has a deadline (24h by default). Worth
                        # telling the user, and it rides in the same object.
                        "expiresAt": _queued_expiry(result),
                        "retry": False,
                        "message": (
                            "Companion Memory has asked the owner to approve this. It has NOT "
                            "run. Tell the user you have requested approval; do not call this "
                            "tool again for the same request."
                        ),
                    }
                )

            return json.dumps(result)
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                message = (
                    f"CI-Server does not expose intent '{tool_name}' "
                    "(HTTP 404) — unknown intent, or the server predates the REST intent executor"
                )
            elif exc.code == 403:
                # No longer the destructive/external case: those are queued as an
                # approval card now, not refused. A 403 here means this key's
                # capability is genuinely too low for the intent.
                message = (
                    f"CI-Server refused intent '{tool_name}' (HTTP 403) — this connection's "
                    "capability is insufficient for it"
                )
            else:
                message = f"CI-Server intent '{tool_name}' failed (HTTP {exc.code})"
            # Not getattr(): HTTPError's addbase ancestor defines a __getattr__
            # that raises KeyError (not AttributeError) when fp is None, which
            # getattr's default does not swallow.
            detail = str(exc.__dict__.get("ci_body") or "")[:300]
            if detail:
                message = f"{message}: {detail}"
            logger.debug("CI intent tool '%s' HTTP error: %s", tool_name, message)
            return json.dumps({"success": False, "error": message})
        except Exception as exc:
            logger.debug("CI intent tool '%s' failed: %s", tool_name, exc)
            return json.dumps({"success": False, "error": f"CI-Server intent '{tool_name}' failed: {exc}"})

    # ---------------------------------------------------------------------------
    # Shutdown
    # ---------------------------------------------------------------------------

    def shutdown(self) -> None:
        if self._sync_thread and self._sync_thread.is_alive():
            self._sync_thread.join(timeout=5.0)


def register(ctx) -> None:
    """Register Companion Intelligence as a Hermes memory provider plugin."""
    ctx.register_memory_provider(CompanionIntelligenceProvider())
