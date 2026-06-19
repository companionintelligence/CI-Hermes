#!/usr/bin/env python3
"""
CI-Server Hermes installer.

Installs the Companion Intelligence MemoryProvider plugin into
$HERMES_HOME/plugins/companionintelligence/ so it appears in
`hermes memory setup`.

The memory provider itself is activated by bootstrap-ci-context.sh when
credentials are present; you can also configure it interactively:

    hermes memory setup
    → pick "companionintelligence"
    → enter your CI-Server URL and API key

Additionally, whenever both CI_SERVER_URL and CI_SERVER_TOKEN are set (and
CI_SERVER_ENABLED is not "false"), this script registers CI-Server as an MCP
server in config.yaml (for agents that use the MCP tools directly).
"""

import os
import re
import shutil
import sys
import time
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Env
# ---------------------------------------------------------------------------

CI_URL = os.environ.get("CI_SERVER_URL", "").strip()
CI_TOKEN = os.environ.get("CI_SERVER_TOKEN", "").strip()
# Enabled by default; enablement is really gated by URL + token presence below
# (no credentials → nothing is configured). Setting CI_SERVER_ENABLED=false is
# an explicit off-switch even when credentials happen to be present. Mirrors
# CI-OpenClaw, which treats any value other than "false" as enabled.
CI_ENABLED = os.environ.get("CI_SERVER_ENABLED", "true").strip().lower() != "false"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_SCRIPT_DIR = Path(__file__).parent
_PLUGIN_SRC_CANDIDATES = [
    _SCRIPT_DIR / "companionintelligence",
    _SCRIPT_DIR / "ci-context" / "plugins" / "companionintelligence",
]

CONFIG_PATHS = [
    os.path.expanduser("~/.hermes/config.yaml"),
    "/opt/data/.hermes/config.yaml",
    "/home/node/.hermes/config.yaml",
    "/root/.hermes/config.yaml",
]


def find_config() -> str:
    for path in CONFIG_PATHS:
        if os.path.exists(path):
            return path
    preferred = "/opt/data/.hermes/config.yaml"
    os.makedirs(os.path.dirname(preferred), exist_ok=True)
    return preferred


def find_hermes_home() -> Path:
    hermes_home = os.environ.get("HERMES_HOME", "").strip()
    if hermes_home:
        return Path(hermes_home)
    return Path(find_config()).parent


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
    backup = path + ".pre-ci"
    if os.path.exists(path) and not os.path.exists(backup):
        shutil.copy(path, backup)


def find_plugin_src() -> Optional[Path]:
    for candidate in _PLUGIN_SRC_CANDIDATES:
        if candidate.is_dir():
            return candidate
    return None


# ---------------------------------------------------------------------------
# Step 1 — Install the MemoryProvider plugin (always runs)
# ---------------------------------------------------------------------------

def install_plugin(hermes_home: Path) -> bool:
    """Copy plugin package into $HERMES_HOME/plugins/companionintelligence/.

    Returns True if the plugin was installed or updated, False if skipped.
    """
    plugin_src = find_plugin_src()

    if not plugin_src:
        print("[CI-Server] Plugin source not found — skipping plugin installation.")
        return False

    plugins_dir = hermes_home / "plugins"
    dest = plugins_dir / "companionintelligence"
    plugins_dir.mkdir(parents=True, exist_ok=True)

    if dest.exists():
        shutil.rmtree(dest)

    shutil.copytree(str(plugin_src), str(dest))
    print(f"[CI-Server] Plugin installed → {dest}")
    return True


# ---------------------------------------------------------------------------
# Step 2 — MCP server registration (only when URL + TOKEN are available)
# ---------------------------------------------------------------------------

_CI_SERVER_RE = re.compile(r"^(\s*)ci_server:\s*(?:#.*)?$")
_MCP_SERVERS_RE = re.compile(r"^(\s*)mcp_servers:\s*(?:#.*)?$")


def _indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _is_blank_or_comment(line: str) -> bool:
    stripped = line.strip()
    return stripped == "" or stripped.startswith("#")


def _block_end(lines: list, start: int, indent: int) -> int:
    """Index just past the mapping block opened at `start` (whose key sits at
    `indent`): the first later line that has content and is indented <= indent."""
    for i in range(start + 1, len(lines)):
        if _is_blank_or_comment(lines[i]):
            continue
        if _indent_of(lines[i]) <= indent:
            return i
    return len(lines)


def _find_ci_server(lines: list):
    """Return (index, indent) of the `ci_server:` mapping line, or (None, None).
    Line-anchored (not a substring scan) so a comment or string mentioning
    `ci_server:` is not mistaken for a real block."""
    for i, line in enumerate(lines):
        match = _CI_SERVER_RE.match(line)
        if match:
            return i, len(match.group(1))
    return None, None


def has_ci_mcp_server(config_text: str) -> bool:
    index, _ = _find_ci_server(config_text.splitlines())
    return index is not None


