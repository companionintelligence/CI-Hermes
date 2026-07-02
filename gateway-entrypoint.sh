#!/bin/bash
# Gateway container entrypoint: apply managed CI context and then run
# Hermes in gateway mode.
set -euo pipefail

source "/opt/hermes/.venv/bin/activate"

# Hub bootstrap first — config.yaml must exist before MCP configurators run.
/app/bootstrap-from-hub.sh || true

/app/bootstrap-ci-context.sh

# Export Hub-derived provider env values before launching Hermes.
HUB_ENV_FILE="${HERMES_HOME:-/opt/data}/.env.hub-bootstrap"
if [[ -f "${HUB_ENV_FILE}" ]]; then
  is_allowed_key() {
    case "$1" in
      OPENAI_*|ANTHROPIC_*|GEMINI_*|GOOGLE_*|OLLAMA_*|HERMES_*) return 0 ;;
      *) return 1 ;;
    esac
  }

  # Parse KEY=VALUE pairs without executing file contents as shell code.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"

      is_allowed_key "$key" || continue

      if [[ "$value" =~ ^\"(.*)\"$ ]]; then
        value="${BASH_REMATCH[1]}"
      elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi

      export "$key=$value"
    fi
  done < "${HUB_ENV_FILE}"
fi

if [[ "$#" -eq 0 ]]; then
  set -- gateway run
fi

exec hermes "$@"