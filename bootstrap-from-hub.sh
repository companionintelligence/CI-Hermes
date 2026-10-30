#!/bin/sh
# Pull inference config from the Hub, write it to .env.hub-bootstrap, and make the
# Hub-managed part of config.yaml follow it (reconcile-hub-config.py).
#
# Idempotent and failure-tolerant: if the Hub is unreachable the script logs
# and exits 0 so container start still succeeds — Hermes will fall back to
# its own setup wizard for credentials.
#
# --retry-in-background (the two container entrypoints): when the Hub can't be
# reached, keep the last handout as above and also ask again every
# HUB_BOOTSTRAP_RETRY_INTERVAL seconds from a background loop until the Hub answers
# once. A Hub still starting after a reboot is the usual case. The answer is applied
# as at start (this script, then bootstrap-ci-context.sh). config.yaml carries the
# model and the Hub's own endpoint into the running processes. Terminal sessions
# don't pass it: each one fetches again anyway.
#
# POSIX sh — no bashisms. Runs in any /bin/sh including dash.
#
# Inputs:
#   CI_HUB_URL       Base URL of the Hub backend  (default: http://ci-os-hub:5002)
#                    Falls back to HUB_URL when Hub injects MCP env at install time.
#   HUB_APP_SLUG     App slug to bootstrap as     (default: hermes-agent)
#   HERMES_HOME      Hermes data dir              (default: /opt/data)
#   HUB_BOOTSTRAP_TIMEOUT    Whole seconds to wait for each handout request (default: 20)
#   HUB_BOOTSTRAP_RETRY_INTERVAL  Whole seconds between tries with --retry-in-background (default: 30)
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

# The OpenAI-SDK endpoint and key aliases. For the Hub's own endpoint config.yaml owns
# them (sanitize_env drops them); for a cloud provider they travel in env.
ENDPOINT_ENV_KEYS='CUSTOM_BASE_URL|CUSTOM_API_KEY|OPENAI_BASE_URL|OPENAI_API_BASE|OPENAI_API_KEY'

log() {
  echo "[hub-bootstrap] $*"
}

fetch_bootstrap() {
  if [ -n "${BOOTSTRAP_FIXTURE_FILE:-}" ]; then
    # A missing fixture is a Hub that can't be reached.
    cat "${BOOTSTRAP_FIXTURE_FILE}"
    return
  fi
  url="${CI_HUB_URL}/api/inference/apps/${HUB_APP_SLUG}/credentials.env"
  # The Hub's first handout after it starts can take 10 s or more: it probes Ollama
  # addresses that may not answer, 3 s each, before it replies. At 5 s per try both
  # tries ran out and Hermes started with no model and no config.yaml. 20 s covers
  # that slow first answer. Connecting gets 5 s of it, so a Hub that never accepts
  # the connection costs about 12 s of startup and one that accepts and then stalls
  # about 42 s.
  max_time="$(handout_timeout)"
  curl --silent --show-error --fail --connect-timeout 5 --max-time "${max_time}" \
    --retry 1 --retry-delay 2 "${url}"
}

positive_seconds() {
  # $1: variable name, $2: default. Its value as whole seconds, or the default with
  # a warning for 0 or a non-number.
  eval "t=\"\${$1:-}\""
  case "${t}" in
    '') echo "$2"; return 0 ;;
    *[!0-9]*) ;;
    *) if [ "${t}" -gt 0 ] 2>/dev/null; then echo "${t}"; return 0; fi ;;
  esac
  log "WARN: $1=${t} is not a positive whole number of seconds; using $2" >&2
  echo "$2"
}

handout_timeout() {
  # HUB_BOOTSTRAP_TIMEOUT as curl --max-time. curl reads 0 as "no limit", so a Hub
  # that stalls would hang the container start. It exits at once on a non-number,
  # so every handout would be skipped. Either value falls back to 20 s.
  positive_seconds HUB_BOOTSTRAP_TIMEOUT 20
}

retry_in_background() {
  # The loop keeps this script's stdout and stderr, which the entrypoints hand to the
  # container log. A caller that captures or pipes the output would wait for the loop
  # to end, so only the entrypoints pass --retry-in-background. Each container runs
  # its own loop, as each runs its own start-up: both write the shared files with an
  # atomic rename.
  interval="$(positive_seconds HUB_BOOTSTRAP_RETRY_INTERVAL 30)"
  # What the processes about to start load from the env file, to tell later whether
  # the answer changed anything only env carries.
  # -r, not -f: under set -e an unreadable file (one an older image wrote as root)
  # would end the script here, before the loop starts.
  started_env=""
  if [ -r "${OUT_ENV}" ]; then
    started_env="$(env_carried < "${OUT_ENV}")"
  fi
  (
    set +e
    while :; do
      sleep "${interval}"
      # The start-up run already logged why the Hub couldn't be reached; repeating
      # curl's error (and any HUB_BOOTSTRAP_TIMEOUT warning) on every try only fills
      # the container log while the Hub stays down.
      body="$(fetch_bootstrap 2>/dev/null)"
      rc=$?
      if [ "${rc}" -eq 22 ]; then
        # curl --fail: the Hub is up and answered with an error. A 5xx, 408 or 429 is
        # a Hub still settling (curl's own --retry counts 408, 429, 500, 502, 503 and
        # 504 as transient; a proxy in front of a restarting Hub can answer other
        # 5xx), so keep asking. Anything else (a 404 from an older Hub, a 401, a
        # 403) won't change. A 2xx means the Hub settled between the two requests:
        # the next try gets the handout.
        status="$(hub_status)"
        case "${status}" in
          2??|5??|408|429|000) continue ;;
        esac
        log "WARN: the Hub answered with an error (HTTP ${status}); keeping the last handout until the next start"
        exit 0
      fi
      if [ "${rc}" -ne 0 ]; then
        continue
      fi
      if [ -z "${body}" ]; then
        log "WARN: the Hub answered with an empty handout; keeping the last one"
        exit 0
      fi
      log "the Hub answered; applying its handout"
      if ! apply_handout "${body}"; then
        exit 0
      fi
      "${SCRIPT_DIR}/bootstrap-ci-context.sh" || log "ERROR: bootstrap-ci-context.sh failed after the late handout"
      if [ "$(env_carried < "${OUT_ENV}")" != "${started_env}" ]; then
        log "WARN: the handout changed settings that travel in env (a cloud endpoint or key); the dashboard and gateway use them from their next start"
      fi
      exit 0
    done
  ) </dev/null &
  log "asking the Hub again every ${interval} s until it answers (pid $!)"
}

