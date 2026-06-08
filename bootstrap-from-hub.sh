#!/bin/sh
# Pull inference config from the Hub and translate Hub's HERMES_* env keys
# into the OPENAI_* env vars Hermes (and most agent frameworks it wraps) read.
#
# Idempotent and failure-tolerant: if the Hub is unreachable the script logs
# and exits 0 so container start still succeeds — Hermes will fall back to
# its own setup wizard for credentials.
#
# POSIX sh — no bashisms. Runs in any /bin/sh including dash.
#
# Inputs:
#   CI_HUB_URL       Base URL of the Hub backend  (default: http://ci-os-hub:5002)
#   HUB_APP_SLUG     App slug to bootstrap as     (default: hermes-agent)
#   HERMES_HOME      Hermes data dir              (default: /opt/data)
#   BOOTSTRAP_FIXTURE_FILE   For tests: read body from this file instead of curling
#
# Outputs:
#   $HERMES_HOME/.env.hub-bootstrap   sourced by start-hermes.sh
set -eu

CI_HUB_URL="${CI_HUB_URL:-http://ci-os-hub:5002}"
HUB_APP_SLUG="${HUB_APP_SLUG:-hermes-agent}"
DATA_DIR="${HERMES_HOME:-/opt/data}"
OUT_ENV="${DATA_DIR}/.env.hub-bootstrap"

log() {
  echo "[hub-bootstrap] $*"
}

fetch_bootstrap() {
  if [ -n "${BOOTSTRAP_FIXTURE_FILE:-}" ]; then
    cat "${BOOTSTRAP_FIXTURE_FILE}"
    return 0
  fi
  url="${CI_HUB_URL}/api/inference/apps/${HUB_APP_SLUG}/credentials.env"
  curl --silent --show-error --fail --max-time 5 --retry 1 --retry-delay 2 "${url}"
}

translate_keys() {
  # stdin: HERMES_* and other env lines from Hub
  # stdout: OPENAI_* lines Hermes can read, plus the original keys preserved
  awk '
    BEGIN { FS="="; emitted_model_aliases=0 }
    /^HERMES_OPENAI_BASE_URL=/ {
      v=$0
      sub(/^HERMES_OPENAI_BASE_URL=/, "OPENAI_API_BASE=", v); print v
      sub(/^OPENAI_API_BASE=/, "OPENAI_BASE_URL=", v); print v
      sub(/^OPENAI_BASE_URL=/, "CUSTOM_BASE_URL=", v); print v
      print
      next
    }
    /^HERMES_OPENAI_API_KEY=/  {
      v=$0
      sub(/^HERMES_OPENAI_API_KEY=/, "OPENAI_API_KEY=", v); print v
      sub(/^OPENAI_API_KEY=/, "CUSTOM_API_KEY=", v); print v
      print
      next
    }
    /^HERMES_DEFAULT_MODEL=/   {
      v=$0
      sub(/^HERMES_DEFAULT_MODEL=/, "OPENAI_MODEL=", v); print v
      sub(/^OPENAI_MODEL=/, "HERMES_INFERENCE_MODEL=", v); print v
      emitted_model_aliases=1
      print
      next
    }
    /^HERMES_DEFAULT_MODEL_BACKEND_ID=/ {
      if (!emitted_model_aliases) {
        v=$0
        sub(/^HERMES_DEFAULT_MODEL_BACKEND_ID=/, "OPENAI_MODEL=", v); print v
        sub(/^OPENAI_MODEL=/, "HERMES_INFERENCE_MODEL=", v); print v
        emitted_model_aliases=1
      }
      print
      next
    }
    /^HERMES_EMBEDDINGS_MODEL=/ { v=$0; sub(/^HERMES_EMBEDDINGS_MODEL=/, "OPENAI_EMBEDDINGS_MODEL=", v); print v; print; next }
    { print }
  '
}

