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

# Run the CI-Server configurator (MCP registration when credentials are present).
# Uses CI_SERVER_URL / CI_SERVER_TOKEN / CI_SERVER_ENABLED from the environment.
python3 /app/configure-ci-server.py 2>&1 || true

# Hardware-aware context window the Hub computed for this machine and wrote into
# .env.hub-bootstrap as HERMES_NUM_CTX. The upstream hermes-agent reads
# model.ollama_num_ctx (NOT num_ctx) and injects it as extra_body.options.num_ctx
# on every chat request; a value under the wrong key is silently ignored and Ollama
# falls back to its tiny 4096 default. bootstrap-from-hub.sh only stamps this key
# when it FIRST generates config.yaml; once the file exists it skips ("config.yaml
# already exists; skipping generation"), so a config created before this value
# existed — or a value that later changes — would keep Ollama's default. Reconcile
# model.ollama_num_ctx on every boot (and migrate the legacy, never-read num_ctx key
# off existing configs), mirroring how CI-OpenClaw re-patches its config. We also pin
# model.context_length to the same value so the agent's working window matches the KV
# cache Ollama allocates — but ONLY when it clears Hermes' 64K minimum, since the
# agent fatally rejects a smaller context_length at startup (the Hub floors
# hermes-agent to 64K; the guard protects against older Hubs / sub-64K models, where
# auto-detection keeps Hermes bootable).
HUB_ENV_FILE="${DATA_DIR}/.env.hub-bootstrap"
ci_num_ctx=""
if [[ -f "${HUB_ENV_FILE}" ]]; then
  # `|| true`: under `set -euo pipefail` a no-match grep (exit 1) would otherwise
  # fail the pipeline and abort the whole bootstrap when the key is simply absent.
  ci_num_ctx="$(grep -m1 '^HERMES_NUM_CTX=' "${HUB_ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
fi
# Fall back to the process env in case the value is exported rather than file-only.
[[ -z "${ci_num_ctx}" ]] && ci_num_ctx="${HERMES_NUM_CTX:-}"
# Normalize: strip whitespace, a stray CR (CRLF env files), and surrounding quotes
# (a PyYAML/dotenv re-dump may emit HERMES_NUM_CTX="65536"). The value is numeric,
# so deleting all of these characters is equivalent to a strip.
ci_num_ctx="$(printf '%s' "${ci_num_ctx}" | tr -d "[:space:]\"'")"
# Only a POSITIVE integer is a meaningful context window; treat 0 / garbage as unset.
if ! printf '%s' "${ci_num_ctx}" | grep -qE '^[1-9][0-9]*$'; then
  ci_num_ctx=""
fi