def desired_mcp_url() -> str:
    """The /api/mcp URL we want the ci_server entry to point at."""
    ci_url = CI_URL.rstrip("/")
    return ci_url if ci_url.endswith("/api/mcp") else ci_url + "/api/mcp"


def _ci_server_lines(indent: int) -> list:
    """The ci_server block, with its key at `indent` spaces."""
    key = " " * indent
    child = " " * (indent + 2)
    grand = " " * (indent + 4)
    return [
        f"{key}ci_server:\n",
        f'{child}url: "{desired_mcp_url()}"\n',
        f"{child}headers:\n",
        f'{grand}x-api-key: "{CI_TOKEN}"\n',
        f"{child}timeout: 180\n",
        f"{child}connect_timeout: 60\n",
    ]


def patch_mcp(config_text: str) -> str:
    """Insert a ci_server entry *inside* the mcp_servers section, creating that
    section if it is absent. Inserting at the end of the section (rather than at
    EOF) keeps the block correctly nested even when mcp_servers is not the last
    top-level key — e.g. after Hermes re-dumps config.yaml and reorders keys."""
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
        # No section yet — create it at the top level with a 2-space child.
        return "".join(lines) + "mcp_servers:\n" + "".join(_ci_server_lines(2))

    # Nest under the existing section: reuse an existing child's indent if there
    # is one, otherwise the section indent + 2.
    end = _block_end(lines, mcp_index, mcp_indent)
    child_indent = mcp_indent + 2
    for i in range(mcp_index + 1, end):
        if not _is_blank_or_comment(lines[i]):
            child_indent = _indent_of(lines[i])
            break

    # Insert right after the last content line of the section (before trailing
    # blank lines) so the block stays within mcp_servers.
    insert_at = end
    while insert_at - 1 > mcp_index and _is_blank_or_comment(lines[insert_at - 1]):
        insert_at -= 1

    lines[insert_at:insert_at] = _ci_server_lines(child_indent)
    return "".join(lines)


def reconcile_mcp_block(config_text: str) -> "tuple[str, bool]":
    """Update url + x-api-key in an existing ci_server block to the current
    credentials. Returns (new_text, changed). Only the two credential-bearing
    lines are rewritten; timeouts, indentation and ordering are left untouched,
    so repeated runs stay byte-identical when nothing changed. The block bounds
    are derived from the actual indentation of the `ci_server:` line, so a
    re-indented config (different YAML emitter) is still reconciled."""
    lines = config_text.splitlines(keepends=True)
    start, indent = _find_ci_server(lines)
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
        m_key = re.match(r"^(\s*x-api-key:\s*).*$", lines[i])
        if m_key:
            new_line = f'{m_key.group(1)}"{CI_TOKEN}"\n'
            if lines[i] != new_line:
                lines[i] = new_line
                changed = True

    return "".join(lines), changed


def configure_mcp(config_path: str) -> None:
    config_text = read_config(config_path)

    # Reconcile credentials on every run rather than skipping when the block
    # already exists: the URL/key entered in the install dialog can change, and a
    # skip-if-exists would otherwise leave the MCP tools pointed at stale creds.
    if has_ci_mcp_server(config_text):
        new_text, changed = reconcile_mcp_block(config_text)
        if changed:
            backup_config(config_path)
            write_config(config_path, new_text)
            print(f"[CI-Server] MCP server credentials reconciled in config.yaml  (URL: {CI_URL})")
        else:
            print("[CI-Server] MCP server already up to date.")
        return

    backup_config(config_path)
    write_config(config_path, patch_mcp(config_text))
    print(f"[CI-Server] MCP server registered in config.yaml  (URL: {CI_URL})")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    hermes_home = find_hermes_home()

    # Step 1: install the plugin so it shows up in `hermes memory setup`
    installed = install_plugin(hermes_home)

    if installed:
        print()
        print("[CI-Server] To finish setup, run:")
        print("              hermes memory setup")
        print("            Pick 'companionintelligence', then enter your")
        print("            CI-Server URL and API key.")
        print()

    # Step 2: MCP registration — only if the operator has injected credentials
    # (typical in docker / CI-Hub deployments).
    if CI_ENABLED and CI_URL and CI_TOKEN:
        print("[CI-Server] Credentials detected — configuring MCP server...")

        config_path = find_config()
        for _ in range(30):
            if os.path.exists(config_path):
                break
            time.sleep(1)
        else:
            print("[CI-Server] Timed out waiting for config.yaml — MCP not configured.")
            return

        configure_mcp(config_path)
        print("[CI-Server] MCP configuration complete.")
    elif CI_ENABLED and (CI_URL or CI_TOKEN):
        # Only warn on a partial/incomplete config (one of URL/token present).
        # With no credentials at all, MCP simply isn't requested — stay quiet.
        print("[CI-Server] Incomplete config — set both CI_SERVER_URL and CI_SERVER_TOKEN to enable MCP; skipped.")


if __name__ == "__main__":
    main()
