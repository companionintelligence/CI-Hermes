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
# Marker recording that we have auto-selected the provider at least once. After
# the first activation we stop overriding a provider the user later chose by
# hand (see the config.yaml reconcile below).
CI_MEMORY_MARKER="${DATA_DIR}/companionintelligence/.ci-auto-activated"

# Activate the bundled provider only when both credentials are present, matching
# the memory plugin's own is_available() check (URL + token required). An
# explicit CI_SERVER_ENABLED=false is honoured as an off-switch (mirrors
# CI-OpenClaw); any other value (or unset) leaves activation gated on the creds.
# Normalize the flag the same way configure-ci-server.py does — trim whitespace
# and lowercase — so FALSE / "false " also disable it.
ci_enabled_norm="$(printf '%s' "${CI_SERVER_ENABLED:-true}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
if [[ -n "${CI_SERVER_URL:-}" && -n "${CI_SERVER_TOKEN:-}" \
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

# Run the CI-Server configurator (MCP registration when credentials are present).
# Uses CI_SERVER_URL / CI_SERVER_TOKEN / CI_SERVER_ENABLED from the environment.
python3 /app/configure-ci-server.py 2>&1 || true

if [[ -f "${CONFIG_FILE}" ]]; then
  python3 - "${CONFIG_FILE}" "${SKILLS_SOURCE}" "${PLUGIN_NAME}" "${CI_MEMORY_PROVIDER}" "${CI_MEMORY_MARKER}" <<'PY'
import os
from pathlib import Path
import re
import sys

config_path = Path(sys.argv[1])
skills_dir = sys.argv[2]
plugin_name = sys.argv[3]
memory_provider = sys.argv[4] if len(sys.argv) > 4 else ""
memory_marker = sys.argv[5] if len(sys.argv) > 5 else ""

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
# Only when credentials were injected at install time (memory_provider set).
if memory_provider:
    # Make the bundled provider's plugin loadable.
    ensure_child_list_item("plugins", "enabled", memory_provider)
    remove_child_list_item("plugins", "disabled", memory_provider)

    # Select it as the active memory provider. The first automated activation
    # (no marker yet) wins and overrides Hermes' generated default; after that
    # we only re-assert when the provider is still ours or unset, so a provider
    # the user later picked with `hermes memory setup` is never clobbered.
    already_activated = bool(memory_marker) and os.path.exists(memory_marker)
    current_provider = get_child_scalar("memory", "provider")
    if (not already_activated) or current_provider in (None, "", memory_provider):
        if current_provider != memory_provider:
            set_child_scalar("memory", "provider", memory_provider)
            print(f"CI context: selected '{memory_provider}' as active memory provider")

new_text = "".join(lines)
config_path.write_text(new_text, encoding="utf-8")
PY

  # Record that auto-activation has run at least once (used by the guard above
  # on subsequent boots). Best-effort; never fail startup over the marker.
  if [[ -n "${CI_MEMORY_PROVIDER}" ]]; then
    mkdir -p "$(dirname "${CI_MEMORY_MARKER}")"
    : > "${CI_MEMORY_MARKER}" 2>/dev/null || true
  fi
else
  echo "CI context: ${CONFIG_FILE} not found yet; plugin and skill config will be reconciled on next startup" >&2
fi
