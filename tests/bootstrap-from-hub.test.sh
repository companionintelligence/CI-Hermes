#!/bin/bash
# Tests for bootstrap-from-hub.sh.
# Uses BOOTSTRAP_FIXTURE_FILE to bypass the real curl, so this works in CI
# without standing up an HTTP server.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../bootstrap-from-hub.sh"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [[ "${want}" == "${got}" ]]; then
    echo "  ✓ ${label}"
    PASS=$((PASS + 1))
  else
    echo "  ✗ ${label}"
    echo "    want: ${want}"
    echo "    got:  ${got}"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF "${needle}"; then
    echo "  ✓ ${label}"
    PASS=$((PASS + 1))
  else
    echo "  ✗ ${label}"
    echo "    expected to contain: ${needle}"
    echo "    in:                  ${haystack}"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF "${needle}"; then
    echo "  ✗ ${label}"
    echo "    expected to NOT contain: ${needle}"
    echo "    in:                      ${haystack}"
    FAIL=$((FAIL + 1))
  else
    echo "  ✓ ${label}"
    PASS=$((PASS + 1))
  fi
}

# LITERAL line-prefix checks: assert (no) line *starts with* the given prefix,
# matched literally — not as a regex. A bare substring check would let
# "OPENAI_BASE_URL=" match inside "HERMES_OPENAI_BASE_URL=", and a grep -E check
# would mis-handle prefixes containing metacharacters (URLs with ".", "{") or a
# stray leading "^". `[[ "$line" == "$prefix"* ]]` treats the quoted prefix as a
# literal string with a trailing wildcard, so callers pass plain text.
_starts_with_line() {  # $1 prefix, $2 haystack → 0 if some line starts with prefix
  local prefix="$1" haystack="$2" line
  while IFS= read -r line; do
    [[ "${line}" == "${prefix}"* ]] && return 0
  done <<< "${haystack}"
  return 1
}

assert_line() {
  local label="$1" prefix="$2" haystack="$3"
  if _starts_with_line "${prefix}" "${haystack}"; then
    echo "  ✓ ${label}"; PASS=$((PASS + 1))
  else
    echo "  ✗ ${label}"; echo "    expected a line starting with: ${prefix}"; echo "    in: ${haystack}"; FAIL=$((FAIL + 1))
  fi
}

assert_no_line() {
  local label="$1" prefix="$2" haystack="$3"
  if _starts_with_line "${prefix}" "${haystack}"; then
    echo "  ✗ ${label}"; echo "    expected NO line starting with: ${prefix}"; echo "    in: ${haystack}"; FAIL=$((FAIL + 1))
  else
    echo "  ✓ ${label}"; PASS=$((PASS + 1))
  fi
}

run_with_fixture() {
  local fixture_body="$1"
  local gateway_ip_override="${2:-}"
  local data_dir
  data_dir="$(mktemp -d)"
  local fixture_file
  fixture_file="$(mktemp)"
  printf '%s' "${fixture_body}" > "${fixture_file}"

  if [[ -n "${gateway_ip_override}" ]]; then
    HERMES_HOME="${data_dir}" \
    BOOTSTRAP_FIXTURE_FILE="${fixture_file}" \
    DOCKER_HOST_GATEWAY_IP="${gateway_ip_override}" \
      "${SCRIPT}" >/dev/null 2>&1
  else
    HERMES_HOME="${data_dir}" \
    BOOTSTRAP_FIXTURE_FILE="${fixture_file}" \
      "${SCRIPT}" >/dev/null 2>&1
  fi

  cat "${data_dir}/.env.hub-bootstrap"
  rm -rf "${data_dir}" "${fixture_file}"
}

run_with_no_fixture_and_bad_hub() {
  local data_dir
  data_dir="$(mktemp -d)"
  HERMES_HOME="${data_dir}" \
  CI_HUB_URL="http://127.0.0.1:1" \
    "${SCRIPT}" >/dev/null 2>&1
  local rc=$?
  rm -rf "${data_dir}"
  return ${rc}
}

