"""CI Intent catalog client for the Companion Intelligence Hermes plugin.

CI-Server publishes one curated, typed, domain-organized capability catalog at
``GET /api/agent/intents`` (legacy alias ``/api/intents``; also an
``intents://catalog`` MCP resource). This module
lets the Hermes memory provider fetch that catalog and inject a compact description
into the system prompt, so the agent prefers the curated, privacy-labelled intents
over raw CRUD — the same shared catalog CI-OpenClaw consumes, instead of bespoke
per-harness glue.

Beyond the prompt block, the catalog is also the source of the plugin's callable
tool surface: ``manifest_to_tool_schemas`` maps the manifest's read-only,
appliance-local intents to OpenAI function-calling schemas (the format
``MemoryProvider.get_tool_schemas`` must return), and ``execute_path_candidates``
yields the ``POST`` paths of CI-Server's generic REST intent executor
(``/api/intents/:name/execute``) in the same canonical-then-legacy order as the
catalog fetch.

Pure + dependency-free so it is unit-testable without the Hermes runtime:
``fetch_intent_manifest`` takes a ``get_json(path)`` callable (the provider passes
the ``_CIClient._get`` bound method; tests pass a mock).
"""

from __future__ import annotations

from typing import Callable, Collection, Dict, List, Optional
from urllib.parse import quote


# Canonical path first, then the deprecated alias for older CI-Server builds
# that still serve the catalog from /api/intents.
_CATALOG_PATHS = ("/api/agent/intents", "/api/intents")


def fetch_intent_manifest(get_json: Callable[[str], dict]) -> Optional[dict]:
    """Fetch the intent manifest, or ``None`` if unavailable or malformed.

    Tries the canonical ``/api/agent/intents`` first, falling back to the legacy
    ``/api/intents`` alias. Never raises — discovery must degrade gracefully when
    CI-Server is unreachable.
    """
    for path in _CATALOG_PATHS:
        try:
            body = get_json(path)
        except Exception:
            continue
        if isinstance(body, dict) and isinstance(body.get("intents"), list):
            return body
    return None


def describe_catalog_for_prompt(manifest: Optional[dict]) -> str:
    """Render the catalog as a compact prompt block grouped by schema domain.

    Flags destructive and external intents so the agent treats them with care.
    Returns "" for a missing or empty manifest.
    """
    if not manifest:
        return ""
    intents = manifest.get("intents")
    if not isinstance(intents, list) or not intents:
        return ""

    by_domain: Dict[str, List[dict]] = {}
    for intent in intents:
        domain = intent.get("domain", "other")
        by_domain.setdefault(domain, []).append(intent)

    lines = [
        "## Companion Intelligence — Intent catalog",
        "",
        "Prefer these curated, typed actions over raw CRUD. Call an intent by its tool name (in backticks).",
        "",
    ]
    for domain, domain_intents in by_domain.items():
        lines.append(f"### {domain}")
        for intent in domain_intents:
            privacy = intent.get("privacy") or {}
            flags = []
            if privacy.get("destructive"):
                flags.append("destructive")
            if privacy.get("external"):
                flags.append("external")
            suffix = f" _({', '.join(flags)})_" if flags else ""
            tool = intent.get("tool", "")
            title = intent.get("title", "")
            desc = intent.get("description", "")
            lines.append(f"- `{tool}` — {title}: {desc}{suffix}")
        lines.append("")
    return "\n".join(lines).strip()


def manifest_to_tool_schemas(
    manifest: Optional[dict],
    include: Optional[Collection[str]] = None,
) -> List[Dict]:
    """Map manifest intents to OpenAI function-calling tool schemas.

    Only non-destructive AND non-external intents are mapped — the same policy
    CI-Server's generic REST executor enforces server-side with a 403, so the
    agent is never offered a tool the executor would refuse.

    ``include`` optionally restricts the result to intents whose ``tool`` (or
    dotted ``name``) is in the collection. Returns ``[]`` for a missing or
    malformed manifest — tool registration must degrade gracefully.

    Schema shape (per ``MemoryProvider.get_tool_schemas``):
    ``{"name": <underscored tool>, "description": ..., "parameters": <JSON Schema>}``
    """
    if not isinstance(manifest, dict):
        return []
    intents = manifest.get("intents")
    if not isinstance(intents, list):
        return []

    schemas: List[Dict] = []
    for intent in intents:
        if not isinstance(intent, dict):
            continue
        tool = intent.get("tool") or ""
        if not tool:
            continue
        if include is not None and tool not in include and intent.get("name") not in include:
            continue
        privacy = intent.get("privacy") or {}
        if privacy.get("destructive") or privacy.get("external"):
            continue
        title = intent.get("title") or ""
        desc = intent.get("description") or ""
        description = f"{title} — {desc}" if title and desc else (title or desc or tool)
        parameters = intent.get("parameters")
        if not isinstance(parameters, dict) or not parameters:
            parameters = {"type": "object", "properties": {}}
        schemas.append({"name": tool, "description": description, "parameters": parameters})
    return schemas


def execute_path_candidates(intent_name: str) -> List[str]:
    """``POST`` paths for executing an intent, in fallback order.

    Mirrors the catalog-path ordering (``_CATALOG_PATHS``): the canonical
    ``/api/agent/intents/:name/execute`` first, then the ``/api/intents``
    alias — today's CI-Server serves the executor from the alias, so callers
    must fall through on a route-miss 404. Accepts the dotted intent id
    (``predictions.forecast``) or its executable form (``predictions_forecast``);
    the server treats them as aliases. Returns ``[]`` for an empty name.
    """
    name = str(intent_name or "").strip()
    if not name:
        return []
    encoded = quote(name, safe="")
    return [f"{base}/{encoded}/execute" for base in _CATALOG_PATHS]