# The main inference endpoint the Hub configured, so we can point auxiliary
# side-tasks (compression/title/vision/…) at the SAME endpoint. Without this,
# Hermes' aux auto-detect only tries cloud providers and resolves to nothing on a
# local-only appliance, so those tasks silently don't run. See the Python block.
strip_qcr() { printf '%s' "$1" | tr -d "\r" | sed -e "s/^[\"']//" -e "s/[\"']\$//"; }
aux_base=""; aux_key=""; aux_model=""
if [[ -f "${HUB_ENV_FILE}" ]]; then
  aux_base="$(grep -m1 '^HERMES_OPENAI_BASE_URL=' "${HUB_ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
  aux_key="$(grep -m1 '^HERMES_OPENAI_API_KEY=' "${HUB_ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
  aux_model="$(grep -m1 '^HERMES_DEFAULT_MODEL=' "${HUB_ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
fi
aux_base="$(strip_qcr "${aux_base}")"
aux_key="$(strip_qcr "${aux_key}")"
aux_model="$(strip_qcr "${aux_model}")"
# Gate (mirrors bootstrap-from-hub.sh): only wire aux to the local endpoint when
# native mode is enabled AND this is the local Ollama endpoint (api_key sentinel
# "ollama"). Clearing aux_base makes the Python block a no-op. This keeps flag-off a
# true no-op and never writes a cloud API key into config.yaml.
ci_native_lc="$(printf '%s' "${CI_HERMES_OLLAMA_NATIVE:-}" | tr '[:upper:]' '[:lower:]')"
case "${ci_native_lc}" in 1|true|yes|on) : ;; *) aux_base="" ;; esac
[[ "${aux_key}" == "ollama" ]] || aux_base=""

if [[ -f "${CONFIG_FILE}" ]]; then
  python3 - "${CONFIG_FILE}" "${SKILLS_SOURCE}" "${PLUGIN_NAME}" "${CI_MEMORY_PROVIDER}" "${ci_num_ctx}" "${aux_base}" "${aux_model}" <<'PY'
from pathlib import Path
import re
import sys

config_path = Path(sys.argv[1])
skills_dir = sys.argv[2]
plugin_name = sys.argv[3]
memory_provider = sys.argv[4] if len(sys.argv) > 4 else ""
num_ctx = sys.argv[5] if len(sys.argv) > 5 else ""
aux_base = sys.argv[6] if len(sys.argv) > 6 else ""
aux_model = sys.argv[7] if len(sys.argv) > 7 else ""

# Hermes' hard minimum context window. Mirrors the upstream agent's
# MINIMUM_CONTEXT_LENGTH, which is the literal 64000 (NOT 65536) and is compared
# with a strict `<`, so a context_length of exactly 64000 is accepted.
HERMES_MIN_CONTEXT = 64000

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

def delete_child_scalar(section: str, child: str) -> bool:
    """Remove ALL `  child: value` scalar lines from a section. Returns True if any
    were removed. Removing every occurrence (not just the first) means a config that
    already carried duplicates — from manual edits or an earlier reconcile bug —
    doesn't keep a stale copy that a later read could pick up."""
    global lines
    section_index, section_end = section_bounds(section)
    if section_index is None:
        return False
    child_re = re.compile(rf"^  {re.escape(child)}:\s*(?:.*)$")
    removed = False
    i = section_index + 1
    while i < section_end:
        if child_re.match(lines[i]):
            del lines[i]
            section_end -= 1
            removed = True
            continue
        i += 1
    return removed

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

# ── Hub-managed context window ────────────────────────────────────────────────
# Reconcile model.ollama_num_ctx every boot (see the shell preamble for why a write
# that only happens at config generation is not enough, and why ollama_num_ctx — not
# num_ctx — is the key the upstream agent reads). Only touch an existing model
# section so we never create a provider-less stub — bootstrap-from-hub.sh owns
# generating that section on first boot. Skip the write when the value is already
# correct so repeated runs stay byte-identical (idempotent).
if num_ctx:
    model_start, _ = section_bounds("model")
    if model_start is None:
        print(
            "CI context: no model section yet; ollama_num_ctx will be reconciled on next startup",
            file=sys.stderr,
        )
    else:
        # Migrate the legacy, never-read `num_ctx` key off existing configs so an
        # appliance bootstrapped before this fix stops carrying a dead key.
        if delete_child_scalar("model", "num_ctx"):
            print("CI context: removed stale model.num_ctx (upstream reads ollama_num_ctx)")
        if get_child_scalar("model", "ollama_num_ctx") != num_ctx:
            set_child_scalar("model", "ollama_num_ctx", num_ctx)
            print(f"CI context: set model.ollama_num_ctx={num_ctx}")
        # Pin context_length to the same value so the agent's working window matches
        # the KV cache — but only when it clears HERMES_MIN_CONTEXT (below that the
        # agent aborts at startup). context_length is fully Hub-managed: when the
        # value drops below the minimum (e.g. a downgrade to smaller hardware) we
        # REMOVE it so the agent falls back to auto-detecting the model's true window,
        # matching the "<min → context_length unset" contract.
        if int(num_ctx) >= HERMES_MIN_CONTEXT:
            if get_child_scalar("model", "context_length") != num_ctx:
                set_child_scalar("model", "context_length", num_ctx)
                print(f"CI context: set model.context_length={num_ctx}")
        elif delete_child_scalar("model", "context_length"):
            print("CI context: removed model.context_length (Hub value below minimum; auto-detect)")

# ── Hub-managed auxiliary providers ───────────────────────────────────────────
# Point side-tasks (compression/title/vision/…) at the SAME endpoint as the main
# model. Hermes' aux auto-detect chain only tries cloud providers (OpenRouter/Nous/
# api-key) and resolves to NOTHING on a local-only appliance — so compression/title
# silently don't run (middle turns dropped without a summary). An explicit
# base_url+api_key per task forces the "custom" path to the local endpoint (and lets
# the native /api/chat adapter take over when CI_HERMES_OLLAMA_NATIVE is on). Only
# add when there is no `auxiliary:` section yet — never clobber a user's own config.
if aux_base:
    # Detect an existing auxiliary section in ANY form (block `auxiliary:` or inline
    # `auxiliary: {...}` from a PyYAML re-dump) so we never append a duplicate
    # top-level key, and never clobber a user's own auxiliary config.
    has_aux = any(re.match(r"^auxiliary:", ln) for ln in lines)
    if not has_aux:
        def _yq(v: str) -> str:
            return v.replace("'", "''")  # YAML single-quote escaping
        block = ["auxiliary:\n"]
        for _t in ("compression", "title_generation", "vision", "web_extract", "session_search", "skills_hub", "mcp"):
            block.append(f"  {_t}:\n")
            block.append(f"    base_url: '{_yq(aux_base)}'\n")
            block.append("    api_key: 'ollama'\n")
            if aux_model:
                block.append(f"    model: '{_yq(aux_model)}'\n")
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.extend(block)
        print(f"CI context: added auxiliary providers (side-tasks -> {aux_base})")

new_text = "".join(lines)
# Only write when something actually changed, so a fully-reconciled config is a
# true no-op (no needless mtime churn on every boot).
if new_text != text:
    config_path.write_text(new_text, encoding="utf-8")
PY
else
  echo "CI context: ${CONFIG_FILE} not found yet; plugin and skill config will be reconciled on next startup" >&2
fi
