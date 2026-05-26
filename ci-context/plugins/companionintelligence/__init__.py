"""Companion Intelligence memory plugin — passive context ingestion.

Dumps each conversation turn into the CI-Server knowledge graph via the
authenticated absorb endpoint.  The server handles deduplication and storage;
this plugin does not inject any context back into the agent (steel-thread phase).

Config (set by configure-ci-server.py or environment):
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

logger = logging.getLogger(__name__)

_ABSORB_TIMEOUT = 10.0  # seconds — give the server time to persist


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


# ---------------------------------------------------------------------------
# HTTP client — urllib only, zero extra dependencies
# ---------------------------------------------------------------------------

class _CIClient:
    def __init__(self, base_url: str, token: str, timeout: float = _ABSORB_TIMEOUT):
        self._base = base_url.rstrip("/")
        self._token = token
        self._timeout = timeout

    def absorb(self, messages: list, session_id: str = "", platform: str = "") -> dict:
        payload: dict = {"messages": messages}
        if session_id:
            payload["sessionId"] = session_id
        if platform:
            payload["platform"] = platform
        return self._post("/api/agent/absorb", payload)

    def health(self) -> bool:
        try:
            req = urllib.request.Request(f"{self._base}/api/health")
            req.add_header("Authorization", f"Bearer {self._token}")
            with urllib.request.urlopen(req, timeout=3.0) as resp:
                return resp.status == 200
        except Exception:
            return False

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
    """Passively ingests conversation context into the CI-Server knowledge graph."""

    def __init__(self):
        self._client: Optional[_CIClient] = None
        self._session_id = ""
        self._platform = ""
        self._sync_thread: Optional[threading.Thread] = None

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
        self._session_id = str(session_id or "").strip()
        self._platform = str(kwargs.get("platform") or "").strip()

        url = cfg.get("url") or os.environ.get("CI_SERVER_URL", "")
        token = cfg.get("token") or os.environ.get("CI_SERVER_TOKEN", "")

        if not url or not token:
            logger.warning("CI-Server URL or token missing — provider disabled")
            self._client = None
            return

        self._client = _CIClient(url, token)
        logger.warning("CI-Server provider ready  url=%s  session=%s", url, self._session_id)

    def system_prompt_block(self) -> str:
        # No context injection in steel-thread phase
        return ""

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        pass  # not active in this phase

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        return ""  # not active in this phase

    # ---------------------------------------------------------------------------
    # Turn sync — non-blocking write after each turn
    # ---------------------------------------------------------------------------

    def sync_turn(self, user_content: str, assistant_content: str, *,
                  session_id: str = "") -> None:
        if not self._client:
            return

        logger.warning(
            "CI-Server sync_turn called  user=%r  assistant=%r",
            (user_content or "")[:80],
            (assistant_content or "")[:80],
        )

        messages = [
            {"role": "user",      "content": (user_content or "")[:4000]},
            {"role": "assistant", "content": (assistant_content or "")[:4000]},
        ]
        sid = session_id or self._session_id

        def _run():
            try:
                self._client.absorb(messages, session_id=sid, platform=self._platform)
                logger.warning("CI-Server sync_turn ok  session=%s", sid)
            except Exception as exc:
                logger.warning("CI-Server sync_turn failed: %s", exc)

        # Wait for any prior sync to finish before starting a new one
        # (prevents out-of-order writes to the same session row)
        if self._sync_thread and self._sync_thread.is_alive():
            self._sync_thread.join(timeout=5.0)

        self._sync_thread = threading.Thread(target=_run, daemon=True, name="ci-sync")
        self._sync_thread.start()

    # ---------------------------------------------------------------------------
    # Optional hooks
    # ---------------------------------------------------------------------------

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        """Flush the full session transcript on close."""
        if not self._client or not messages:
            return

        # Wait for any in-flight sync before sending the final absorb
        if self._sync_thread and self._sync_thread.is_alive():
            self._sync_thread.join(timeout=10.0)

        serialized = [
            {"role": m.get("role", "user"), "content": str(m.get("content", ""))[:4000]}
            for m in messages
            if m.get("role") in ("user", "assistant")
        ]
        if not serialized:
            return

        try:
            self._client.absorb(serialized, session_id=self._session_id,
                                platform=self._platform)
            logger.info("CI-Server session absorbed (%d messages)", len(serialized))
        except Exception as exc:
            logger.warning("CI-Server on_session_end failed: %s", exc)

    def on_pre_compress(self, messages: List[Dict[str, Any]]) -> str:
        """Absorb messages that are about to be dropped from the context window."""
        if not self._client or not messages:
            return ""

        serialized = [
            {"role": m.get("role", "user"), "content": str(m.get("content", ""))[:2000]}
            for m in messages
            if m.get("role") in ("user", "assistant")
        ]
        if not serialized:
            return ""

        def _run():
            try:
                self._client.absorb(serialized, session_id=self._session_id,
                                    platform=self._platform)
            except Exception as exc:
                logger.debug("CI-Server on_pre_compress failed: %s", exc)

        t = threading.Thread(target=_run, daemon=True, name="ci-compress")
        t.start()
        return ""

    # ---------------------------------------------------------------------------
    # Tools — disabled in this phase
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