run_with_fixture_in_dir() {
  local fixture_body="$1"
  local data_dir="$2"
  local gateway_ip_override="${3:-}"
  local fixture_file
  fixture_file="$(mktemp)"
  printf '%s' "${fixture_body}" > "${fixture_file}"

  if [[ -n "${gateway_ip_override}" ]]; then
    HERMES_HOME="${data_dir}" \
    BOOTSTRAP_FIXTURE_FILE="${fixture_file}" \
    DOCKER_HOST_GATEWAY_IP="${gateway_ip_override}" \
      "${SCRIPT}" >/dev/null 2>&1
  else
    HERMES_HOME="${data_dir}" \
    BOOTSTRAP_FIXTURE_FILE="${fixture_file}" \
      "${SCRIPT}" >/dev/null 2>&1
  fi

  rm -f "${fixture_file}"
}

# ─── Test 1: LOCAL Ollama (api_key sentinel "ollama") → CUSTOM_* aliases only ──
# The OpenAI-SDK aliases (OPENAI_BASE_URL/OPENAI_API_BASE/OPENAI_API_KEY) are
# deliberately suppressed for a local endpoint: they make the upstream model picker
# mislabel the local box as the cloud "openai-api" provider (dropping num_ctx and
# targeting api.openai.com on a GUI switch). The runtime uses CUSTOM_BASE_URL +
# config model.base_url instead. Model aliases are unaffected.
echo "test: local endpoint aliases to CUSTOM_* only (no OPENAI_* foot-guns)"
fixture=$'HERMES_OPENAI_BASE_URL=http://ci-hub-ollama:11434/v1\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL=hermes4-70b\nHERMES_DEFAULT_MODEL_BACKEND_ID=hermes4:70b\nHERMES_EMBEDDINGS_MODEL=nomic-embed-text\n'
out="$(run_with_fixture "${fixture}")"
assert_no_line "OPENAI_API_BASE suppressed for local" "OPENAI_API_BASE=" "${out}"
assert_no_line "OPENAI_BASE_URL suppressed for local" "OPENAI_BASE_URL=" "${out}"
assert_no_line "OPENAI_API_KEY suppressed for local" "OPENAI_API_KEY=" "${out}"
assert_contains "CUSTOM_BASE_URL alias present" "CUSTOM_BASE_URL=http://ci-hub-ollama:11434/v1" "${out}"
assert_contains "CUSTOM_API_KEY alias present" "CUSTOM_API_KEY=ollama" "${out}"
assert_contains "OPENAI_MODEL present" "OPENAI_MODEL=hermes4-70b" "${out}"
assert_contains "HERMES_INFERENCE_MODEL alias present" "HERMES_INFERENCE_MODEL=hermes4-70b" "${out}"
assert_contains "OPENAI_EMBEDDINGS_MODEL present" "OPENAI_EMBEDDINGS_MODEL=nomic-embed-text" "${out}"
assert_contains "original HERMES_ key preserved" "HERMES_DEFAULT_MODEL=hermes4-70b" "${out}"
assert_contains "BACKEND_ID passthrough preserved" "HERMES_DEFAULT_MODEL_BACKEND_ID=hermes4:70b" "${out}"

# ─── Test 1-cloud: CLOUD provider (real api_key) keeps the full OPENAI_* fan-out ─
# For a cloud endpoint "openai-api" is the correct provider and the OpenAI aliases
# are required (host-gated key resolution), so they must NOT be suppressed.
echo "test: cloud endpoint keeps OPENAI_* aliases (real key)"
fixture=$'HERMES_OPENAI_BASE_URL=https://api.openai.com/v1\nHERMES_OPENAI_API_KEY=sk-real-cloud\nHERMES_DEFAULT_MODEL=gpt-4o\n'
out="$(run_with_fixture "${fixture}")"
assert_line "cloud OPENAI_API_BASE present" "OPENAI_API_BASE=https://api.openai.com/v1" "${out}"
assert_line "cloud OPENAI_BASE_URL present" "OPENAI_BASE_URL=https://api.openai.com/v1" "${out}"
assert_line "cloud OPENAI_API_KEY present" "OPENAI_API_KEY=sk-real-cloud" "${out}"
assert_line "cloud CUSTOM_BASE_URL present" "CUSTOM_BASE_URL=https://api.openai.com/v1" "${out}"

