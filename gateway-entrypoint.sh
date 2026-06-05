#!/bin/bash
# Gateway container entrypoint: apply managed CI context and then run
# Hermes in gateway mode.
set -e

source "/opt/hermes/.venv/bin/activate"

/app/bootstrap-ci-context.sh

# Pull inference config from the Hub (idempotent; safe if Hub is unreachable).
/app/bootstrap-from-hub.sh

# Export Hub-derived provider env values before launching Hermes.
HUB_ENV_FILE="${HERMES_HOME:-/opt/data}/.env.hub-bootstrap"
if [[ -f "${HUB_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${HUB_ENV_FILE}"
  set +a
fi

if [[ "$#" -eq 0 ]]; then
  set -- gateway run
fi

exec hermes "$@"