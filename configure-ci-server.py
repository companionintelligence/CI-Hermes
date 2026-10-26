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

import errno
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import time
from pathlib import Path
from typing import Optional

try:
    import fcntl
except ImportError:  # not on Windows; the containers are Linux
    fcntl = None

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

# Hermes reads $HERMES_HOME/config.yaml, and the image sets HERMES_HOME=/opt/data,
# so /opt/data/config.yaml is the file that matters there. Without it in this list
# the script waited 30 s for a file under /opt/data/.hermes that Hermes never
# writes, and Memory's MCP server was never registered. The rest of the list
# matches configure-hub-mcp.py.
_HERMES_HOME_CONFIG = (
    os.path.join(os.environ["HERMES_HOME"].strip(), "config.yaml")
    if os.environ.get("HERMES_HOME", "").strip()
    else None
)

CONFIG_PATHS = [
    *([_HERMES_HOME_CONFIG] if _HERMES_HOME_CONFIG else []),
    os.path.expanduser("~/.hermes/config.yaml"),
    "/opt/data/config.yaml",
    "/opt/data/.hermes/config.yaml",
    "/home/node/.hermes/config.yaml",
    "/root/.hermes/config.yaml",
]


def find_config() -> str:
    for path in CONFIG_PATHS:
        if os.path.exists(path):
            return path
    preferred = _HERMES_HOME_CONFIG or "/opt/data/config.yaml"
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
    """Replace config.yaml in one step. The web and gateway containers run this at
    the same time on one volume, and Hermes may be reading the file, so it must
    never be seen half written."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        mode = stat.S_IMODE(os.stat(path).st_mode)
    except FileNotFoundError:
        mode = 0o600
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".config.yaml.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class ConfigLock:
    """The lock reconcile-hub-config.py and bootstrap-ci-context.sh hold around
    their own read-modify-write of config.yaml. Both containers patch the file at
    start, so without it one can write back a copy it read before the other added
    its block, and the block is gone."""

    def __init__(self, config_path: str, timeout: float = 30.0):
        self.path = os.path.join(os.path.dirname(config_path), ".hub-config.lock")
        self.timeout = timeout
        self.fh = None

    def __enter__(self):
        if fcntl is None:
            return self
        try:
            self.fh = open(self.path, "a+")
        except OSError as exc:
            print(f"[CI-Server] WARN: could not open {self.path} ({exc}); continuing unlocked")
            return self
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EACCES) or time.monotonic() > deadline:
                    print(f"[CI-Server] WARN: could not lock {self.path} ({exc}); continuing unlocked")
                    return self
                time.sleep(0.1)

    def __exit__(self, *exc):
        if self.fh is not None:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_UN)
            finally:
                self.fh.close()


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


# ---------------------------------------------------------------------------
# Ownership: which ci_server block this script wrote
# ---------------------------------------------------------------------------
#
# Memory's Connect hands the containers CI_SERVER_URL and CI_SERVER_TOKEN and
# this script writes the ci_server block from them. Disconnect revokes the key
# and restarts the containers without them. The block it wrote would then point
# Hermes at a revoked key on every start, so it is removed. A block someone wrote
# by hand is left alone: only a block whose url and key are still the ones this
# script last wrote (recorded, the key as a hash, next to config.yaml) is ours.

STATE_FILE = ".ci-server-mcp.json"


def _state_path(config_path: str) -> str:
    return os.path.join(os.path.dirname(config_path), STATE_FILE)


def _key_hash(key: str) -> str:
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def record_written_block(config_path: str) -> None:
    state = {"url": desired_mcp_url(), "keySha256": _key_hash(CI_TOKEN)}
    try:
        with open(_state_path(config_path), "w", encoding="utf-8") as f:
            json.dump(state, f)
    except OSError as exc:
        print(f"[CI-Server] WARN: could not record the MCP block's owner ({exc})")


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def _block_values(lines: list, start: int, end: int) -> "tuple[str, str]":
    url = key = ""
    for line in lines[start + 1:end]:
        m_url = re.match(r"^\s*url:\s*(.*?)\s*$", line)
        if m_url:
            url = _unquote(m_url.group(1))
        m_key = re.match(r"^\s*x-api-key:\s*(.*?)\s*$", line)
        if m_key:
            key = _unquote(m_key.group(1))
    return url, key


def remove_written_block(config_text: str, state: dict) -> "tuple[str, bool]":
    """Drop the ci_server block if it is still the one recorded in `state`.
    Returns (new_text, removed). An mcp_servers section left with nothing in it
    goes too, since an empty key reads as null and not as an empty mapping."""
    lines = config_text.splitlines(keepends=True)
    start, indent = _find_ci_server(lines)
    if start is None:
        return config_text, False
    end = _block_end(lines, start, indent)
    url, key = _block_values(lines, start, end)
    if not key or url != state.get("url") or _key_hash(key) != state.get("keySha256"):
        return config_text, False
    del lines[start:end]

    for i, line in enumerate(lines):
        match = _MCP_SERVERS_RE.match(line)
        if not match:
            continue
        section_end = _block_end(lines, i, len(match.group(1)))
        if all(_is_blank_or_comment(l) for l in lines[i + 1:section_end]):
            del lines[i:section_end]
        break
    return "".join(lines), True


def unconfigure_mcp(config_path: str) -> None:
    """Credentials are gone (Memory disconnected or switched off): remove the
    ci_server block this script wrote, if it is still there unchanged."""
    state_path = _state_path(config_path)
    if not os.path.exists(state_path) or not os.path.exists(config_path):
        return
    try:
        with open(state_path, encoding="utf-8") as f:
            state = json.load(f)
    except (OSError, ValueError):
        return
    with ConfigLock(config_path):
        new_text, removed = remove_written_block(read_config(config_path), state)
        if removed:
            write_config(config_path, new_text)
            print("[CI-Server] No Memory credentials: removed the MCP server block this script added.")
    try:
        os.unlink(state_path)
    except OSError:
        pass


def configure_mcp(config_path: str) -> None:
    with ConfigLock(config_path):
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
            record_written_block(config_path)
            return

        backup_config(config_path)
        write_config(config_path, patch_mcp(config_text))
        record_written_block(config_path)
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
    else:
        if CI_ENABLED and (CI_URL or CI_TOKEN):
            # Only warn on a partial/incomplete config (one of URL/token present).
            # With no credentials at all, MCP simply isn't requested — stay quiet.
            print("[CI-Server] Incomplete config — set both CI_SERVER_URL and CI_SERVER_TOKEN to enable MCP; skipped.")
        unconfigure_mcp(find_config())


if __name__ == "__main__":
    main()