# ─── Test 1b: backend id becomes model fallback when plain default model is absent ──
echo "test: backend id becomes model fallback when plain default model is absent"
fixture=$'HERMES_OPENAI_BASE_URL=http://ci-hub-ollama:11434/v1\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL_BACKEND_ID=qwen3.5:9b\n'
out="$(run_with_fixture "${fixture}")"
assert_contains "OPENAI_MODEL fallback present" "OPENAI_MODEL=qwen3.5:9b" "${out}"
assert_contains "HERMES_INFERENCE_MODEL fallback present" "HERMES_INFERENCE_MODEL=qwen3.5:9b" "${out}"
assert_contains "backend id preserved" "HERMES_DEFAULT_MODEL_BACKEND_ID=qwen3.5:9b" "${out}"

# ─── Test 2: Unrelated env lines pass through untouched ─────────────────────
echo "test: unrelated env lines pass through"
fixture=$'SOMETHING_ELSE=opaque-value\nHERMES_OPENAI_API_KEY=ollama\n'
out="$(run_with_fixture "${fixture}")"
assert_contains "unrelated line preserved" "SOMETHING_ELSE=opaque-value" "${out}"

# ─── Test 2b: host.docker.internal is normalized to gateway IP ─────────────
echo "test: host.docker.internal is rewritten to detected gateway IP"
fixture=$'HERMES_OPENAI_BASE_URL=http://host.docker.internal:11434/v1\nOLLAMA_HOST=http://host.docker.internal:11434\n'
out="$(run_with_fixture "${fixture}" "172.18.0.1")"
assert_contains "OPENAI_API_BASE rewritten" "OPENAI_API_BASE=http://172.18.0.1:11434/v1" "${out}"
assert_contains "OPENAI_BASE_URL rewritten" "OPENAI_BASE_URL=http://172.18.0.1:11434/v1" "${out}"
assert_contains "CUSTOM_BASE_URL rewritten" "CUSTOM_BASE_URL=http://172.18.0.1:11434/v1" "${out}"
assert_contains "HERMES base URL rewritten" "HERMES_OPENAI_BASE_URL=http://172.18.0.1:11434/v1" "${out}"
assert_contains "OLLAMA_HOST rewritten" "OLLAMA_HOST=http://172.18.0.1:11434" "${out}"

# ─── Test 2c: gateway override metacharacters are treated literally ─────────
echo "test: gateway override escapes sed replacement metacharacters"
fixture=$'HERMES_OPENAI_BASE_URL=http://host.docker.internal:11434/v1\n'
out="$(run_with_fixture "${fixture}" '10.0.0.1\&edge')"
assert_contains "escaped override remains literal" "OPENAI_API_BASE=http://10.0.0.1\\&edge:11434/v1" "${out}"
assert_contains "CUSTOM_BASE_URL escaped override remains literal" "CUSTOM_BASE_URL=http://10.0.0.1\\&edge:11434/v1" "${out}"

# ─── Test 3: Hub unreachable → script exits 0 (does not abort container) ────
echo "test: unreachable Hub returns exit 0"
if run_with_no_fixture_and_bad_hub; then
  echo "  ✓ exits 0 when Hub is unreachable"
  PASS=$((PASS + 1))
else
  echo "  ✗ unexpected non-zero exit (rc=$?)"
  FAIL=$((FAIL + 1))
fi

# ─── Test 4: Missing data dir → script exits 0 ──────────────────────────────
echo "test: missing data dir returns exit 0"
if HERMES_HOME="/does/not/exist/$$" "${SCRIPT}" >/dev/null 2>&1; then
  echo "  ✓ exits 0 when HERMES_HOME is missing"
  PASS=$((PASS + 1))
else
  rc=$?
  echo "  ✗ unexpected non-zero exit (rc=${rc})"
  FAIL=$((FAIL + 1))
fi

