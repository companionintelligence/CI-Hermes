#!/bin/bash
# Enable the bundled CI runtime plugin and skill directory in Hermes config.
# Also installs the Companion Intelligence memory provider plugin so it
# appears in `hermes memory setup`.
#
# When Companion Memory credentials are supplied at install time
# (CI_SERVER_URL + CI_SERVER_TOKEN, set via the marketplace install dialog),
# the provider is also activated automatically — its plugin is enabled and
# selected as the active memory provider in config.yaml — so no manual
# `hermes memory setup` step is needed. This mirrors CI-OpenClaw.
#
# This stays idempotent so web and terminal startup can both run it safely.
set -euo pipefail

DATA_DIR="${HERMES_HOME:-/opt/data}"
SKILLS_SOURCE="/app/ci-context/skills"
CONFIG_FILE="${DATA_DIR}/config.yaml"
PLUGIN_NAME="ci-runtime"
CI_PLUGIN_SRC="/app/ci-context/plugins/companionintelligence"
CI_PLUGIN_DEST="${DATA_DIR}/plugins/companionintelligence"
CI_MEMORY_PLUGIN="companionintelligence"

# Activate the bundled provider only when both credentials are present, matching
# the memory plugin's own is_available() check (URL + token required). The
# plugin's _load_config() .strip()s these env vars, so a whitespace-only value
# counts as missing — we remove whitespace here too before the emptiness check,
# otherwise we'd select a non-functional provider. (URLs/tokens carry no internal
# whitespace, so removing all of it is equivalent to a strip for this purpose.)
# An explicit CI_SERVER_ENABLED=false is honoured as an off-switch (mirrors
# CI-OpenClaw), lowercased and whitespace-removed so FALSE / "false " also
# disable.
ci_url_norm="$(printf '%s' "${CI_SERVER_URL:-}" | tr -d '[:space:]')"
ci_token_norm="$(printf '%s' "${CI_SERVER_TOKEN:-}" | tr -d '[:space:]')"
ci_enabled_norm="$(printf '%s' "${CI_SERVER_ENABLED:-true}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
if [[ -n "${ci_url_norm}" && -n "${ci_token_norm}" \
      && "${ci_enabled_norm}" != "false" ]]; then
  CI_MEMORY_PROVIDER="${CI_MEMORY_PLUGIN}"
else
  CI_MEMORY_PROVIDER=""
fi

if [[ ! -d "${DATA_DIR}" ]]; then
  echo "CI context: ${DATA_DIR} does not exist; persistent data volume is not mounted" >&2
  exit 1
fi

# ── Companion Intelligence memory plugin ──────────────────────────────────────
# Copy into $HERMES_HOME/plugins/ so `hermes memory setup` discovers it.
# Always sync to pick up image updates; preserve any user-written config.json.
if [[ -d "${CI_PLUGIN_SRC}" ]]; then
  mkdir -p "${CI_PLUGIN_DEST}"
  cp -r "${CI_PLUGIN_SRC}/." "${CI_PLUGIN_DEST}/"
  echo "CI context: companionintelligence plugin installed → ${CI_PLUGIN_DEST}"
fi

# Hub-managed inference settings (model, endpoint, context window, model picker
# entry, side-task routing) follow the Hub handout in .env.hub-bootstrap on every
# start. One implementation, shared with bootstrap-from-hub.sh; see its docstring
# for ownership (a user's own edits are kept) and the 64K-minimum refusal. Runs
# before the MCP configurators, which wait for config.yaml to exist.
HUB_ENV_FILE="${DATA_DIR}/.env.hub-bootstrap"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${SCRIPT_DIR}/reconcile-hub-config.py" --data-dir "${DATA_DIR}" \
  || echo "CI context: ERROR: config.yaml reconcile failed; Hermes keeps its previous inference settings" >&2

