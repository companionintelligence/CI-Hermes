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

# Hermes' hard minimum context window. Mirrors the upstream agent's
# MINIMUM_CONTEXT_LENGTH, which is the literal 64000 (NOT 65536) and is compared
# with a strict `<`, so a context_length of exactly 64000 is accepted. We only pin
# model.context_length at/above this value; below it the agent would abort at startup.
HERMES_MIN_CONTEXT=64000

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
  # $1: is_local_ollama — "1" when the Hub endpoint is the local Ollama box
  #     (api_key sentinel "ollama"); "0"/empty for a cloud provider.
  #
  # stdin:  HERMES_* and other env lines from Hub
  # stdout: env lines Hermes can read, plus the original keys preserved.
  #
  # For a LOCAL Ollama endpoint we deliberately do NOT emit — and actively drop —
  # the OpenAI-SDK aliases OPENAI_BASE_URL / OPENAI_API_BASE / OPENAI_API_KEY.
  # The runtime resolves the local endpoint from CUSTOM_BASE_URL + config
  # model.base_url (upstream no longer consults OPENAI_BASE_URL), so these aliases
  # are unused there — while setting them makes the upstream model picker treat the
  # local endpoint as the generic "openai-api" provider, which loses the Ollama
  # num_ctx injection and points the main model at api.openai.com after a GUI model
  # switch. For a CLOUD provider the OpenAI aliases are correct and required
  # (host-gated key resolution), so we keep the original fan-out untouched.
  awk -v is_local="${1:-0}" '
    BEGIN { FS="="; emitted_model_aliases=0 }
    # Local: never let an OpenAI-SDK base/key alias reach the agent (foot-gun above),
    # even if a future Hub were to send one directly.
    is_local == "1" && /^OPENAI_BASE_URL=/ { next }
    is_local == "1" && /^OPENAI_API_BASE=/ { next }
    is_local == "1" && /^OPENAI_API_KEY=/  { next }
    /^HERMES_OPENAI_BASE_URL=/ {
      v=$0
      sub(/^HERMES_OPENAI_BASE_URL=/, "CUSTOM_BASE_URL=", v); print v
      if (is_local != "1") {
        a=$0; sub(/^HERMES_OPENAI_BASE_URL=/, "OPENAI_API_BASE=", a); print a
        b=$0; sub(/^HERMES_OPENAI_BASE_URL=/, "OPENAI_BASE_URL=", b); print b
      }
      print
      next
    }
    /^HERMES_OPENAI_API_KEY=/  {
      v=$0
      sub(/^HERMES_OPENAI_API_KEY=/, "CUSTOM_API_KEY=", v); print v
      if (is_local != "1") {
        a=$0; sub(/^HERMES_OPENAI_API_KEY=/, "OPENAI_API_KEY=", a); print a
      }
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
  if ! body="$(fetch_bootstrap)"; then
    log "WARN: Hub unreachable or returned error; leaving Hermes provider config alone"
    exit 0
  fi

  if [ -z "${body}" ]; then
    log "WARN: empty response from Hub; nothing to apply"
    exit 0
  fi

  # Detect a local-Ollama endpoint (api_key sentinel "ollama") vs a cloud provider,
  # so translate_keys suppresses the OpenAI-SDK aliases for local only — they make
  # the model picker mislabel the local box as the cloud "openai-api" provider.
  main_api_key="$(printf '%s\n' "${body}" | grep -m1 '^HERMES_OPENAI_API_KEY=' | cut -d= -f2- || true)"
  main_api_key="$(normalize_env_value "${main_api_key}")"
  is_local_ollama=0
  [ "${main_api_key}" = "ollama" ] && is_local_ollama=1

  tmp="$(mktemp)"
  if ! printf '%s\n' "${body}" | translate_keys "${is_local_ollama}" > "${tmp}"; then
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
    model_name_raw=$(grep "^HERMES_DEFAULT_MODEL=" "${OUT_ENV}" | cut -d= -f2- | head -n 1)
    [ -z "${model_name_raw}" ] && model_name_raw=$(grep "^HERMES_DEFAULT_MODEL_BACKEND_ID=" "${OUT_ENV}" | cut -d= -f2- | head -n 1)
    model_name=$(normalize_env_value "${model_name_raw}")
    
    if [ -n "${model_name}" ]; then
      # Only write config.yaml if it doesn't exist or is empty
      # This ensures user's manual config.yaml is not overwritten
      if [ ! -s "${OUT_CONFIG}" ]; then
        model_name_yaml=$(yaml_single_quote "${model_name}")
        cat > "${OUT_CONFIG}" <<EOF
model:
  provider: ollama
  default: '${model_name_yaml}'
EOF
        # Pin the local endpoint in config.yaml so (1) the runtime resolves it from
        # the single source of truth (upstream no longer consults OPENAI_BASE_URL) and
        # (2) the GUI model picker surfaces it as the "custom" provider — the one that
        # injects ollama_num_ctx — instead of the generic "openai-api" provider (which
        # drops num_ctx and points the main model at api.openai.com on a switch).
        # Local-only: gated on the "ollama" key sentinel, mirroring the auxiliary
        # block, so cloud setups (provider/base_url come from the Hub) are untouched.
        main_base=$(normalize_env_value "$(grep "^HERMES_OPENAI_BASE_URL=" "${OUT_ENV}" | cut -d= -f2- | head -n 1)")
        main_key=$(normalize_env_value "$(grep "^HERMES_OPENAI_API_KEY=" "${OUT_ENV}" | cut -d= -f2- | head -n 1)")
        if [ -n "${main_base}" ] && [ "${main_key}" = "ollama" ]; then
          esc_main_base=$(yaml_single_quote "${main_base}")
          {
            printf "  base_url: '%s'\n" "${esc_main_base}"
            printf "  api_key: 'ollama'\n"
          } >> "${OUT_CONFIG}"
          log "set model.base_url=${main_base} (config-authoritative endpoint) in ${OUT_CONFIG}"
        fi
        # Hardware-aware context size from the Hub (HERMES_NUM_CTX). The upstream
        # hermes-agent reads model.ollama_num_ctx (NOT num_ctx) and injects it as
        # extra_body.options.num_ctx on every chat request — see the bundled
        # plugins/model-providers/custom profile. A value under the wrong key is
        # silently ignored, so Hermes falls back to Ollama's tiny 4096 default for
        # any model it can't auto-detect.
        #
        # We also pin model.context_length to the same value so the agent's working
        # window matches the KV cache Ollama actually allocates (otherwise the agent
        # auto-detects the model's full window — e.g. 128K — and over-fills a smaller
        # cache, silently truncating long sessions). But ONLY when the value clears
        # HERMES_MIN_CONTEXT: the agent fatally rejects a smaller context_length at
        # startup. The Hub floors hermes-agent to that minimum, so this normally fires;
        # the guard keeps us safe against an older Hub (or a model whose own window is
        # below the minimum), where we leave context_length to the agent's
        # auto-detection and only cap the KV cache via ollama_num_ctx.
        #
        # Only a POSITIVE integer is a meaningful window; treat 0 / garbage as unset,
        # matching the reconcile path in bootstrap-ci-context.sh.
        num_ctx_raw=$(grep "^HERMES_NUM_CTX=" "${OUT_ENV}" | cut -d= -f2- | head -n 1)
        num_ctx=$(normalize_env_value "${num_ctx_raw}")
        if printf '%s' "${num_ctx}" | grep -q -E '^[1-9][0-9]*$'; then
          printf '  ollama_num_ctx: %s\n' "${num_ctx}" >> "${OUT_CONFIG}"
          log "set model.ollama_num_ctx=${num_ctx} in ${OUT_CONFIG}"
          if [ "${num_ctx}" -ge "${HERMES_MIN_CONTEXT}" ]; then
            printf '  context_length: %s\n' "${num_ctx}" >> "${OUT_CONFIG}"
            log "set model.context_length=${num_ctx} in ${OUT_CONFIG}"
          fi
        fi

        # Register the local endpoint as a named provider so the GUI model picker
        # LISTS it with its models — the dashboard picker reads providers:/
        # custom_providers:, NOT model.base_url. Keyed "ollama": a built-in alias of
        # the num_ctx-aware "custom" profile, so selecting a model here writes a
        # provider that still injects ollama_num_ctx on switch (verified: both the
        # "ollama" slug and a "custom" write resolve to the custom profile). Emitted
        # AFTER all model.* keys so they stay contiguous under model:. Local-only.
        if [ -n "${main_base}" ] && [ "${main_key}" = "ollama" ]; then
          esc_main_base=$(yaml_single_quote "${main_base}")
          {
            printf 'providers:\n'
            printf '  ollama:\n'
            printf "    name: 'Ollama (local)'\n"
            printf "    base_url: '%s'\n" "${esc_main_base}"
            printf "    api_key: 'ollama'\n"
          } >> "${OUT_CONFIG}"
          log "registered providers.ollama for the GUI model picker -> ${main_base}"
        fi

        # Point auxiliary side-tasks (compression, title, vision, …) at the SAME
        # local endpoint as the main model. Without this, Hermes' aux auto-detection
        # chain only tries cloud providers (OpenRouter/Nous/api-key) and resolves to
        # nothing on a local-only appliance — so compression/title silently don't run
        # (it drops middle turns without a summary). An explicit base_url+api_key per
        # task forces the "custom" path to the local endpoint, which also lets the
        # native /api/chat adapter take over.
        #
        # Gated on (1) CI_HERMES_OLLAMA_NATIVE being enabled — so flag-off stays a true
        # no-op — and (2) the api_key being the local "ollama" sentinel, so we NEVER
        # embed a cloud API key in config.yaml or change cloud aux behavior when the
        # Hub points Hermes at a cloud provider. Lockstep with bootstrap-ci-context.sh.
        aux_base=$(normalize_env_value "$(grep "^HERMES_OPENAI_BASE_URL=" "${OUT_ENV}" | cut -d= -f2- | head -n 1)")
        aux_key=$(normalize_env_value "$(grep "^HERMES_OPENAI_API_KEY=" "${OUT_ENV}" | cut -d= -f2- | head -n 1)")
        ci_native=$(printf '%s' "${CI_HERMES_OLLAMA_NATIVE:-}" | tr '[:upper:]' '[:lower:]')
        case "${ci_native}" in 1|true|yes|on) native_aux=1 ;; *) native_aux="" ;; esac
        if [ -n "${native_aux}" ] && [ -n "${aux_base}" ] && [ "${aux_key}" = "ollama" ]; then
          esc_base=$(yaml_single_quote "${aux_base}")
          esc_model=$(yaml_single_quote "${model_name}")
          {
            printf 'auxiliary:\n'
            for aux_task in compression title_generation vision web_extract session_search skills_hub mcp; do
              printf '  %s:\n' "${aux_task}"
              printf "    base_url: '%s'\n" "${esc_base}"
              printf "    api_key: 'ollama'\n"
              printf "    model: '%s'\n" "${esc_model}"
            done
          } >> "${OUT_CONFIG}"
          log "wrote auxiliary providers (side-tasks -> ${aux_base}) in ${OUT_CONFIG}"
        fi

        chmod 600 "${OUT_CONFIG}" 2>/dev/null || true
        log "wrote ${OUT_CONFIG} with provider=ollama"
      else
        log "config.yaml already exists; skipping generation"
      fi
    fi
  fi
}

main "$@"
