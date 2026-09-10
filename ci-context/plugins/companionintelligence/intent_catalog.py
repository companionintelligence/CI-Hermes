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


def fetch_intent_manifest(
    get_json: Callable[[str], dict],
    on_unavailable: Optional[Callable[[List[str]], None]] = None,
) -> Optional[dict]:
    """Fetch the intent manifest, or ``None`` if unavailable or malformed.

    Tries the canonical ``/api/agent/intents`` first, falling back to the legacy
    ``/api/intents`` alias. Never raises — discovery must degrade gracefully when
    CI-Server is unreachable.

    Degrading *quietly* is what let CI-Server#1684 survive for months: both paths
    404'd through the appliance gateway (which strips ``/api`` while the
    controller had baked it in), this returned ``None``, and the agent silently
    fell back to raw CRUD with nothing logged. ``on_unavailable`` is how the
    caller gets told — graceful degradation should still be *audible*. It fires
    only when every candidate path failed, so a legacy-alias fallback that
    succeeds stays silent.
    """
    failures: List[str] = []

    for path in _CATALOG_PATHS:
        try:
            body = get_json(path)
        except Exception as error:  # noqa: BLE001 - any transport failure is a failed path
            failures.append(f"{path}: {error!s}")
            continue
        if isinstance(body, dict) and isinstance(body.get("intents"), list):
            return body
        # A 200 that is not a manifest is its own failure mode, and the one a
        # gateway misroute produces: nginx serves the SPA rather than 404ing,
        # so the body parses but has no intents[].
        failures.append(f"{path}: 200 without an intents[] list")

    if on_unavailable is not None:
        on_unavailable(failures)
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


#: Appended to a gated intent's description.
#:
#: Without it the agent meets the gate only by calling, and reads the queued
#: result as a failure — and the obvious next move after a failure is to retry,
#: which turns one intent into a pile of duplicate cards for the owner.
_APPROVAL_NOTE = (
    "\n\nRequires the owner's approval: calling this does NOT perform it. "
    "Companion Memory queues an approval card and the owner answers on their own "
    "device. Report that you have asked and move on — do NOT call it again to "
    "check, and do not retry."
)


def manifest_to_tool_schemas(
    manifest: Optional[dict],
    include: Optional[Collection[str]] = None,
) -> List[Dict]:
    """Map manifest intents to OpenAI function-calling tool schemas.

    EVERY intent is mapped, including destructive and external ones.

    They used to be skipped, on the sound reasoning that CI-Server would answer
    them with a 403 anyway — true while a connect key held ``write`` capability,
    because ``capabilityAllows`` refused them before the gate was reached.

    CI-Server now mints these keys at ``full`` and QUEUES anything irreversible
    as an approval card for the owner instead of refusing it. Under that design
    the filter is backwards: a tool the agent cannot call is a card it can never
    ask for. Gated intents are mapped with an explicit note in the description
    (see ``_APPROVAL_NOTE``) so the model knows the owner decides, rather than
    discovering it from a result it will read as a plain failure.

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
        title = intent.get("title") or ""
        desc = intent.get("description") or ""
        description = f"{title} — {desc}" if title and desc else (title or desc or tool)
        if privacy.get("destructive") or privacy.get("external"):
            description = f"{description}{_APPROVAL_NOTE}"
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
