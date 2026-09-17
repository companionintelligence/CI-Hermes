# shellcheck shell=bash
# The one loader for the Hub handout env file ($HERMES_HOME/.env.hub-bootstrap).
# Sourced by entrypoint.sh (web: dashboard + terminal server), gateway-entrypoint.sh
# (gateway) and start-hermes.sh (terminal session). server.cjs applies the same rule
# through hub-env.cjs; tests/hub-env.test.cjs runs both on one file and requires the
# same result.
#
# Each of those used to parse the file its own way, and they disagreed: the web
# entrypoint `source`d it (exporting every key, and running it as shell), the gateway
# skipped CUSTOM_*, the terminal took it. Upstream Hermes ranks env CUSTOM_BASE_URL
# over config model.base_url and HERMES_INFERENCE_MODEL over model.default, and env
# is fixed for the life of a process, so the dashboard and the gateway could run
# different endpoints and models from one handout, and ignore config.yaml after it
# was corrected.
#
# config.yaml now owns the model and the Hub endpoint (reconcile-hub-config.py). This
# loader never exports a key that would outrank it, even if the file carries one — an
# env file an older image wrote is the obvious case. bootstrap-from-hub.sh already
# strips them when it writes the file; this is the same rule at the point of use.

HUB_ENV_ALLOWED_PREFIXES=(OPENAI_ HERMES_ CUSTOM_ ANTHROPIC_ GEMINI_ GOOGLE_ OLLAMA_)

# config.yaml model.default is authoritative. HERMES_INFERENCE_MODEL / HERMES_MODEL
# outrank it in the dashboard's TUI gateway and `hermes -z`; OPENAI_MODEL is dead
# upstream and only misleads.
HUB_ENV_CONFIG_OWNED_KEYS=(HERMES_INFERENCE_MODEL HERMES_MODEL OPENAI_MODEL)

# For the Hub's own endpoint (HERMES_OPENAI_API_KEY is the "ollama" sentinel)
# config.yaml also owns the endpoint: CUSTOM_BASE_URL would outrank model.base_url,
# and the OpenAI-SDK aliases make the model picker treat the local endpoint as
# api.openai.com. A cloud provider's endpoint still travels in env, because its key
# is never written to config.yaml.
HUB_ENV_LOCAL_ENDPOINT_KEYS=(CUSTOM_BASE_URL CUSTOM_API_KEY OPENAI_BASE_URL OPENAI_API_BASE OPENAI_API_KEY)

# Export the handout into the current shell. Values are data: nothing in the file is
# executed. The endpoint rule depends on HERMES_OPENAI_API_KEY wherever it appears in
# the file, so the file is read fully before anything is exported.
#
# Keys config.yaml owns are also UNSET, not just left out: a process that inherited
# them — server.cjs's own environment after the handout moved from a cloud provider
# back to the Hub endpoint, say — would otherwise keep outranking config.yaml.
load_hub_env_file() {
  local env_file="$1"
  local line key value prefix skip i is_local=0
  local -a keys=() values=()
  [[ -f "${env_file}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
      value="${BASH_REMATCH[1]}"
    elif [[ "${value}" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    if [[ "${key}" == "HERMES_OPENAI_API_KEY" ]]; then
      if [[ "${value}" == "ollama" ]]; then is_local=1; else is_local=0; fi
    fi
    keys+=("${key}")
    values+=("${value}")
  done < "${env_file}"

  unset "${HUB_ENV_CONFIG_OWNED_KEYS[@]}"
  if [[ "${is_local}" == 1 ]]; then
    unset "${HUB_ENV_LOCAL_ENDPOINT_KEYS[@]}"
  fi

  for i in "${!keys[@]}"; do
    key="${keys[$i]}"
    skip=1
    for prefix in "${HUB_ENV_ALLOWED_PREFIXES[@]}"; do
      if [[ "${key}" == "${prefix}"* ]]; then skip=0; break; fi
    done
    for prefix in "${HUB_ENV_CONFIG_OWNED_KEYS[@]}"; do
      [[ "${key}" == "${prefix}" ]] && skip=1
    done
    if [[ "${is_local}" == 1 ]]; then
      for prefix in "${HUB_ENV_LOCAL_ENDPOINT_KEYS[@]}"; do
        [[ "${key}" == "${prefix}" ]] && skip=1
      done
    fi
    [[ "${skip}" == 0 ]] && export "${key}=${values[$i]}"
  done
  return 0
}
