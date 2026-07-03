#!/usr/bin/env python3
"""
Hub MCP Hermes configurator.

When HUB_MCP_URL and HUB_MCP_API_KEY are set (typical in CI-Hub deployments),
registers the Hub MCP server in config.yaml under ``mcp_servers.hub`` so the
Hermes agent's built-in MCP client can reach it. Coexists with the CI-Server
memory MCP block.

Transport: CI-Hub serves MCP over the spec-compliant **Streamable HTTP**
transport at a single ``/api/mcp`` endpoint (the legacy ``/api/mcp/sse`` +
``/api/mcp/messages`` scheme was removed). The ``hub`` block is therefore
written to mirror the proven ``ci_server`` block emitted by
``configure-ci-server.py``: a ``url`` ending in ``/api/mcp`` with **no**
``transport:`` line, letting the agent use its default Streamable HTTP client.
The blocks differ only in the auth header — the Hub authenticates with
``Authorization: Bearer <key>`` where CI-Server uses ``x-api-key``.
"""

import os
import re
import shutil
import time

# ---------------------------------------------------------------------------
# Env
# ---------------------------------------------------------------------------

HUB_MCP_URL = os.environ.get("HUB_MCP_URL", "").strip()
HUB_MCP_API_KEY = os.environ.get("HUB_MCP_API_KEY", "").strip()
# Enabled by default; enablement is gated by URL + key presence below.
HUB_MCP_ENABLED = os.environ.get("HUB_MCP_ENABLED", "true").strip().lower() != "false"