# Run the CI-Server configurator (MCP registration when credentials are present).
# Uses CI_SERVER_URL / CI_SERVER_TOKEN / CI_SERVER_ENABLED from the environment.
python3 /app/configure-ci-server.py 2>&1 || true

# Register Hub platform MCP (SSE + Bearer) when Hub injects credentials.
python3 /app/configure-hub-mcp.py 2>&1 || true

if [[ -f "${CONFIG_FILE}" ]]; then
  python3 - "${CONFIG_FILE}" "${SKILLS_SOURCE}" "${PLUGIN_NAME}" "${CI_MEMORY_PROVIDER}" "${HUB_ENV_FILE}" <<'PY'
from pathlib import Path
import fcntl
import os
import re
import sys
import tempfile

config_path = Path(sys.argv[1])
# The web and gateway containers run this at the same time on one volume, and
# reconcile-hub-config.py edits the same file: hold its lock for the whole
# read-modify-write so neither loses the other's changes.
_lock = open(config_path.parent / ".hub-config.lock", "a+")
fcntl.flock(_lock, fcntl.LOCK_EX)
skills_dir = sys.argv[2]
plugin_name = sys.argv[3]
memory_provider = sys.argv[4] if len(sys.argv) > 4 else ""
hub_env_file = sys.argv[5] if len(sys.argv) > 5 else ""

text = config_path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)

def is_top_level_key(line: str) -> bool:
    return re.match(r"^[A-Za-z_][A-Za-z0-9_-]*:\s*(?:#.*)?$", line) is not None

def section_bounds(section: str):
    start = next(
        (i for i, line in enumerate(lines) if re.match(rf"^{re.escape(section)}:\s*(?:#.*)?$", line)),
        None,
    )
    if start is None:
        return None, None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if is_top_level_key(lines[i]):
            end = i
            break
    return start, end

def ensure_child_list_item(section: str, child: str, item: str):
    global lines
    section_index, section_end = section_bounds(section)
    if section_index is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.extend([
            f"{section}:\n",
            f"  {child}:\n",
            f"    - {item}\n",
        ])
        return

    child_index = None
    # Match the child key whether it is an empty block (`child:`) or an inline
    # empty list (`child: []`). PyYAML serializes empty lists as `[]`, so a
    # config re-dumped by Hermes can present either form; treating only the
    # block form as a match would otherwise insert a duplicate child key.
    child_re = re.compile(rf"^  {re.escape(child)}:\s*(\[\s*\])?\s*(?:#.*)?$")
    for i in range(section_index + 1, section_end):
        match = child_re.match(lines[i])
        if match:
            child_index = i
            if match.group(1):  # was `child: []` — open it so items can append
                lines[i] = f"  {child}:\n"
            break

    if child_index is None:
        lines[section_index + 1:section_index + 1] = [
            f"  {child}:\n",
            f"    - {item}\n",
        ]
        return

    item_re = re.compile(rf"^\s*-\s*{re.escape(item)}\s*(?:#.*)?$")
    list_indent = None
    insert_at = child_index + 1
    while insert_at < section_end:
        line = lines[insert_at]
        if item_re.match(line):
            return
        list_match = re.match(r"^(\s*)-\s+", line)
        if list_match:
            list_indent = list_match.group(1)
            insert_at += 1
            continue
        if re.match(r"^\s*$", line) or re.match(r"^\s*#", line):
            insert_at += 1
            continue
        break
    if list_indent is None:
        list_indent = "    "
    lines.insert(insert_at, f"{list_indent}- {item}\n")

