#!/bin/sh
# Pull inference config from the Hub, write it to .env.hub-bootstrap, and make the
# Hub-managed part of config.yaml follow it (reconcile-hub-config.py).
#
# Idempotent and failure-tolerant: if the Hub is unreachable the script logs
# and exits 0 so container start still succeeds — Hermes will fall back to
# its own setup wizard for credentials.
#
# POSIX sh — no bashisms. Runs in any /bin/sh including dash.
#
# Inputs:
#   CI_HUB_URL       Base URL of the Hub backend  (default: http://ci-os-hub:5002)
#                    Falls back to HUB_URL when Hub injects MCP env at install time.
#   HUB_APP_SLUG     App slug to bootstrap as     (default: hermes-agent)
#   HERMES_HOME      Hermes data dir              (default: /opt/data)
#   BOOTSTRAP_FIXTURE_FILE   For tests: read body from this file instead of curling
#
# Outputs:
#   $HERMES_HOME/.env.hub-bootstrap   loaded by hub-env.sh / hub-env.cjs into every process
#   $HERMES_HOME/config.yaml          Hub-managed inference settings, via reconcile-hub-config.py
#
# config.yaml, not env, carries the model and (for the Hub's own endpoint) the
# endpoint. Upstream, env CUSTOM_BASE_URL outranks model.base_url and
# HERMES_INFERENCE_MODEL outranks model.default, and env is frozen into a process at
# exec — so exporting them made a corrected config.yaml invisible to the dashboard
# and gateway until both restarted, and let the two containers disagree. The env
# file therefore never carries those keys for a Hub endpoint config.yaml holds.
set -eu

CI_HUB_URL="${CI_HUB_URL:-${HUB_URL:-http://ci-os-hub:5002}}"
HUB_APP_SLUG="${HUB_APP_SLUG:-hermes-agent}"
DATA_DIR="${HERMES_HOME:-/opt/data}"
OUT_ENV="${DATA_DIR}/.env.hub-bootstrap"

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
RECONCILER="${SCRIPT_DIR}/reconcile-hub-config.py"

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
  # $1: is_local_ollama — "1" when the Hub endpoint is its own (api_key sentinel
  #     "ollama": direct Ollama or the pool proxy); "0"/empty for a cloud provider.
  #
  # stdin:  HERMES_* and other env lines from Hub
  # stdout: env lines Hermes can read, plus the original keys preserved.
  #
  # LOCAL endpoint: no aliases at all. reconcile-hub-config.py writes the endpoint
  # into config.yaml (providers.ollama, which `provider: ollama` resolves through, and
  # model.base_url, which env CUSTOM_BASE_URL would outrank on the generic path). The
  # OpenAI-SDK aliases are worse than unused there:
  # they make the upstream model picker treat the local endpoint as the generic
  # "openai-api" provider, which loses the Ollama num_ctx injection and points the
  # main model at api.openai.com after a GUI model switch.
  #
  # CLOUD provider: CUSTOM_* + OPENAI_* aliases, as before. The key never goes into
  # config.yaml, so the endpoint has to travel in env (host-gated key resolution).
  #
  # No model aliases in either case: config.yaml model.default is authoritative,
  # and HERMES_INFERENCE_MODEL would outrank it (OPENAI_MODEL is dead upstream).
  awk -v is_local="${1:-0}" '
    BEGIN { FS="=" }
    /^HERMES_OPENAI_BASE_URL=/ {
      if (is_local != "1") {
        v=$0; sub(/^HERMES_OPENAI_BASE_URL=/, "CUSTOM_BASE_URL=", v); print v
        a=$0; sub(/^HERMES_OPENAI_BASE_URL=/, "OPENAI_API_BASE=", a); print a
        b=$0; sub(/^HERMES_OPENAI_BASE_URL=/, "OPENAI_BASE_URL=", b); print b
      }
      print
      next
    }
    /^HERMES_OPENAI_API_KEY=/  {
      if (is_local != "1") {
        v=$0; sub(/^HERMES_OPENAI_API_KEY=/, "CUSTOM_API_KEY=", v); print v
        a=$0; sub(/^HERMES_OPENAI_API_KEY=/, "OPENAI_API_KEY=", a); print a
      }
      print
      next
    }
    /^HERMES_EMBEDDINGS_MODEL=/ { v=$0; sub(/^HERMES_EMBEDDINGS_MODEL=/, "OPENAI_EMBEDDINGS_MODEL=", v); print v; print; next }
    { print }
  '
}

