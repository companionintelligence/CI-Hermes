#!/bin/bash
# Terminal entrypoint: enable managed CI context, run setup only when
# Hermes' own runtime provider resolver cannot find usable credentials, then
# start chat and leave users in a shell for follow-up admin commands.

set -euo pipefail

/app/bootstrap-ci-context.sh

# Refresh Hub-derived model/provider credentials for each terminal session.
/app/bootstrap-from-hub.sh

HUB_ENV_FILE="${HERMES_HOME:-/opt/data}/.env.hub-bootstrap"
if [[ -f "${HUB_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${HUB_ENV_FILE}"
  set +a
fi

if ! python3 - <<'PY' 2>/dev/null; then
from dotenv import load_dotenv
from hermes_cli.runtime_provider import resolve_runtime_provider

load_dotenv("/opt/data/.env")
load_dotenv("/opt/data/.env.hub-bootstrap")
resolve_runtime_provider()
PY
  hermes setup
fi

/app/bootstrap-ci-context.sh

hermes

exec bash