def remove_child_list_item(section: str, child: str, item: str):
    global lines
    section_index, section_end = section_bounds(section)
    if section_index is None:
        return

    child_index = None
    child_re = re.compile(rf"^  {re.escape(child)}:\s*(?:#.*)?$")
    for i in range(section_index + 1, section_end):
        if child_re.match(lines[i]):
            child_index = i
            break

    if child_index is None:
        return

    item_re = re.compile(rf"^\s*-\s*{re.escape(item)}\s*(?:#.*)?$")
    i = child_index + 1
    removed_any = False
    while i < section_end:
        line = lines[i]
        if item_re.match(line):
            del lines[i]
            section_end -= 1
            removed_any = True
            continue
        if re.match(r"^\s*-\s+", line) or re.match(r"^\s*$", line) or re.match(r"^\s*#", line):
            i += 1
            continue
        break

    if removed_any:
        has_items = False
        i = child_index + 1
        while i < section_end:
            line = lines[i]
            if re.match(r"^\s*-\s+", line):
                has_items = True
                break
            if re.match(r"^\s*$", line) or re.match(r"^\s*#", line):
                i += 1
                continue
            break
        if not has_items:
            lines[child_index] = f"  {child}: []\n"

def get_child_scalar(section: str, child: str):
    section_index, section_end = section_bounds(section)
    if section_index is None:
        return None
    child_re = re.compile(rf"^  {re.escape(child)}:\s*(.*?)\s*(?:#.*)?$")
    for i in range(section_index + 1, section_end):
        match = child_re.match(lines[i])
        if match:
            value = match.group(1).strip()
            # Strip surrounding quotes so the comparison below is value-based.
            if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
                value = value[1:-1]
            return value
    return None

def set_child_scalar(section: str, child: str, value: str):
    global lines
    new_line = f"  {child}: {value}\n"
    section_index, section_end = section_bounds(section)
    if section_index is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.extend([f"{section}:\n", new_line])
        return
    child_re = re.compile(rf"^  {re.escape(child)}:\s*(?:.*)$")
    for i in range(section_index + 1, section_end):
        if child_re.match(lines[i]):
            lines[i] = new_line
            return
    lines.insert(section_index + 1, new_line)

if Path(skills_dir).is_dir():
    ensure_child_list_item("skills", "external_dirs", skills_dir)
else:
    print(f"CI context: {skills_dir} not found; skill directory will be reconciled on next startup", file=sys.stderr)

ensure_child_list_item("plugins", "enabled", plugin_name)
remove_child_list_item("plugins", "disabled", plugin_name)

# ── Companion Memory auto-activation ──────────────────────────────────────────
# Only when credentials were injected at install time (memory_provider set), and
# only when the user has not selected a memory provider of their own. Hermes'
# default/unconfigured value is an empty string ("" == built-in only; see
# `hermes memory off`), and a provider is only written to config.yaml as a
# non-empty value by `hermes memory setup` (a deliberate user choice). So we
# select our provider when the current value is unset/empty (or already ours),
# and never override any other non-empty value — including on the first run
# after an upgrade. This mirrors CI-OpenClaw's guard.
if memory_provider:
    current_provider = get_child_scalar("memory", "provider")
    if current_provider in (None, "", memory_provider):
        # Make the bundled provider's plugin loadable and select it.
        ensure_child_list_item("plugins", "enabled", memory_provider)
        remove_child_list_item("plugins", "disabled", memory_provider)
        if current_provider != memory_provider:
            set_child_scalar("memory", "provider", memory_provider)
            print(f"CI context: selected '{memory_provider}' as active memory provider")

