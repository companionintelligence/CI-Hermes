"""CI runtime context for Hermes Agent on the CI marketplace.

Puts RUNTIME_CONTEXT.md in front of the model once per session. On a host that
has ``register_system_prompt_section`` (Hermes v0.21+) the text is a frozen
system-prompt section; on older hosts it falls back to the ``pre_llm_call``
hook this plugin always used.

Why the section is preferred. ``pre_llm_call`` context is appended to the user
message at API time, and Hermes stamps those exact bytes onto the stored user
row so that every later turn replays them (the prompt-cache prefix has to stay
byte-stable). Each turn of a session therefore carried its own copy of this
text: a 30-turn conversation was re-sending ~5K tokens of identical runtime
context on every call, which on a 64K-token local model is a real slice of the
window and an earlier compaction. A system-prompt section is rendered once per
session, frozen on the agent, and persisted with the session, so the text is
in the prompt exactly once — and the system prompt is the right place for
"where am I running" facts in the first place.
"""

import logging
import re
from pathlib import Path

logger = logging.getLogger(__name__)

CONTEXT_FILE = Path(__file__).resolve().with_name("RUNTIME_CONTEXT.md")

# Upstream caps one section at 4,000 characters and skips (with a warning) any
# that exceeds it. RUNTIME_CONTEXT.md is well under that; if it ever grows past
# it, the hook path still delivers the text rather than losing it.
SECTION_ID = "ci-runtime"
SECTION_MAX_CHARS = 4_000


def _load_runtime_context():
    text = CONTEXT_FILE.read_text(encoding="utf-8").strip()
    if not text:
        raise RuntimeError(f"{CONTEXT_FILE} is empty")
    return _format_context(text)


def _format_context(text):
    lines = text.splitlines()
    while lines and not lines[0].strip():
        lines.pop(0)
    if lines and re.match(r"^#\s+", lines[0]):
        lines[0] = re.sub(r"^#\s+", "", lines[0]).rstrip(":")
        while len(lines) > 1 and not lines[1].strip():
            lines.pop(1)
    if lines:
        lines[0] = lines[0].rstrip(":") + ":"
    return "\n".join(lines).strip()


def _inject_ci_runtime_context(**kwargs):
    del kwargs
    return {"context": _load_runtime_context()}


def _register_as_section(ctx, context):
    """Register *context* as a frozen system-prompt section; False if the host cannot."""
    register_section = getattr(ctx, "register_system_prompt_section", None)
    if not callable(register_section):
        return False
    if len(context) > SECTION_MAX_CHARS:
        logger.warning(
            "ci-runtime: RUNTIME_CONTEXT.md is %d chars, over the %d-char section cap; "
            "injecting per turn instead", len(context), SECTION_MAX_CHARS,
        )
        return False
    try:
        register_section(SECTION_ID, context, position="after_memory")
    except Exception as exc:  # an API that exists but refuses us: keep the old path
        logger.warning("ci-runtime: system prompt section refused (%s); injecting per turn instead", exc)
        return False
    return True


def register(ctx):
    if not _register_as_section(ctx, _load_runtime_context()):
        ctx.register_hook("pre_llm_call", _inject_ci_runtime_context)