detect_docker_gateway_ip() {
  # Allow tests/operators to force a known gateway IP.
  if [ -n "${DOCKER_HOST_GATEWAY_IP:-}" ]; then
    printf '%s\n' "${DOCKER_HOST_GATEWAY_IP}"
    return 0
  fi

  # Linux containers can usually reach the host via the default route gateway.
  # If detection fails, return empty and keep values unchanged.
  ip route 2>/dev/null | awk '/^default[[:space:]]/ { print $3; exit }'
}

rewrite_host_docker_internal() {
  file_path="$1"
  gateway_ip="$2"

  if [ -z "${gateway_ip}" ]; then
    return 0
  fi

  # Escape sed replacement metacharacters so operator/test overrides containing
  # '&', '\\', or '/' remain literal.
  escaped_gateway_ip="$(
    printf '%s' "${gateway_ip}" |
    sed 's/\\/\\\\/g' |
    sed 's/&/\\\&/g' |
    sed 's#/#\\/#g'
  )"

  # Replace only the docker-host alias token, preserving URL scheme/port/path.
  sed "s/host\.docker\.internal/${escaped_gateway_ip}/g" "${file_path}"
}

main() {
  if [ ! -d "${DATA_DIR}" ]; then
    log "WARN: ${DATA_DIR} does not exist; skipping"
    exit 0
  fi

  log "fetching ${CI_HUB_URL} -> slug=${HUB_APP_SLUG}"
  if ! body="$(fetch_bootstrap)"; then
    log "WARN: Hub unreachable or returned error; leaving Hermes provider config alone"
    exit 0
  fi

  if [ -z "${body}" ]; then
    log "WARN: empty response from Hub; nothing to apply"
    exit 0
  fi

  tmp="$(mktemp)"
  if ! printf '%s\n' "${body}" | translate_keys > "${tmp}"; then
    rm -f "${tmp}"
    log "ERROR: translate_keys failed"
    exit 0
  fi

  gateway_ip="$(detect_docker_gateway_ip || true)"
  if [ -n "${gateway_ip}" ]; then
    tmp2="$(mktemp)"
    if rewrite_host_docker_internal "${tmp}" "${gateway_ip}" > "${tmp2}"; then
      mv "${tmp2}" "${tmp}"
      log "normalized host.docker.internal -> ${gateway_ip}"
    else
      rm -f "${tmp2}"
      log "WARN: failed to normalize host.docker.internal values"
    fi
  fi

  mv "${tmp}" "${OUT_ENV}"
  chmod 600 "${OUT_ENV}" 2>/dev/null || true
  log "wrote ${OUT_ENV} ($(wc -l < "${OUT_ENV}" | tr -d ' ') lines)"

  # Also write minimal config.yaml with model provider set, so Hermes recognizes
  # that a provider is configured when it starts. This is required for -z oneshot
  # and interactive chat to work with custom OpenAI-compatible endpoints.
  OUT_CONFIG="${DATA_DIR}/config.yaml"
  if grep -q "^HERMES_DEFAULT_MODEL=" "${OUT_ENV}" || grep -q "^HERMES_DEFAULT_MODEL_BACKEND_ID=" "${OUT_ENV}"; then
    # Extract model name from env file (prefer HERMES_DEFAULT_MODEL)
    model_name=$(grep "^HERMES_DEFAULT_MODEL=" "${OUT_ENV}" | cut -d= -f2- | head -1)
    [ -z "${model_name}" ] && model_name=$(grep "^HERMES_DEFAULT_MODEL_BACKEND_ID=" "${OUT_ENV}" | cut -d= -f2- | head -1)
    
    if [ -n "${model_name}" ]; then
      # Only write config.yaml if it doesn't exist or is empty
      # This ensures user's manual config.yaml is not overwritten
      if [ ! -s "${OUT_CONFIG}" ]; then
        cat > "${OUT_CONFIG}" <<EOF
model:
  provider: ollama
  default: ${model_name}
EOF
        chmod 600 "${OUT_CONFIG}" 2>/dev/null || true
        log "wrote ${OUT_CONFIG} with provider=ollama"
      else
        log "config.yaml already exists; skipping generation"
      fi
    fi
  fi
}

main "$@"