sanitize_env() {
  # $1: is_local_ollama, as for translate_keys.
  #
  # Drops the keys config.yaml owns, whatever wrote them: a Hub that sends one
  # directly, or an env file an older image wrote (the Hub-unreachable path reuses
  # it). Mirrors HUB_ENV_CONFIG_OWNED_KEYS / HUB_ENV_LOCAL_ENDPOINT_KEYS in
  # hub-env.sh, which applies the same rule again when the file is loaded.
  awk -v is_local="${1:-0}" '
    /^(HERMES_INFERENCE_MODEL|HERMES_MODEL|OPENAI_MODEL)=/ { next }
    is_local == "1" && /^(CUSTOM_BASE_URL|CUSTOM_API_KEY|OPENAI_BASE_URL|OPENAI_API_BASE|OPENAI_API_KEY)=/ { next }
    { print }
  '
}

is_local_env() {
  # stdin: env lines. Prints 1 when HERMES_OPENAI_API_KEY is the local sentinel.
  key="$(grep -m1 '^HERMES_OPENAI_API_KEY=' | cut -d= -f2- || true)"
  key="$(normalize_env_value "${key}")"
  if [ "${key}" = "ollama" ]; then echo 1; else echo 0; fi
}

reconcile_config() {
  # config.yaml follows the handout on EVERY start, not only when first generated.
  # Failure never blocks the container: Hermes keeps its previous settings, loudly.
  if ! command -v python3 >/dev/null 2>&1; then
    log "ERROR: python3 not found; config.yaml cannot follow the Hub handout"
    return 0
  fi
  python3 "${RECONCILER}" --data-dir "${DATA_DIR}" \
    || log "ERROR: config.yaml reconcile failed; Hermes keeps its previous inference settings"
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

yaml_single_quote() {
  # YAML single-quoted scalar escaping: single quote is represented as two quotes.
  printf "%s" "$1" | sed "s/'/''/g"
}

normalize_env_value() {
  # Strip CR from CRLF files and one matching pair of surrounding quotes.
  value="$1"
  cr_char="$(printf '\r')"
  dq='"'
  sq="'"
  value="${value%${cr_char}}"

  if [ "${value#"${dq}"}" != "${value}" ] && [ "${value%"${dq}"}" != "${value}" ]; then
    value="${value#"${dq}"}"
    value="${value%"${dq}"}"
  elif [ "${value#"${sq}"}" != "${value}" ] && [ "${value%"${sq}"}" != "${value}" ]; then
    value="${value#"${sq}"}"
    value="${value%"${sq}"}"
  fi

  printf '%s' "${value}"
}

main() {
  if [ ! -d "${DATA_DIR}" ]; then
    log "WARN: ${DATA_DIR} does not exist; skipping"
    exit 0
  fi

  log "fetching ${CI_HUB_URL} -> slug=${HUB_APP_SLUG}"
  body=""
  if ! body="$(fetch_bootstrap)" || [ -z "${body}" ]; then
    log "WARN: Hub unreachable, errored or returned an empty handout; keeping the last one"
    # Still converge on the last handout we have: an env file an older image wrote
    # carries the env overrides this version no longer exports, and its config.yaml
    # may never have been reconciled at all.
    if [ -f "${OUT_ENV}" ]; then
      tmp="$(mktemp "${OUT_ENV}.XXXXXX")"
      if sanitize_env "$(is_local_env < "${OUT_ENV}")" < "${OUT_ENV}" > "${tmp}"; then
        if cmp -s "${tmp}" "${OUT_ENV}"; then
          rm -f "${tmp}"
        else
          chmod 600 "${tmp}" 2>/dev/null || true
          mv "${tmp}" "${OUT_ENV}"
          log "removed config-owned overrides from the existing ${OUT_ENV}"
        fi
      else
        rm -f "${tmp}"
      fi
      reconcile_config
    fi
    exit 0
  fi

  # Detect the Hub's own endpoint (api_key sentinel "ollama") vs a cloud provider:
  # only a cloud provider's endpoint travels in env.
  is_local_ollama="$(printf '%s\n' "${body}" | is_local_env)"

  # Temp files live beside the output so the final mv is an atomic rename: the web
  # and gateway containers share this directory and start together.
  tmp="$(mktemp "${OUT_ENV}.XXXXXX")"
  if ! printf '%s\n' "${body}" | translate_keys "${is_local_ollama}" | sanitize_env "${is_local_ollama}" > "${tmp}"; then
    rm -f "${tmp}"
    log "ERROR: translate_keys failed"
    exit 0
  fi

  gateway_ip="$(detect_docker_gateway_ip || true)"
  if [ -n "${gateway_ip}" ]; then
    tmp2="$(mktemp "${OUT_ENV}.XXXXXX")"
    if rewrite_host_docker_internal "${tmp}" "${gateway_ip}" > "${tmp2}"; then
      mv "${tmp2}" "${tmp}"
      log "normalized host.docker.internal -> ${gateway_ip}"
    else
      rm -f "${tmp2}"
      log "WARN: failed to normalize host.docker.internal values"
    fi
  fi

  chmod 600 "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${OUT_ENV}"
  log "wrote ${OUT_ENV} ($(wc -l < "${OUT_ENV}" | tr -d ' ') lines)"

  reconcile_config
}

main "$@"