CONFIG_PATHS = [
    os.path.expanduser("~/.hermes/config.yaml"),
    "/opt/data/config.yaml",
    "/opt/data/.hermes/config.yaml",
    "/home/node/.hermes/config.yaml",
    "/root/.hermes/config.yaml",
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def find_config() -> str:
    for path in CONFIG_PATHS:
        if os.path.exists(path):
            return path
    preferred = "/opt/data/config.yaml"
    os.makedirs(os.path.dirname(preferred), exist_ok=True)
    return preferred


def read_config(path: str) -> str:
    if os.path.exists(path):
        with open(path) as f:
            return f.read()
    return ""


def write_config(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def backup_config(path: str) -> None:
    backup = path + ".pre-hub-mcp"
    if os.path.exists(path) and not os.path.exists(backup):
        shutil.copy(path, backup)


def desired_mcp_url() -> str:
    """Return the canonical Streamable HTTP MCP endpoint for the Hub (``…/api/mcp``).

    Normalizes whatever ``HUB_MCP_URL`` the Hub injected — a bare host, a
    ``…/api/mcp`` URL, or a legacy ``…/api/mcp/sse`` value — down to the single
    ``/api/mcp`` endpoint. A legacy ``/sse`` suffix is stripped rather than
    appended so an already-correct injected URL is not corrupted.
    """
    url = HUB_MCP_URL.rstrip("/")
    if url.endswith("/api/mcp/sse"):
        url = url[: -len("/sse")]
    if url.endswith("/api/mcp"):
        return url
    return url + "/api/mcp"


# ---------------------------------------------------------------------------
# MCP block patching
# ---------------------------------------------------------------------------

_HUB_RE = re.compile(r"^(\s*)hub:\s*(?:#.*)?$")
_MCP_SERVERS_RE = re.compile(r"^(\s*)mcp_servers:\s*(?:#.*)?$")


def _indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _is_blank_or_comment(line: str) -> bool:
    stripped = line.strip()
    return stripped == "" or stripped.startswith("#")


def _block_end(lines: list, start: int, indent: int) -> int:
    for i in range(start + 1, len(lines)):
        if _is_blank_or_comment(lines[i]):
            continue
        if _indent_of(lines[i]) <= indent:
            return i
    return len(lines)


def _find_mcp_servers(lines: list):
    for i, line in enumerate(lines):
        match = _MCP_SERVERS_RE.match(line)
        if match:
            return i, len(match.group(1))
    return None, None


def _find_hub_in_mcp_servers(lines: list):
    mcp_index, mcp_indent = _find_mcp_servers(lines)
    if mcp_index is None:
        return None, None

    end = _block_end(lines, mcp_index, mcp_indent)
    for i in range(mcp_index + 1, end):
        match = _HUB_RE.match(lines[i])
        if match:
            return i, len(match.group(1))
    return None, None


def _find_hub(lines: list):
    return _find_hub_in_mcp_servers(lines)


def has_hub_mcp_server(config_text: str) -> bool:
    index, _ = _find_hub(config_text.splitlines())
    return index is not None


def _hub_lines(indent: int) -> list:
    """YAML lines for the ``hub`` MCP server block, keyed at ``indent`` spaces.

    Mirrors the proven ``ci_server`` block shape (see configure-ci-server.py):
    ``url`` + ``headers`` + timeouts, with **no** ``transport:`` line so the
    Hermes agent uses its default Streamable HTTP client against ``/api/mcp``.
    """
    key = " " * indent
    child = " " * (indent + 2)
    grand = " " * (indent + 4)
    return [
        f"{key}hub:\n",
        f'{child}url: "{desired_mcp_url()}"\n',
        f"{child}headers:\n",
        f'{grand}Authorization: "Bearer {HUB_MCP_API_KEY}"\n',
        f"{child}timeout: 180\n",
        f"{child}connect_timeout: 60\n",
    ]


def patch_mcp(config_text: str) -> str:
    lines = config_text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"

    mcp_index = None
    mcp_indent = 0
    for i, line in enumerate(lines):
        match = _MCP_SERVERS_RE.match(line)
        if match:
            mcp_index = i
            mcp_indent = len(match.group(1))
            break

    if mcp_index is None:
        return "".join(lines) + "mcp_servers:\n" + "".join(_hub_lines(2))

    end = _block_end(lines, mcp_index, mcp_indent)
    child_indent = mcp_indent + 2
    for i in range(mcp_index + 1, end):
        if not _is_blank_or_comment(lines[i]):
            child_indent = _indent_of(lines[i])
            break

    insert_at = end
    while insert_at - 1 > mcp_index and _is_blank_or_comment(lines[insert_at - 1]):
        insert_at -= 1

    lines[insert_at:insert_at] = _hub_lines(child_indent)
    return "".join(lines)


def reconcile_mcp_block(config_text: str) -> "tuple[str, bool]":
    """Bring an existing ``hub`` block in line with the current transport + creds.

    A **complete** block (has both ``url`` and ``Authorization``) is updated in
    place: ``url`` is rewritten to the canonical ``/api/mcp`` endpoint,
    ``Authorization`` to the current key, and any stale ``transport:`` line is
    removed (older configs wrote ``transport: sse``; the block now omits it to
    mirror ``ci_server``). Timeouts, indentation and ordering are left untouched so
    a converged config stays byte-identical across runs.

    An **incomplete/malformed** block (missing ``url`` or ``Authorization``) is
    replaced wholesale with a correct ``_hub_lines`` block at the block's own
    indent. This avoids trying to guess where a missing key nests — inserting an
    ``Authorization`` at the block's end (rather than under the existing
    ``headers:`` mapping), or assuming a fixed child indent, could otherwise emit
    invalid YAML for a partial or re-indented block. Returns ``(new_text, changed)``.
    """
    lines = config_text.splitlines(keepends=True)
    start, indent = _find_hub_in_mcp_servers(lines)
    if start is None:
        return config_text, False

    end = _block_end(lines, start, indent)
    has_url = any(re.match(r"^\s*url:\s*", lines[i]) for i in range(start + 1, end))
    has_auth = any(re.match(r"^\s*Authorization:\s*", lines[i]) for i in range(start + 1, end))

    # Incomplete/malformed block → rewrite it wholesale to a known-good shape.
    if not (has_url and has_auth):
        new_block = _hub_lines(indent)
        if lines[start:end] == new_block:
            return config_text, False
        lines[start:end] = new_block
        return "".join(lines), True

    # Complete block → minimal in-place update: rewrite url + auth, drop transport.
    mcp_url = desired_mcp_url()
    changed = False
    remove_indices: list[int] = []
    for i in range(start + 1, end):
        m_url = re.match(r"^(\s*url:\s*).*$", lines[i])
        if m_url:
            new_line = f'{m_url.group(1)}"{mcp_url}"\n'
            if lines[i] != new_line:
                lines[i] = new_line
                changed = True
            continue
        if re.match(r"^\s*transport:\s*.*$", lines[i]):
            remove_indices.append(i)
            changed = True
            continue
        m_auth = re.match(r"^(\s*Authorization:\s*).*$", lines[i])
        if m_auth:
            new_line = f'{m_auth.group(1)}"Bearer {HUB_MCP_API_KEY}"\n'
            if lines[i] != new_line:
                lines[i] = new_line
                changed = True

    # Delete stale transport lines in reverse so earlier indices stay valid.
    for i in reversed(remove_indices):
        del lines[i]

    return "".join(lines), changed


def configure_mcp(config_path: str) -> None:
    config_text = read_config(config_path)

    if has_hub_mcp_server(config_text):
        new_text, changed = reconcile_mcp_block(config_text)
        if changed:
            backup_config(config_path)
            write_config(config_path, new_text)
            print(f"[Hub MCP] Server reconciled to Streamable HTTP in config.yaml  (URL: {desired_mcp_url()})")
        else:
            print("[Hub MCP] Server already up to date.")
        return

    backup_config(config_path)
    write_config(config_path, patch_mcp(config_text))
    print(f"[Hub MCP] Server registered (Streamable HTTP) in config.yaml  (URL: {desired_mcp_url()})")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    if not HUB_MCP_ENABLED:
        print("[Hub MCP] Disabled via HUB_MCP_ENABLED=false — skipped.")
        return

    if not (HUB_MCP_URL and HUB_MCP_API_KEY):
        if HUB_MCP_URL or HUB_MCP_API_KEY:
            print(
                "[Hub MCP] Incomplete config — set both HUB_MCP_URL and "
                "HUB_MCP_API_KEY to enable Hub MCP; skipped.",
            )
        return

    print("[Hub MCP] Credentials detected — configuring MCP server...")

    config_path = find_config()
    for _ in range(30):
        if os.path.exists(config_path):
            break
        time.sleep(1)
    else:
        print("[Hub MCP] Timed out waiting for config.yaml — MCP not configured.")
        return

    configure_mcp(config_path)
    print("[Hub MCP] MCP configuration complete.")


if __name__ == "__main__":
    main()
