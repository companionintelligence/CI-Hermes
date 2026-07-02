#!/bin/bash
# Start the web container: enable managed CI context, run the Hermes
# dashboard locally, then serve the proxied terminal/dashboard UI.
set -e

source "/opt/hermes/.venv/bin/activate"

# Pull inference config from the Hub first so config.yaml exists before MCP
# configurators run (bootstrap-from-hub.sh generates config.yaml on first boot).
/app/bootstrap-from-hub.sh || true

/app/bootstrap-ci-context.sh

# Source the Hub-derived env so OPENAI_API_BASE / OPENAI_MODEL reach the
# dashboard and the Node server before they spawn agent subprocesses.
HUB_ENV_FILE="${HERMES_HOME:-/opt/data}/.env.hub-bootstrap"
if [[ -f "${HUB_ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${HUB_ENV_FILE}"
  set +a
fi

# Start dashboard in background.
# Binds to 127.0.0.1 (not 0.0.0.0) since our Node server proxies it — no
# direct external access needed, and avoids the "Binding to 0.0.0.0" warning.
# If it crashes, the terminal still works — user can restart the app from CI marketplace.
hermes dashboard --host 127.0.0.1 --no-open &

exec node /app/server.cjs
