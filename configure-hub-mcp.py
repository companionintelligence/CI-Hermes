#!/usr/bin/env python3
"""
Hub MCP Hermes configurator.

When HUB_MCP_URL and HUB_MCP_API_KEY are set (typical in CI-Hub deployments),
registers the Hub MCP server in config.yaml under mcp_servers.hub with SSE
transport and Bearer auth. Coexists with the CI-Server memory MCP block.
"""

import os
import re
import shutil
import sys
import time
from typing import Optional

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
    """The SSE endpoint we want the hub entry to point at."""
    url = HUB_MCP_URL.rstrip("/")
    if url.endswith("/api/mcp/sse"):
        return url
    if url.endswith("/api/mcp"):
        return url + "/sse"
    return url + "/api/mcp/sse"


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


def _find_hub(lines: list):
    for i, line in enumerate(lines):
        match = _HUB_RE.match(line)
        if match:
            return i, len(match.group(1))
    return None, None


def has_hub_mcp_server(config_text: str) -> bool:
    index, _ = _find_hub(config_text.splitlines())
    return index is not None


def _hub_lines(indent: int) -> list:
    key = " " * indent
    child = " " * (indent + 2)
    grand = " " * (indent + 4)
    return [
        f"{key}hub:\n",
        f'{child}url: "{desired_mcp_url()}"\n',
        f"{child}transport: sse\n",
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
    lines = config_text.splitlines(keepends=True)
    start, indent = _find_hub(lines)
    if start is None:
        return config_text, False

    end = _block_end(lines, start, indent)
    mcp_url = desired_mcp_url()
    changed = False
    for i in range(start + 1, end):
        m_url = re.match(r"^(\s*url:\s*).*$", lines[i])
        if m_url:
            new_line = f'{m_url.group(1)}"{mcp_url}"\n'
            if lines[i] != new_line:
                lines[i] = new_line
                changed = True
            continue
        m_transport = re.match(r"^(\s*transport:\s*).*$", lines[i])
        if m_transport:
            new_line = f"{m_transport.group(1)}sse\n"
            if lines[i] != new_line:
                lines[i] = new_line
                changed = True
            continue
        m_auth = re.match(r"^(\s*Authorization:\s*).*$", lines[i])
        if m_auth:
            new_line = f'{m_auth.group(1)}"Bearer {HUB_MCP_API_KEY}"\n'
            if lines[i] != new_line:
                lines[i] = new_line
                changed = True

    return "".join(lines), changed


def configure_mcp(config_path: str) -> None:
    config_text = read_config(config_path)

    if has_hub_mcp_server(config_text):
        new_text, changed = reconcile_mcp_block(config_text)
        if changed:
            backup_config(config_path)
            write_config(config_path, new_text)
            print(f"[Hub MCP] Server credentials reconciled in config.yaml  (URL: {desired_mcp_url()})")
        else:
            print("[Hub MCP] Server already up to date.")
        return

    backup_config(config_path)
    write_config(config_path, patch_mcp(config_text))
    print(f"[Hub MCP] Server registered in config.yaml  (URL: {desired_mcp_url()})")


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