# ── Hub-saved cloud providers (additive) ─────────────────────────────────────
# Hub Settings → AI injects CI_CLOUD_* into .env.hub-bootstrap. Register each
# present provider so the GUI picker can offer OpenAI / Anthropic / Google /
# GitHub Copilot alongside local Ollama. Do not overwrite HERMES_OPENAI_* /
# model.provider — those stay on the local backend.
def read_dotenv(path: str) -> dict:
    env = {}
    p = Path(path) if path else None
    if not p or not p.is_file():
        return env
    for raw in p.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip("\r")
        if (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        env[key] = value
    return env

def env_get(key: str) -> str:
    return (hub_env.get(key) or os.environ.get(key) or "").strip()

def provider_span(provider_key: str):
    start, end = section_bounds("providers")
    if start is None:
        return None
    key_re = re.compile(rf"^  {re.escape(provider_key)}:\s*(?:.*)$")
    for i in range(start + 1, end):
        if key_re.match(lines[i]):
            j = i + 1
            while j < end and (lines[j].startswith("    ") or not lines[j].strip()):
                j += 1
            return i, j
    return None

def remove_provider_entry(provider_key: str) -> bool:
    span = provider_span(provider_key)
    if span is None:
        return False
    del lines[span[0]:span[1]]
    return True

def upsert_provider_entry(provider_key: str, name: str, base_url: str, api_key: str, model: str) -> bool:
    def _q(v: str) -> str:
        return v.replace("'", "''")

    block = [
        f"  {provider_key}:\n",
        f"    name: '{_q(name)}'\n",
    ]
    if base_url:
        block.append(f"    base_url: '{_q(base_url)}'\n")
    block.append(f"    api_key: '{_q(api_key)}'\n")
    if model:
        block.append(f"    model: '{_q(model)}'\n")

    span = provider_span(provider_key)
    if span is not None and lines[span[0]:span[1]] == block:
        return False
    if span is not None:
        del lines[span[0]:span[1]]

    idx = next((i for i, l in enumerate(lines) if re.match(r"^providers:", l)), None)
    if idx is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.append("providers:\n")
        lines.extend(block)
        return True
    if re.match(r"^providers:\s*(\{\s*\}|\[\s*\])\s*(?:#.*)?$", lines[idx]):
        lines[idx] = "providers:\n"
        lines[idx + 1:idx + 1] = block
        return True
    start, _end = section_bounds("providers")
    if start is None:
        return False
    lines[start + 1:start + 1] = block
    return True

hub_env = read_dotenv(hub_env_file)
CLOUD_SPECS = (
    ("openai", "OpenAI", "CI_CLOUD_OPENAI_API_KEY", "CI_CLOUD_OPENAI_BASE_URL", "CI_CLOUD_OPENAI_MODEL"),
    ("anthropic", "Anthropic", "CI_CLOUD_ANTHROPIC_API_KEY", "CI_CLOUD_ANTHROPIC_BASE_URL", "CI_CLOUD_ANTHROPIC_MODEL"),
    ("google", "Google", "CI_CLOUD_GOOGLE_API_KEY", "CI_CLOUD_GOOGLE_BASE_URL", "CI_CLOUD_GOOGLE_MODEL"),
    ("github-copilot", "GitHub Copilot", "CI_CLOUD_GITHUB_COPILOT_API_KEY", "CI_CLOUD_GITHUB_COPILOT_BASE_URL", "CI_CLOUD_GITHUB_COPILOT_MODEL"),
)
for _id, _name, _key, _base, _model in CLOUD_SPECS:
    _api_key = env_get(_key)
    if not _api_key:
        if remove_provider_entry(_id):
            print(f"CI context: removed providers.{_id} (Hub cloud key absent)")
        continue
    if upsert_provider_entry(_id, _name, env_get(_base), _api_key, env_get(_model)):
        print(f"CI context: registered providers.{_id} from Hub cloud token")

new_text = "".join(lines)
# Only write when something actually changed, so a fully-reconciled config is a
# true no-op (no needless mtime churn on every boot).
if new_text != text:
    # Atomic: Hermes may be reading config.yaml in the other container right now.
    _mode = config_path.stat().st_mode & 0o777
    _fd, _tmp = tempfile.mkstemp(dir=str(config_path.parent), prefix=".config.yaml.")
    with os.fdopen(_fd, "w", encoding="utf-8") as _fh:
        _fh.write(new_text)
    os.chmod(_tmp, _mode)
    os.replace(_tmp, config_path)
PY
else
  echo "CI context: ${CONFIG_FILE} not found yet; plugin and skill config will be reconciled on next startup" >&2
fi