# ─── Test 5: Idempotency — running twice yields same output ─────────────────
echo "test: idempotent across two runs"
data_dir="$(mktemp -d)"
fixture_file="$(mktemp)"
printf 'HERMES_OPENAI_BASE_URL=http://x/v1\nHERMES_OPENAI_API_KEY=k\nHERMES_DEFAULT_MODEL=m\n' > "${fixture_file}"
HERMES_HOME="${data_dir}" BOOTSTRAP_FIXTURE_FILE="${fixture_file}" "${SCRIPT}" >/dev/null 2>&1
hash1="$(shasum "${data_dir}/.env.hub-bootstrap" | awk '{print $1}')"
HERMES_HOME="${data_dir}" BOOTSTRAP_FIXTURE_FILE="${fixture_file}" "${SCRIPT}" >/dev/null 2>&1
hash2="$(shasum "${data_dir}/.env.hub-bootstrap" | awk '{print $1}')"
rm -rf "${data_dir}" "${fixture_file}"
assert_eq "two runs produce identical output" "${hash1}" "${hash2}"

# ─── Test 6: config.yaml generation uses YAML-safe quoted model name ─────────
echo "test: config.yaml is generated with quoted YAML-safe model name"
data_dir="$(mktemp -d)"
fixture="HERMES_DEFAULT_MODEL=model: foo #bar's"$'\n'
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_contains "config provider set" "provider: ollama" "${config_out}"
assert_contains "config default key used" "default: 'model: foo #bar''s'" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 6b: local endpoint pins model.base_url + api_key (picker shows 'custom') ──
# The pinned endpoint makes the GUI model picker surface the local box as the
# "custom" provider (which injects ollama_num_ctx) rather than the cloud
# "openai-api" provider, and makes the runtime config-authoritative.
echo "test: local endpoint writes model.base_url + api_key into config.yaml"
data_dir="$(mktemp -d)"
fixture=$'HERMES_DEFAULT_MODEL=gemma4:e2b\nHERMES_OPENAI_BASE_URL=http://host.docker.internal:11434/v1\nHERMES_OPENAI_API_KEY=ollama\nHERMES_NUM_CTX=64000\n'
run_with_fixture_in_dir "${fixture}" "${data_dir}" "172.17.0.1"
config_out="$(cat "${data_dir}/config.yaml")"
assert_contains "model.base_url pinned (host rewritten)" "base_url: 'http://172.17.0.1:11434/v1'" "${config_out}"
assert_contains "model.api_key sentinel written" "api_key: 'ollama'" "${config_out}"
assert_contains "provider stays ollama" "provider: ollama" "${config_out}"
# providers.ollama registers the local endpoint for the GUI model picker.
assert_contains "providers.ollama registered for picker" "name: 'Ollama (local)'" "${config_out}"
assert_line "providers section emitted" "providers:" "${config_out}"
# model.* keys must stay contiguous (num_ctx/context_length not nested under providers).
assert_line "ollama_num_ctx under model (2-space)" "  ollama_num_ctx: 64000" "${config_out}"
python3 -c "import yaml,sys; d=yaml.safe_load(open('${data_dir}/config.yaml')); sys.exit(0 if d['model'].get('ollama_num_ctx')==64000 and 'ollama' in d['providers'] and 'ollama_num_ctx' not in d['providers'] else 1)" \
  && { echo "  ✓ YAML structure valid (model keys contiguous, providers.ollama present)"; PASS=$((PASS+1)); } \
  || { echo "  ✗ YAML structure invalid"; FAIL=$((FAIL+1)); }
rm -rf "${data_dir}"

# ─── Test 6c: cloud endpoint does NOT pin model.base_url / leak the key ───────
echo "test: cloud endpoint leaves model.base_url out of config.yaml (no key leak)"
data_dir="$(mktemp -d)"
fixture=$'HERMES_DEFAULT_MODEL=gpt-4o\nHERMES_OPENAI_BASE_URL=https://api.openai.com/v1\nHERMES_OPENAI_API_KEY=sk-secret-cloud\n'
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no model.base_url for cloud" "base_url:" "${config_out}"
assert_not_contains "cloud key never written to model block" "sk-secret-cloud" "${config_out}"
assert_not_contains "no providers.ollama picker entry for cloud" "Ollama (local)" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 7: existing config.yaml is never overwritten ───────────────────────
echo "test: existing config.yaml is preserved"
data_dir="$(mktemp -d)"
cat > "${data_dir}/config.yaml" <<'EOF'
model:
  provider: custom
  default: keep-me
