"""Companion Intelligence memory plugin.

Passively ingests each conversation turn into the CI-Server knowledge graph
and injects relevant context back into the agent at the right moments:

  system_prompt_block()  — L0 user profile (name, relationships, preferences)
                           fetched once at session start, stable for the session
  prefetch()             — L1 hybrid search results relevant to the current turn
                           queued as soon as the user message arrives, so the
                           HTTP call overlaps with other pre-turn processing

Config (set by `hermes memory setup` or environment):
  CI_SERVER_URL    — Base URL of your CI-Server instance (e.g. http://ci-server:8642)
  CI_SERVER_TOKEN  — API key generated from the CI-Server admin panel
"""

from __future__ import annotations

import json
import logging
import os
import sys
import threading
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional

from agent.memory_provider import MemoryProvider

from .intent_catalog import describe_catalog_for_prompt, fetch_intent_manifest

logger = logging.getLogger(__name__)

_REQUEST_TIMEOUT = 10.0   # seconds for write calls (absorb)
_PREFETCH_TIMEOUT = 5.0   # seconds to wait for a queued prefetch result
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
#   CI_MEMORY_TURN_ENABLED     — turn-sync ingestion (/api/memory/turn)
#   CI_MEMORY_WRITE_ENABLED    — durable note writes (/api/memory/write)
#   CI_INTENTS_ENABLED         — intent catalog (/api/intents)
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
            file_cfg = json.loads(config_path.read_text(encoding="utf-8"))
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
        try:
            return self._post("/api/memory/write", payload)
        except urllib.error.HTTPError as exc:
            # Older CI-Server builds expose this as /api/memory/note. Fall back on
            # 404 so a version skew doesn't drop the write (matches CI-OpenClaw).
            if exc.code == 404:
                return self._post("/api/memory/note", payload)
            raise

    # ── Health ────────────────────────────────────────────────────────────────

    def health(self) -> bool:
        try:
            req = urllib.request.Request(f"{self._base}/api/health")
            req.add_header("x-api-key", self._token)
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                return resp.status == 200
        except Exception:
            return False

    # ── Transport ─────────────────────────────────────────────────────────────

    def _get(self, path: str) -> dict:
        url = f"{self._base}{path}"
        req = urllib.request.Request(url, method="GET")
        req.add_header("x-api-key", self._token)
        req.add_header("Accept", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self._timeout) as resp:
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
        req = urllib.request.Request(url, data=data, method="POST")
        req.add_header("x-api-key", self._token)
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self._timeout) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
            logger.debug("CI-Server POST %s → HTTP %s: %s", path, exc.code, body[:200])
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
        # Prefetch state — reset each turn by queue_prefetch
        self._prefetch_event: Optional[threading.Event] = None
        self._prefetch_result: Optional[str] = None

    @property
    def name(self) -> str:
        return "companionintelligence"

    def is_available(self) -> bool:
        cfg = _load_config()
        return bool(cfg.get("url") and cfg.get("token"))

    def save_config(self, values: dict, hermes_home: str) -> None:
        from pathlib import Path
        config_dir = Path(hermes_home) / "companionintelligence"
        config_dir.mkdir(parents=True, exist_ok=True)
        config_path = config_dir / "config.json"
        existing = {}
        if config_path.exists():
            try:
                existing = json.loads(config_path.read_text())
            except Exception:
                pass
        existing.update(values)
        config_path.write_text(json.dumps(existing, indent=2))

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
        from pathlib import Path

        try:
            from hermes_cli.config import save_config as hermes_save_config
        except ImportError:
            print("  ✗ Could not import hermes config module — run from inside a Hermes install.\n")
            return

        hermes_home_path = Path(hermes_home)
        existing = _load_config()

        print("\n  Companion Intelligence setup")
        print("  ─────────────────────────────────────────")
        print("  Generate an API key in the CI-Server admin panel first.\n")

        # ── URL ──────────────────────────────────────────────────────────────
        default_url = existing.get("url") or "http://127.0.0.1:8642"
        sys.stdout.write(f"  CI-Server URL [{default_url}]: ")
        sys.stdout.flush()
        url = sys.stdin.readline().strip() or default_url
        if url and "://" not in url:
            url = f"http://{url}"

        # ── API key ───────────────────────────────────────────────────────────
        existing_token = os.environ.get("CI_SERVER_TOKEN", "")
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
            print("\n  ✗ Both URL and API key are required. Setup cancelled.\n")
            return

        # ── Connection test ───────────────────────────────────────────────────
        health_url = f"{url.rstrip('/')}/api/health"
        print(f"\n  Testing connection: GET {health_url} ...")

        try:
            req = urllib.request.Request(health_url, method="GET")
            req.add_header("x-api-key", token)
            req.add_header("Accept", "application/json")
            with urllib.request.urlopen(req, timeout=6.0) as resp:
                status = resp.status
                body = resp.read().decode("utf-8", errors="replace")[:200]
            if status == 200:
                print(f"  ✓ Connected  (HTTP {status}: {body})")
            else:
                print(f"  ✗ Unexpected response  HTTP {status}: {body}")
                print("  Nothing was saved — run 'hermes memory setup' again when ready.\n")
                return
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")[:200] if exc.fp else ""
            print(f"  ✗ HTTP {exc.code} {exc.reason}")
            if body:
                print(f"    {body}")
            print("  Nothing was saved — run 'hermes memory setup' again when ready.\n")
            return
        except urllib.error.URLError as exc:
            print(f"  ✗ Could not reach {url}")
            print(f"    {exc.reason}")
            print("  Nothing was saved — run 'hermes memory setup' again when ready.\n")
            return
        except Exception as exc:
            print(f"  ✗ Unexpected error: {exc}")
            print("  Nothing was saved — run 'hermes memory setup' again when ready.\n")
            return

        print("  ✓ Connected successfully\n")

        # ── Persist URL to config.json ────────────────────────────────────────
        self.save_config({"url": url}, hermes_home)

        # ── Persist token to .env (0600) ──────────────────────────────────────
        env_path = hermes_home_path / ".env"
        env_path.parent.mkdir(parents=True, exist_ok=True)
        existing_lines = (
            env_path.read_text(encoding="utf-8").splitlines()
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
        env_path.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
        try:
            env_path.chmod(stat.S_IRUSR | stat.S_IWUSR)  # 0600
        except OSError:
            pass

        # ── Activate provider in config.yaml ─────────────────────────────────
        if not isinstance(config.get("memory"), dict):
            config["memory"] = {}
        config["memory"]["provider"] = self.name
        hermes_save_config(config)

        print("  ✓ API key saved to .env")
        print("  ✓ URL saved to companionintelligence/config.json")
        print("  ✓ memory.provider: companionintelligence activated in config.yaml")
        print()
        print("  Start a new Hermes session to activate.\n")

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
            catalog = describe_catalog_for_prompt(fetch_intent_manifest(self._client._get))
            if catalog:
                blocks.append(catalog)

        return "\n\n".join(blocks)

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        """Kick off an async L1 search as soon as the user message arrives.

        The HTTP call runs in a background thread so it overlaps with any other
        pre-turn processing. prefetch() then waits for the result.
        """
        if not self._client or not _feature_enabled("CI_MEMORY_RECALL_ENABLED"):
            return

        self._prefetch_result = None
        self._prefetch_event = threading.Event()

        def _run() -> None:
            try:
                resp = self._client.recall(query)
                self._prefetch_result = _extract_block(resp)
            except Exception as exc:
                logger.debug("CI-Server prefetch failed: %s", exc)
                self._prefetch_result = ""
            finally:
                self._prefetch_event.set()

        t = threading.Thread(target=_run, daemon=True, name="ci-prefetch")
        t.start()

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        """Return the L1 search result queued by queue_prefetch().

        Waits up to _PREFETCH_TIMEOUT seconds for the background request to
        finish. Returns an empty string if the client is not ready or the
        request timed out / failed.
        """
        if not self._client or self._prefetch_event is None:
            return ""
        self._prefetch_event.wait(timeout=_PREFETCH_TIMEOUT)
        return self._prefetch_result or ""

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
    # Tools — not active
    # ---------------------------------------------------------------------------

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        return []

    # ---------------------------------------------------------------------------
    # Shutdown
    # ---------------------------------------------------------------------------

    def shutdown(self) -> None:
        if self._sync_thread and self._sync_thread.is_alive():
            self._sync_thread.join(timeout=5.0)


def register(ctx) -> None:
    """Register Companion Intelligence as a Hermes memory provider plugin."""
    ctx.register_memory_provider(CompanionIntelligenceProvider())