hub_status() {
  # The HTTP status a handout request gets now, or 000 when none arrived. Asked only
  # after curl --fail reported an HTTP error, to tell a refusal from a Hub still
  # settling. It is a second request, so the Hub may have moved on (to a 200) since.
  curl --silent --output /dev/null --write-out '%{http_code}' --connect-timeout 5 \
    --max-time "$(handout_timeout 2>/dev/null)" \
    "${CI_HUB_URL}/api/inference/apps/${HUB_APP_SLUG}/credentials.env" || true
}

env_carried() {
  # stdin: env lines. The ones hub-env.sh exports that config.yaml can't carry: a
  # cloud provider's endpoint and key plus the Hub's cloud-fallback keys
  # (ANTHROPIC_API_KEY, GOOGLE_API_KEY, GEMINI_API_KEY).
  grep -E "^(${ENDPOINT_ENV_KEYS}|ANTHROPIC_[A-Za-z0-9_]*|GEMINI_[A-Za-z0-9_]*|GOOGLE_[A-Za-z0-9_]*)=" | sort || true
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
  awk -v is_local="${1:-0}" -v endpoint_re="^(${ENDPOINT_ENV_KEYS})=" '
    /^(HERMES_INFERENCE_MODEL|HERMES_MODEL|OPENAI_MODEL)=/ { next }
    is_local == "1" && $0 ~ endpoint_re { next }
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

install_env_file() {
  # $1: a temp file beside OUT_ENV. Renames it over OUT_ENV (atomic: the web and
  # gateway containers share the directory); on failure removes it and returns 1.
  chmod 600 "$1" 2>/dev/null || true
  if mv "$1" "${OUT_ENV}"; then
    return 0
  fi
  rm -f "$1"
  return 1
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
  retry=0
  if [ "${1:-}" = "--retry-in-background" ]; then
    retry=1
  fi

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
      # A failed write here must not end the script under set -e: the loop below
      # still has to start.
      if tmp="$(mktemp "${OUT_ENV}.XXXXXX")"; then
        if ! sanitize_env "$(is_local_env < "${OUT_ENV}")" < "${OUT_ENV}" > "${tmp}" \
          || cmp -s "${tmp}" "${OUT_ENV}"; then
          rm -f "${tmp}"
        elif install_env_file "${tmp}"; then
          log "removed config-owned overrides from the existing ${OUT_ENV}"
        else
          log "ERROR: could not replace ${OUT_ENV}; keeping it as it is"
        fi
      else
        log "ERROR: cannot write beside ${OUT_ENV}; keeping it as it is"
      fi
      reconcile_config
    fi
    if [ "${retry}" = 1 ]; then
      retry_in_background
    fi
    exit 0
  fi

  apply_handout "${body}" || true
}

apply_handout() {
  # $1: the handout body, as the Hub sent it.
  body="$1"

  # Detect the Hub's own endpoint (api_key sentinel "ollama") vs a cloud provider:
  # only a cloud provider's endpoint travels in env.
  is_local_ollama="$(printf '%s\n' "${body}" | is_local_env)"

  # Temp files live beside the output so the final mv is an atomic rename: the web
  # and gateway containers share this directory and start together.
  if ! tmp="$(mktemp "${OUT_ENV}.XXXXXX")"; then
    log "ERROR: cannot write beside ${OUT_ENV}; keeping the last handout"
    return 1
  fi
  if ! printf '%s\n' "${body}" | translate_keys "${is_local_ollama}" | sanitize_env "${is_local_ollama}" > "${tmp}"; then
    rm -f "${tmp}"
    log "ERROR: translate_keys failed"
    return 1
  fi

  # main calls this as `apply_handout ... || true`, which turns set -e off in here:
  # every step that can fail is checked by hand.
  gateway_ip="$(detect_docker_gateway_ip || true)"
  if [ -n "${gateway_ip}" ]; then
    tmp2=""
    if tmp2="$(mktemp "${OUT_ENV}.XXXXXX")" \
      && rewrite_host_docker_internal "${tmp}" "${gateway_ip}" > "${tmp2}" \
      && mv "${tmp2}" "${tmp}"; then
      log "normalized host.docker.internal -> ${gateway_ip}"
    else
      [ -z "${tmp2}" ] || rm -f "${tmp2}"
      log "WARN: failed to normalize host.docker.internal values"
    fi
  fi

  if ! install_env_file "${tmp}"; then
    log "ERROR: could not replace ${OUT_ENV}; keeping the last handout"
    return 1
  fi
  log "wrote ${OUT_ENV} ($(wc -l < "${OUT_ENV}" | tr -d ' ') lines)"

  reconcile_config
}

main "$@"
