#!/bin/bash
# Gateway container entrypoint: apply managed CI context and then run
# Hermes in gateway mode.
set -euo pipefail

# CI_HERMES_APP_DIR / CI_HERMES_VENV exist so tests can run this entrypoint against a
# checkout and a fake hermes; the image never sets them.
APP_DIR="${CI_HERMES_APP_DIR:-/app}"
source "${CI_HERMES_VENV:-/opt/hermes/.venv}/bin/activate"

# Hub bootstrap first — config.yaml must exist before MCP configurators run.
"${APP_DIR}/bootstrap-from-hub.sh" || true

"${APP_DIR}/bootstrap-ci-context.sh"

# Export Hub-derived provider env through the same loader as the web container, so
# the gateway and the dashboard cannot resolve different endpoints or models from
# one handout. This loader used to skip CUSTOM_*, which left a cloud endpoint out
# of the gateway while the dashboard had it.
# shellcheck source=hub-env.sh
source "${APP_DIR}/hub-env.sh"
load_hub_env_file "${HERMES_HOME:-/opt/data}/.env.hub-bootstrap"

if [[ "$#" -eq 0 ]]; then
  set -- gateway run
fi

exec hermes "$@"