EOF
fixture=$'HERMES_DEFAULT_MODEL=qwen3.5:9b\n'
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_contains "existing provider preserved" "provider: custom" "${config_out}"
assert_contains "existing default preserved" "default: keep-me" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 8: quoted model values are unwrapped before YAML quoting ───────────
echo "test: quoted default model value is normalized"
data_dir="$(mktemp -d)"
fixture=$'HERMES_DEFAULT_MODEL="qwen3.5:9b"\n'
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_contains "unwrapped model value" "default: 'qwen3.5:9b'" "${config_out}"
assert_not_contains "wrapped quotes removed" "default: '\"qwen3.5:9b\"'" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 9: CRLF model values do not leak carriage returns into YAML ────────
echo "test: CRLF model values are normalized"
data_dir="$(mktemp -d)"
fixture="$(printf 'HERMES_DEFAULT_MODEL=qwen3.5:9b\r\n')"
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_contains "model value preserved" "default: 'qwen3.5:9b'" "${config_out}"
assert_not_contains "carriage return removed" "$(printf '\r')" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 10: single-quoted model values are unwrapped before YAML quoting ───
echo "test: single-quoted default model value is normalized"
data_dir="$(mktemp -d)"
fixture="$(printf "HERMES_DEFAULT_MODEL='qwen3.5:9b'\n")"
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_contains "single-quoted model unwrapped" "default: 'qwen3.5:9b'" "${config_out}"
assert_not_contains "single-quote wrapper removed" "default: '''qwen3.5:9b'''" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 11: a sub-64K HERMES_NUM_CTX writes ollama_num_ctx but NOT context_length ─
# The upstream agent reads model.ollama_num_ctx (not num_ctx). Below Hermes' 64K
# minimum, context_length must stay unset (a smaller value aborts the agent at
# startup); ollama_num_ctx still caps the KV cache.
echo "test: sub-64K HERMES_NUM_CTX writes ollama_num_ctx only"
data_dir="$(mktemp -d)"
fixture="$(printf 'HERMES_DEFAULT_MODEL=qwen3.5:9b\nHERMES_NUM_CTX=32768\n')"
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_contains "model.ollama_num_ctx written from HERMES_NUM_CTX" "ollama_num_ctx: 32768" "${config_out}"
# Assert the legacy key is absent at ANY value (the two-space indent anchors the
# `num_ctx` child without matching the `ollama_num_ctx` line above it).
assert_not_contains "legacy num_ctx key not written" "  num_ctx:" "${config_out}"
assert_not_contains "context_length not written below 64K (avoids startup abort)" "context_length:" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 11b: a >=64K HERMES_NUM_CTX writes both ollama_num_ctx and context_length ─
# At/above the 64K minimum it is safe (and desirable) to also pin context_length so
# the agent's working window matches the KV cache Ollama allocates.
echo "test: >=64K HERMES_NUM_CTX writes ollama_num_ctx + context_length"
data_dir="$(mktemp -d)"
fixture="$(printf 'HERMES_DEFAULT_MODEL=qwen3.5:9b\nHERMES_NUM_CTX=65536\n')"
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_contains "model.ollama_num_ctx written" "ollama_num_ctx: 65536" "${config_out}"
assert_contains "model.context_length written (>=64K)" "context_length: 65536" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 12: non-numeric HERMES_NUM_CTX is ignored ─────────────────────────
echo "test: non-numeric HERMES_NUM_CTX is ignored (no context window lines)"
data_dir="$(mktemp -d)"
fixture="$(printf 'HERMES_DEFAULT_MODEL=qwen3.5:9b\nHERMES_NUM_CTX=not-a-number\n')"
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no ollama_num_ctx line for non-numeric value" "ollama_num_ctx:" "${config_out}"
assert_contains "model still configured" "default: 'qwen3.5:9b'" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 12b: HERMES_NUM_CTX=0 is treated as unset on the generation path ────
# Mirrors the reconcile path: 0 is not a meaningful window, so neither key is
# written (the validation accepts only positive integers).
echo "test: HERMES_NUM_CTX=0 is ignored on first-boot generation"
data_dir="$(mktemp -d)"
fixture="$(printf 'HERMES_DEFAULT_MODEL=qwen3.5:9b\nHERMES_NUM_CTX=0\n')"
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no ollama_num_ctx line for zero" "ollama_num_ctx:" "${config_out}"
assert_not_contains "no context_length line for zero" "context_length:" "${config_out}"
assert_contains "model still configured" "default: 'qwen3.5:9b'" "${config_out}"
rm -rf "${data_dir}"

