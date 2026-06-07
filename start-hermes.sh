#!/bin/bash
# Terminal entrypoint: enable managed CI context, run setup only when
# Hermes' own runtime provider resolver cannot find usable credentials, then
# start chat and leave users in a shell for follow-up admin commands.

set -euo pipefail

is_allowed_key() {
  case "$1" in
    OPENAI_*|HERMES_*|CUSTOM_*|ANTHROPIC_*|GEMINI_*|GOOGLE_*|OLLAMA_*) return 0 ;;
    *) return 1 ;;
  esac
}

load_hub_env_file() {
  local env_file="$1"
  [[ -f "${env_file}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

    if [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"

      is_allowed_key "${key}" || continue

      if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
        value="${BASH_REMATCH[1]}"
      elif [[ "${value}" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi

      export "${key}=${value}"
    fi
  done < "${env_file}"
}

/app/bootstrap-ci-context.sh

# Refresh Hub-derived model/provider credentials for each terminal session.
/app/bootstrap-from-hub.sh

DATA_DIR="${HERMES_HOME:-/opt/data}"
HUB_ENV_FILE="${DATA_DIR}/.env.hub-bootstrap"
load_hub_env_file "${HUB_ENV_FILE}"

if ! python3 - <<'PY' 2>/dev/null; then
import os
from dotenv import load_dotenv
from hermes_cli.runtime_provider import resolve_runtime_provider

data_dir = os.environ.get("HERMES_HOME", "/opt/data")
load_dotenv(f"{data_dir}/.env")
load_dotenv(f"{data_dir}/.env.hub-bootstrap")
resolve_runtime_provider()
PY
  hermes setup
fi

/app/bootstrap-ci-context.sh

hermes

exec bash
