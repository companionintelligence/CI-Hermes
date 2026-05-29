#!/usr/bin/env python3
"""
CI-Server Hermes installer.

Installs the Companion Intelligence MemoryProvider plugin into
$HERMES_HOME/plugins/companionintelligence/ so it appears in
`hermes memory setup`.

After running this script, complete the setup interactively:

    hermes memory setup
    → pick "companionintelligence"
    → enter your CI-Server URL and API key

Optionally, if CI_SERVER_ENABLED=true and both CI_SERVER_URL and
CI_SERVER_TOKEN are set, also registers CI-Server as an MCP server
in config.yaml (for agents that use the MCP tools directly).
"""

import os
import shutil
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Env
# ---------------------------------------------------------------------------

CI_URL = os.environ.get("CI_SERVER_URL", "").strip()
CI_TOKEN = os.environ.get("CI_SERVER_TOKEN", "").strip()
CI_ENABLED = os.environ.get("CI_SERVER_ENABLED", "false").lower() in ("true", "1", "yes", "on")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_SCRIPT_DIR = Path(__file__).parent
_PLUGIN_SRC = _SCRIPT_DIR / "companionintelligence"

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


# ---------------------------------------------------------------------------
# Step 1 — Install the MemoryProvider plugin (always runs)
# ---------------------------------------------------------------------------

def install_plugin(hermes_home: Path) -> bool:
    """Copy plugin package into $HERMES_HOME/plugins/companionintelligence/.

    Returns True if the plugin was installed or updated, False if skipped.
    """
    if not _PLUGIN_SRC.is_dir():
        print("[CI-Server] Plugin source not found — skipping plugin installation.")
        return False

    plugins_dir = hermes_home / "plugins"
    dest = plugins_dir / "companionintelligence"
    plugins_dir.mkdir(parents=True, exist_ok=True)

    if dest.exists():
        shutil.rmtree(dest)

    shutil.copytree(str(_PLUGIN_SRC), str(dest))
    print(f"[CI-Server] Plugin installed → {dest}")
    return True


# ---------------------------------------------------------------------------
# Step 2 — MCP server registration (only when URL + TOKEN are available)
# ---------------------------------------------------------------------------

def has_ci_mcp_server(config_text: str) -> bool:
    return "ci_server:" in config_text


def patch_mcp(config_text: str) -> str:
    """Append ci_server MCP entry under mcp_servers:."""
    mcp_url = CI_URL.rstrip("/") + "/api/mcp"
    lines = [
        "  ci_server:",
        f'    url: "{mcp_url}"',
        "    headers:",
        f'      x-api-key: "{CI_TOKEN}"',
        "    timeout: 180",
        "    connect_timeout: 60",
    ]
    block = "\n".join(lines)

    if "mcp_servers:" in config_text:
        config_text = config_text.rstrip() + "\n" + block + "\n"
    else:
        config_text = config_text.rstrip() + "\nmcp_servers:\n" + block + "\n"

    return config_text


def configure_mcp(config_path: str) -> None:
    config_text = read_config(config_path)

    if has_ci_mcp_server(config_text):
        print("[CI-Server] MCP server already configured.")
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
    elif CI_ENABLED:
        print("[CI-Server] CI_SERVER_ENABLED=true but URL or token missing — MCP skipped.")


if __name__ == "__main__":
    main()
