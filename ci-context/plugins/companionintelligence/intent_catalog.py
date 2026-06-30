"""CI Intent catalog client for the Companion Intelligence Hermes plugin.

CI-Server publishes one curated, typed, domain-organized capability catalog at
``GET /api/intents`` (and as an ``intents://catalog`` MCP resource). This module
lets the Hermes memory provider fetch that catalog and inject a compact description
into the system prompt, so the agent prefers the curated, privacy-labelled intents
over raw CRUD — the same shared catalog CI-OpenClaw consumes, instead of bespoke
per-harness glue.

Pure + dependency-free so it is unit-testable without the Hermes runtime:
``fetch_intent_manifest`` takes a ``get_json(path)`` callable (the provider passes
the ``_CIClient._get`` bound method; tests pass a mock).
"""

from __future__ import annotations

from typing import Callable, Dict, List, Optional


def fetch_intent_manifest(get_json: Callable[[str], dict]) -> Optional[dict]:
    """Fetch the intent manifest, or ``None`` if unavailable or malformed.

    Never raises — discovery must degrade gracefully when CI-Server is unreachable.
    """
    try:
        body = get_json("/api/intents")
    except Exception:
        return None
    if not isinstance(body, dict) or not isinstance(body.get("intents"), list):
        return None
    return body


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
