#!/bin/bash
# Start the web container: enable managed CI context, run the Hermes
# dashboard locally, then serve the proxied terminal/dashboard UI.
set -e

# CI_HERMES_APP_DIR / CI_HERMES_VENV exist so tests can run this entrypoint against a
# checkout and a fake hermes; the image never sets them.
APP_DIR="${CI_HERMES_APP_DIR:-/app}"
source "${CI_HERMES_VENV:-/opt/hermes/.venv}/bin/activate"

# Pull inference config from the Hub first: it writes .env.hub-bootstrap and makes
# config.yaml follow the handout (generating it on first boot) before the MCP
# configurators run.
"${APP_DIR}/bootstrap-from-hub.sh" || true

"${APP_DIR}/bootstrap-ci-context.sh"

# Export the Hub-derived env before the dashboard and the Node server start. The
# gateway container loads the same file through the same loader, so both run the
# model and endpoint config.yaml names — nothing in env outranks it (hub-env.sh).
# shellcheck source=hub-env.sh
source "${APP_DIR}/hub-env.sh"
load_hub_env_file "${HERMES_HOME:-/opt/data}/.env.hub-bootstrap"

# Start dashboard in background.
# Binds to 127.0.0.1 (not 0.0.0.0) since our Node server proxies it — no
# direct external access needed, and avoids the "Binding to 0.0.0.0" warning.
# If it crashes, the terminal still works — user can restart the app from CI marketplace.
hermes dashboard --host 127.0.0.1 --no-open &

exec node "${APP_DIR}/server.cjs"