# ─── Auxiliary-providers tests ────────────────────────────────────────────────
# These exercise the native-only aux block. Set the flag explicitly with export so
# the flag-OFF case (Test 16) is deterministic regardless of shell assignment
# persistence; unset it before that case.
export CI_HERMES_OLLAMA_NATIVE=1

# ─── Test 13: auxiliary side-tasks point at the local endpoint (flag ON) ──────
# With native mode on + the local ollama endpoint, write an auxiliary: block so
# compression/title/vision/etc. resolve to the local Ollama instead of failing aux
# auto-detection. (Native flag required; api_key sentinel must be "ollama".)
echo "test: auxiliary block written when native flag on + local ollama endpoint"
data_dir="$(mktemp -d)"
fixture="$(printf 'HERMES_DEFAULT_MODEL=gemma4:e2b\nHERMES_OPENAI_BASE_URL=http://host.docker.internal:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n')"
run_with_fixture_in_dir "${fixture}" "${data_dir}" "172.17.0.1"
config_out="$(cat "${data_dir}/config.yaml")"
assert_contains "auxiliary section present" "auxiliary:" "${config_out}"
assert_contains "compression task present" "  compression:" "${config_out}"
assert_contains "title_generation task present" "  title_generation:" "${config_out}"
assert_contains "vision task present" "  vision:" "${config_out}"
assert_contains "aux base_url at local ollama (host rewritten)" "base_url: 'http://172.17.0.1:11434/v1'" "${config_out}"
assert_contains "aux api_key is the local sentinel" "api_key: 'ollama'" "${config_out}"
assert_contains "aux model set" "model: 'gemma4:e2b'" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 14: no auxiliary block when the endpoint is unknown (flag on) ───────
echo "test: no auxiliary block when HERMES_OPENAI_BASE_URL is absent"
data_dir="$(mktemp -d)"
fixture="$(printf 'HERMES_DEFAULT_MODEL=gemma4:e2b\nHERMES_NUM_CTX=65536\n')"
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no auxiliary section without an endpoint" "auxiliary:" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 15: cloud endpoint (api_key != ollama) → no auxiliary block ─────────
# Never embed a non-local API key in config.yaml or change cloud aux behavior.
echo "test: no auxiliary block / no key leak when the endpoint is a cloud provider"
data_dir="$(mktemp -d)"
fixture="$(printf 'HERMES_DEFAULT_MODEL=gpt-4o\nHERMES_OPENAI_BASE_URL=https://api.openai.com/v1\nHERMES_OPENAI_API_KEY=sk-secret-cloud-key\n')"
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no auxiliary section for cloud endpoint" "auxiliary:" "${config_out}"
assert_not_contains "cloud api key never written to config.yaml" "sk-secret-cloud-key" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 16: native flag OFF → no auxiliary block (true no-op) ───────────────
unset CI_HERMES_OLLAMA_NATIVE
echo "test: no auxiliary block when CI_HERMES_OLLAMA_NATIVE is off"
data_dir="$(mktemp -d)"
fixture="$(printf 'HERMES_DEFAULT_MODEL=gemma4:e2b\nHERMES_OPENAI_BASE_URL=http://host.docker.internal:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n')"
run_with_fixture_in_dir "${fixture}" "${data_dir}" "172.17.0.1"
config_out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no auxiliary section with flag off" "auxiliary:" "${config_out}"
rm -rf "${data_dir}"

# ─── Summary ────────────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
