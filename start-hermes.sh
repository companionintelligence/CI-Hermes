#!/bin/bash
# Terminal entrypoint: enable managed CI context, run setup only when
# Hermes' own runtime provider resolver cannot find usable credentials, then
# start chat and leave users in a shell for follow-up admin commands.

set -euo pipefail

# shellcheck source=hub-env.sh
source /app/hub-env.sh

/app/bootstrap-ci-context.sh

# Refresh Hub-derived model/provider credentials for each terminal session.
/app/bootstrap-from-hub.sh

DATA_DIR="${HERMES_HOME:-/opt/data}"
HUB_ENV_FILE="${DATA_DIR}/.env.hub-bootstrap"
load_hub_env_file "${HUB_ENV_FILE}"

# The handout reached config.yaml above; if the Hub handed out a model Hermes cannot
# start (below its 64K minimum), say so where the user is looking.
HUB_WARNING_FILE="${DATA_DIR}/.hub-inference-warning"
if [[ -s "${HUB_WARNING_FILE}" ]]; then
  printf '\n\033[1;31m%s\033[0m\n%s\n\n' "Hub inference settings need attention:" "$(cat "${HUB_WARNING_FILE}")"
fi

# Probe with exactly the environment `hermes` gets below. Loading
# .env.hub-bootstrap again here would re-add keys the loader deliberately leaves to
# config.yaml, and judge a setup the real session never sees.
if ! python3 - <<'PY' 2>/dev/null; then
import os
from dotenv import load_dotenv
from hermes_cli.runtime_provider import resolve_runtime_provider

data_dir = os.environ.get("HERMES_HOME", "/opt/data")
load_dotenv(f"{data_dir}/.env")
resolve_runtime_provider()
PY
  hermes setup
fi

/app/bootstrap-ci-context.sh

hermes

exec bash
