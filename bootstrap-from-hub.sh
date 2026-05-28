#!/bin/bash
# Pull inference config from the Hub and translate Hub's HERMES_* env keys
# into the OPENAI_* env vars Hermes (and most agent frameworks it wraps) read.
#
# Idempotent and failure-tolerant: if the Hub is unreachable the script logs
# and exits 0 so container start still succeeds — Hermes will fall back to
# its own setup wizard for credentials.
#
# Inputs:
#   CI_HUB_URL       Base URL of the Hub backend  (default: http://ci-os-hub:3000)
#   HUB_APP_SLUG     App slug to bootstrap as     (default: hermes-agent)
#   HERMES_HOME      Hermes data dir              (default: /opt/data)
#   BOOTSTRAP_FIXTURE_FILE   For tests: read body from this file instead of curling
#
# Outputs:
#   $HERMES_HOME/.env.hub-bootstrap   sourced by start-hermes.sh
set -euo pipefail

CI_HUB_URL="${CI_HUB_URL:-http://ci-os-hub:3000}"
HUB_APP_SLUG="${HUB_APP_SLUG:-hermes-agent}"
DATA_DIR="${HERMES_HOME:-/opt/data}"
OUT_ENV="${DATA_DIR}/.env.hub-bootstrap"

log() {
  echo "[hub-bootstrap] $*"
}

fetch_bootstrap() {
  if [[ -n "${BOOTSTRAP_FIXTURE_FILE:-}" ]]; then
    cat "${BOOTSTRAP_FIXTURE_FILE}"
    return 0
  fi
  local url="${CI_HUB_URL}/api/inference/apps/${HUB_APP_SLUG}/bootstrap.env"
  curl --silent --show-error --fail --max-time 5 --retry 1 --retry-delay 2 "${url}"
}

translate_keys() {
  # stdin: HERMES_* and other env lines from Hub
  # stdout: OPENAI_* lines Hermes can read, plus the original keys preserved
  awk '
    BEGIN { FS="=" }
    /^HERMES_OPENAI_BASE_URL=/ { v=$0; sub(/^HERMES_OPENAI_BASE_URL=/, "OPENAI_API_BASE=", v); print v; sub(/^OPENAI_API_BASE=/, "OPENAI_BASE_URL=", v); print v; print; next }
    /^HERMES_OPENAI_API_KEY=/  { v=$0; sub(/^HERMES_OPENAI_API_KEY=/, "OPENAI_API_KEY=", v); print v; print; next }
    /^HERMES_DEFAULT_MODEL=/   { v=$0; sub(/^HERMES_DEFAULT_MODEL=/, "OPENAI_MODEL=", v); print v; print; next }
    /^HERMES_EMBEDDINGS_MODEL=/ { v=$0; sub(/^HERMES_EMBEDDINGS_MODEL=/, "OPENAI_EMBEDDINGS_MODEL=", v); print v; print; next }
    { print }
  '
}

main() {
  if [[ ! -d "${DATA_DIR}" ]]; then
    log "WARN: ${DATA_DIR} does not exist; skipping"
    exit 0
  fi

  log "fetching ${CI_HUB_URL} → slug=${HUB_APP_SLUG}"
  local body
  if ! body="$(fetch_bootstrap)"; then
    log "WARN: Hub unreachable or returned error; leaving Hermes provider config alone"
    exit 0
  fi

  if [[ -z "${body}" ]]; then
    log "WARN: empty response from Hub; nothing to apply"
    exit 0
  fi

  local tmp
  tmp="$(mktemp)"
  echo "${body}" | translate_keys > "${tmp}" || { rm -f "${tmp}"; log "ERROR: translate_keys failed"; exit 0; }

  mv "${tmp}" "${OUT_ENV}"
  chmod 600 "${OUT_ENV}" 2>/dev/null || true
  log "wrote ${OUT_ENV} ($(wc -l < "${OUT_ENV}" | tr -d ' ') lines)"
}

main "$@"
