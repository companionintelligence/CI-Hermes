#!/bin/bash
# Tests for bootstrap-from-hub.sh.
# Most tests use BOOTSTRAP_FIXTURE_FILE to bypass the real curl. Test 27 needs the
# real request timing, so it runs a local python3 HTTP server instead.
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

# ─── Test 1: LOCAL endpoint (api_key sentinel "ollama") → no endpoint/model aliases ──
# config.yaml carries the Hub's own endpoint and the model. Upstream, env
# CUSTOM_BASE_URL outranks config model.base_url and HERMES_INFERENCE_MODEL outranks
# model.default, for the life of the process — so exporting them froze every running
# process on the handout it started with (core-4, 2026-09-17). The OpenAI-SDK aliases
# stay suppressed too: they make the model picker mislabel the local box as the
# cloud "openai-api" provider.
echo "test: local endpoint exports no endpoint or model aliases (config.yaml owns them)"
fixture=$'HERMES_OPENAI_BASE_URL=http://ci-hub-ollama:11434/v1\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL=hermes4-70b\nHERMES_DEFAULT_MODEL_BACKEND_ID=hermes4:70b\nHERMES_EMBEDDINGS_MODEL=nomic-embed-text\n'
out="$(run_with_fixture "${fixture}")"
assert_no_line "OPENAI_API_BASE suppressed for local" "OPENAI_API_BASE=" "${out}"
assert_no_line "OPENAI_BASE_URL suppressed for local" "OPENAI_BASE_URL=" "${out}"
assert_no_line "OPENAI_API_KEY suppressed for local" "OPENAI_API_KEY=" "${out}"
assert_no_line "CUSTOM_BASE_URL not exported (would outrank model.base_url)" "CUSTOM_BASE_URL=" "${out}"
assert_no_line "CUSTOM_API_KEY not exported" "CUSTOM_API_KEY=" "${out}"
assert_no_line "OPENAI_MODEL not exported (dead upstream)" "OPENAI_MODEL=" "${out}"
assert_no_line "HERMES_INFERENCE_MODEL not exported (would outrank model.default)" "HERMES_INFERENCE_MODEL=" "${out}"
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
assert_line "cloud CUSTOM_API_KEY present" "CUSTOM_API_KEY=sk-real-cloud" "${out}"
assert_no_line "cloud: no HERMES_INFERENCE_MODEL either (model.default owns the model)" "HERMES_INFERENCE_MODEL=" "${out}"
assert_no_line "cloud: no OPENAI_MODEL" "OPENAI_MODEL=" "${out}"

# ─── Test 1b: backend id becomes the model fallback when plain default model is absent ──
echo "test: backend id becomes model.default when plain default model is absent"
data_dir="$(mktemp -d)"
fixture=$'HERMES_OPENAI_BASE_URL=http://ci-hub-ollama:11434/v1\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL_BACKEND_ID=qwen3.5:9b\n'
run_with_fixture_in_dir "${fixture}" "${data_dir}"
out="$(cat "${data_dir}/.env.hub-bootstrap")"
assert_contains "backend id preserved" "HERMES_DEFAULT_MODEL_BACKEND_ID=qwen3.5:9b" "${out}"
assert_no_line "no model alias exported" "HERMES_INFERENCE_MODEL=" "${out}"
assert_contains "config model.default from backend id" "default: 'qwen3.5:9b'" "$(cat "${data_dir}/config.yaml")"
rm -rf "${data_dir}"

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

# ─── Test 7: a user-authored config.yaml is not overwritten ──────────────────
# Nothing here was written by this bootstrap (no ownership record, no Hub-written
# picker entry), so the model is the user's and the handout does not replace it.
echo "test: a user-authored config.yaml is preserved"
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

# ═══ Handout changes after first boot ═══════════════════════════════════════
# config.yaml used to be generated once and never again, so a changed handout
# never reached model.default / model.base_url / providers.ollama / auxiliary.*.
# Found live on core-4 (2026-09-17): a first-boot gemma3:1b pointed straight at host
# Ollama (32,768 tokens, below the 64K minimum) long after the Hub had moved the app
# to the pool with qwen3-coder:30b / 65536.

# cfg <data_dir> <dotted.path> → the parsed value ("<absent>" when missing).
cfg() {
  python3 - "$1/config.yaml" "$2" <<'PY' || echo "<unreadable>"
import sys, yaml
node = yaml.safe_load(open(sys.argv[1])) or {}
for part in sys.argv[2].split("."):
    if not isinstance(node, dict) or part not in node:
        print("<absent>"); sys.exit(0)
    node = node[part]
print(node)
PY
}

POOL=http://ci-os-hub:5002/api/inference/pool/v1
HOST_OLLAMA=http://172.17.0.1:11434/v1
POOL_HANDOUT="$(printf 'HERMES_OPENAI_BASE_URL=%s\nHERMES_OPENAI_API_KEY=ollama\nCI_INFERENCE_BACKEND=ollama\nHERMES_DEFAULT_MODEL=qwen3-coder:30b\nHERMES_EMBEDDINGS_MODEL=nomic-embed-text\nOLLAMA_HOST=http://ci-os-hub:5002/api/inference/pool\nHERMES_NUM_CTX=65536\n' "${POOL}")"

# The config and env file v2026.8.9 left on core-4, written for the first-boot handout.
seed_core4_before() {
  local d="$1"
  cat > "${d}/config.yaml" <<YAML
model:
  provider: ollama
  default: 'gemma3:1b'
  base_url: '${HOST_OLLAMA}'
  api_key: 'ollama'
  ollama_num_ctx: 32768
providers:
  ollama:
    name: 'Ollama (local)'
    base_url: '${HOST_OLLAMA}'
    api_key: 'ollama'
auxiliary:
$(for t in compression title_generation vision web_extract session_search skills_hub mcp; do printf "  %s:\n    base_url: '%s'\n    api_key: 'ollama'\n    model: 'gemma3:1b'\n" "$t" "${HOST_OLLAMA}"; done)
mcp_servers:
  hub:
    url: "http://ci-os-hub:5002/api/mcp"
    headers:
      Authorization: "Bearer test-token"
    timeout: 180

skills:
  external_dirs:
    - /app/ci-context/skills

plugins:
  enabled:
    - ci-runtime
YAML
  printf 'CUSTOM_BASE_URL=%s\nHERMES_OPENAI_BASE_URL=%s\nCUSTOM_API_KEY=ollama\nHERMES_OPENAI_API_KEY=ollama\nOPENAI_MODEL=gemma3:1b\nHERMES_INFERENCE_MODEL=gemma3:1b\nHERMES_DEFAULT_MODEL=gemma3:1b\nHERMES_NUM_CTX=32768\n' "${HOST_OLLAMA}" "${HOST_OLLAMA}" > "${d}/.env.hub-bootstrap"
}

export CI_HERMES_OLLAMA_NATIVE=1

# ─── Test 17: core-4 regression — an old install follows the new handout ─────
echo "test: core-4 regression: a pre-upgrade config follows the pool handout"
data_dir="$(mktemp -d)"
seed_core4_before "${data_dir}"
run_with_fixture_in_dir "${POOL_HANDOUT}" "${data_dir}"
assert_eq "model.default follows the handout" "qwen3-coder:30b" "$(cfg "${data_dir}" model.default)"
assert_eq "model.base_url follows the handout" "${POOL}" "$(cfg "${data_dir}" model.base_url)"
assert_eq "model.ollama_num_ctx follows" "65536" "$(cfg "${data_dir}" model.ollama_num_ctx)"
assert_eq "model.context_length pinned (>=64K)" "65536" "$(cfg "${data_dir}" model.context_length)"
assert_eq "providers.ollama.base_url follows" "${POOL}" "$(cfg "${data_dir}" providers.ollama.base_url)"
for t in compression title_generation vision web_extract session_search skills_hub mcp; do
  assert_eq "auxiliary.${t}.base_url follows" "${POOL}" "$(cfg "${data_dir}" auxiliary.${t}.base_url)"
  assert_eq "auxiliary.${t}.model follows" "qwen3-coder:30b" "$(cfg "${data_dir}" auxiliary.${t}.model)"
done
assert_eq "unmanaged mcp_servers untouched" "Bearer test-token" "$(cfg "${data_dir}" mcp_servers.hub.headers.Authorization)"
env_out="$(cat "${data_dir}/.env.hub-bootstrap")"
assert_no_line "env: no CUSTOM_BASE_URL outranking model.base_url" "CUSTOM_BASE_URL=" "${env_out}"
assert_no_line "env: no HERMES_INFERENCE_MODEL outranking model.default" "HERMES_INFERENCE_MODEL=" "${env_out}"
assert_no_line "env: no OPENAI_MODEL" "OPENAI_MODEL=" "${env_out}"
state_out="$(cat "${data_dir}/.hub-managed-config.json" 2>/dev/null || true)"
assert_contains "ownership recorded for model.default" '"model.default": "qwen3-coder:30b"' "${state_out}"
assert_eq "no warning for a >=64K handout" "no" "$([[ -e "${data_dir}/.hub-inference-warning" ]] && echo yes || echo no)"
rm -rf "${data_dir}"

# ─── Test 18: every later handout change is followed ───────────────────────────
echo "test: a generated config follows two successive handout changes"
data_dir="$(mktemp -d)"
run_with_fixture_in_dir "$(printf 'HERMES_OPENAI_BASE_URL=%s\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL=qwen3.5:9b\nHERMES_NUM_CTX=65536\n' "${HOST_OLLAMA}")" "${data_dir}"
run_with_fixture_in_dir "${POOL_HANDOUT}" "${data_dir}"
assert_eq "first change: model" "qwen3-coder:30b" "$(cfg "${data_dir}" model.default)"
assert_eq "first change: endpoint" "${POOL}" "$(cfg "${data_dir}" model.base_url)"
run_with_fixture_in_dir "$(printf 'HERMES_OPENAI_BASE_URL=%s\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL=qwen3.6:27b\nHERMES_NUM_CTX=131072\n' "${POOL}")" "${data_dir}"
assert_eq "second change: model" "qwen3.6:27b" "$(cfg "${data_dir}" model.default)"
assert_eq "second change: aux model" "qwen3.6:27b" "$(cfg "${data_dir}" auxiliary.vision.model)"
assert_eq "second change: window" "131072" "$(cfg "${data_dir}" model.context_length)"
rm -rf "${data_dir}"

# ─── Test 19: a GUI model switch survives a handout change ─────────────────────
# Hermes re-dumps config.yaml with yaml.dump on a GUI change (unquoted scalars).
echo "test: a user's model switch is kept while the Hub endpoint still follows"
data_dir="$(mktemp -d)"
run_with_fixture_in_dir "$(printf 'HERMES_OPENAI_BASE_URL=%s\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL=qwen3.5:9b\nHERMES_NUM_CTX=65536\n' "${HOST_OLLAMA}")" "${data_dir}"
python3 - "${data_dir}/config.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); d["model"]["default"] = "llama3.3:70b"
yaml.dump(d, open(p, "w"), default_flow_style=False, sort_keys=False)
PY
log_out="$(HERMES_HOME="${data_dir}" BOOTSTRAP_FIXTURE_FILE=<(printf '%s\n' "${POOL_HANDOUT}") "${SCRIPT}" 2>&1)"
assert_eq "user model kept" "llama3.3:70b" "$(cfg "${data_dir}" model.default)"
assert_eq "Hub endpoint still follows" "${POOL}" "$(cfg "${data_dir}" model.base_url)"
assert_contains "the kept value is logged" "kept user-set model.default='llama3.3:70b' (Hub handout: 'qwen3-coder:30b')" "${log_out}"
# Picking the Hub's model again hands the key back to the Hub.
python3 - "${data_dir}/config.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; d = yaml.safe_load(open(p)); d["model"]["default"] = "qwen3.5:9b"
yaml.dump(d, open(p, "w"), default_flow_style=False, sort_keys=False)
PY
run_with_fixture_in_dir "${POOL_HANDOUT}" "${data_dir}"
assert_eq "reverting to the recorded Hub model resumes management" "qwen3-coder:30b" "$(cfg "${data_dir}" model.default)"
rm -rf "${data_dir}"

# ─── Test 19b: adoption tells a pre-upgrade GUI switch from a stale Hub model ──
echo "test: adoption keeps a model the user picked before the upgrade"
data_dir="$(mktemp -d)"
seed_core4_before "${data_dir}"
sed -i.bak "s/^  default: 'gemma3:1b'$/  default: 'mistral-small:24b'/" "${data_dir}/config.yaml" && rm -f "${data_dir}/config.yaml.bak"
run_with_fixture_in_dir "${POOL_HANDOUT}" "${data_dir}"
assert_eq "pre-upgrade user model kept (aux still carried the Hub's)" "mistral-small:24b" "$(cfg "${data_dir}" model.default)"
assert_eq "endpoint still adopted and followed" "${POOL}" "$(cfg "${data_dir}" model.base_url)"
assert_eq "aux model adopted and followed" "qwen3-coder:30b" "$(cfg "${data_dir}" auxiliary.compression.model)"
rm -rf "${data_dir}"

# ─── Test 20: a user's own endpoint survives a handout change ──────────────────
echo "test: a hand-edited model.base_url is kept across handout changes"
data_dir="$(mktemp -d)"
run_with_fixture_in_dir "${POOL_HANDOUT}" "${data_dir}"
sed -i.bak "s#^  base_url: '${POOL}'\$#  base_url: 'http://my-own-box:11434/v1'#" "${data_dir}/config.yaml" && rm -f "${data_dir}/config.yaml.bak"
run_with_fixture_in_dir "$(printf 'HERMES_OPENAI_BASE_URL=%s\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL=qwen3.6:27b\nHERMES_NUM_CTX=65536\n' "${HOST_OLLAMA}")" "${data_dir}"
assert_eq "user endpoint kept" "http://my-own-box:11434/v1" "$(cfg "${data_dir}" model.base_url)"
assert_eq "Hub-owned model still follows" "qwen3.6:27b" "$(cfg "${data_dir}" model.default)"
assert_eq "Hub-owned picker entry follows" "${HOST_OLLAMA}" "$(cfg "${data_dir}" providers.ollama.base_url)"
rm -rf "${data_dir}"

# ─── Test 21: a handout below the 64K minimum is refused, loudly ──────────────
echo "test: switching to a sub-64K handout model is refused and surfaced"
data_dir="$(mktemp -d)"
run_with_fixture_in_dir "${POOL_HANDOUT}" "${data_dir}"
small="$(printf 'HERMES_OPENAI_BASE_URL=%s\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL=gemma3:1b\nHERMES_NUM_CTX=32768\n' "${HOST_OLLAMA}")"
log_out="$(HERMES_HOME="${data_dir}" BOOTSTRAP_FIXTURE_FILE=<(printf '%s\n' "${small}") "${SCRIPT}" 2>&1)"
assert_eq "working Hub model kept" "qwen3-coder:30b" "$(cfg "${data_dir}" model.default)"
assert_eq "its endpoint kept with it" "${POOL}" "$(cfg "${data_dir}" model.base_url)"
assert_eq "its window kept with it" "65536" "$(cfg "${data_dir}" model.context_length)"
assert_contains "ERROR in the container log" "ERROR: The Hub (Settings -> AI) hands Hermes model 'gemma3:1b' with a 32768-token context window, below Hermes' 64000-token minimum." "${log_out}"
warning="$(cat "${data_dir}/.hub-inference-warning" 2>/dev/null || true)"
assert_contains "warning file for the terminal names the model" "'gemma3:1b'" "${warning}"
assert_contains "warning file says what was kept" "kept the previous Hub model 'qwen3-coder:30b'" "${warning}"
run_with_fixture_in_dir "${POOL_HANDOUT}" "${data_dir}"
assert_eq "warning cleared once the handout is usable" "no" "$([[ -e "${data_dir}/.hub-inference-warning" ]] && echo yes || echo no)"
rm -rf "${data_dir}"

# ─── Test 21b: with nothing to keep, a sub-64K handout is applied and surfaced ─
echo "test: a first-boot sub-64K handout is written, with the warning"
data_dir="$(mktemp -d)"
run_with_fixture_in_dir "${small}" "${data_dir}"
assert_eq "model written (nothing better to keep)" "gemma3:1b" "$(cfg "${data_dir}" model.default)"
assert_eq "no context_length below the minimum" "<absent>" "$(cfg "${data_dir}" model.context_length)"
assert_contains "warning says Hermes will refuse it" "Hermes will refuse to start a session with it" "$(cat "${data_dir}/.hub-inference-warning" 2>/dev/null || true)"
rm -rf "${data_dir}"

# ─── Test 22: a cloud handout does not displace the Hub endpoint ──────────────
# The Hub hands out its first cloud provider whenever local inference is unhealthy at
# fetch time. Following that would move every conversation to a paid provider until
# the next restart — and writing the cloud model over a local endpoint would break
# every request. config.yaml keeps the Hub's local settings and the log says why.
echo "test: a cloud handout leaves a Hub-managed local config alone, loudly"
data_dir="$(mktemp -d)"
run_with_fixture_in_dir "${POOL_HANDOUT}" "${data_dir}"
before="$(shasum "${data_dir}/config.yaml" | awk '{print $1}')"
cloud=$'HERMES_OPENAI_BASE_URL=https://api.openai.com/v1\nHERMES_OPENAI_API_KEY=sk-secret-cloud\nHERMES_DEFAULT_MODEL=gpt-4o\n'
log_out="$(HERMES_HOME="${data_dir}" BOOTSTRAP_FIXTURE_FILE=<(printf '%s' "${cloud}") "${SCRIPT}" 2>&1)"
assert_eq "config.yaml unchanged" "${before}" "$(shasum "${data_dir}/config.yaml" | awk '{print $1}')"
assert_eq "local model kept" "qwen3-coder:30b" "$(cfg "${data_dir}" model.default)"
assert_contains "the kept handout is logged" "the Hub handed out a cloud provider" "${log_out}"
assert_not_contains "cloud key never in config.yaml" "sk-secret-cloud" "$(cat "${data_dir}/config.yaml")"
assert_not_contains "cloud key never in the ownership record" "sk-secret-cloud" "$(cat "${data_dir}/.hub-managed-config.json" 2>/dev/null || true)"
assert_no_line "no model override exported for the cloud handout either" "HERMES_INFERENCE_MODEL=" "$(cat "${data_dir}/.env.hub-bootstrap")"
run_with_fixture_in_dir "$(printf 'HERMES_OPENAI_BASE_URL=%s\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL=qwen3.6:27b\nHERMES_NUM_CTX=65536\n' "${POOL}")" "${data_dir}"
assert_eq "local handout again: followed" "qwen3.6:27b" "$(cfg "${data_dir}" model.default)"
rm -rf "${data_dir}"

# ─── Test 22b: a cloud-only install follows its cloud handout ─────────────────
echo "test: an install with no Hub endpoint follows cloud model changes"
data_dir="$(mktemp -d)"
run_with_fixture_in_dir "${cloud}" "${data_dir}"
run_with_fixture_in_dir $'HERMES_OPENAI_BASE_URL=https://api.openai.com/v1\nHERMES_OPENAI_API_KEY=sk-secret-cloud\nHERMES_DEFAULT_MODEL=gpt-5\n' "${data_dir}"
assert_eq "cloud model follows" "gpt-5" "$(cfg "${data_dir}" model.default)"
assert_eq "no local endpoint invented" "<absent>" "$(cfg "${data_dir}" model.base_url)"
assert_line "cloud endpoint travels in env" "CUSTOM_BASE_URL=https://api.openai.com/v1" "$(cat "${data_dir}/.env.hub-bootstrap")"
assert_not_contains "cloud key never in config.yaml" "sk-secret-cloud" "$(cat "${data_dir}/config.yaml")"
rm -rf "${data_dir}"

# ─── Test 23: Hub unreachable → the last handout (from an older image) still converges ─
echo "test: with the Hub unreachable, an old env file is cleaned and config.yaml reconciled"
data_dir="$(mktemp -d)"
seed_core4_before "${data_dir}"
printf 'CUSTOM_BASE_URL=%s\nHERMES_OPENAI_BASE_URL=%s\nCUSTOM_API_KEY=ollama\nHERMES_OPENAI_API_KEY=ollama\nOPENAI_MODEL=qwen3-coder:30b\nHERMES_INFERENCE_MODEL=qwen3-coder:30b\nHERMES_DEFAULT_MODEL=qwen3-coder:30b\nHERMES_NUM_CTX=65536\n' "${POOL}" "${POOL}" > "${data_dir}/.env.hub-bootstrap"
HERMES_HOME="${data_dir}" CI_HUB_URL="http://127.0.0.1:1" "${SCRIPT}" >/dev/null 2>&1
env_out="$(cat "${data_dir}/.env.hub-bootstrap")"
assert_no_line "stale CUSTOM_BASE_URL removed" "CUSTOM_BASE_URL=" "${env_out}"
assert_no_line "stale HERMES_INFERENCE_MODEL removed" "HERMES_INFERENCE_MODEL=" "${env_out}"
assert_line "handout itself kept" "HERMES_DEFAULT_MODEL=qwen3-coder:30b" "${env_out}"
assert_eq "config reconciled from the last handout" "qwen3-coder:30b" "$(cfg "${data_dir}" model.default)"
assert_eq "endpoint reconciled from the last handout" "${POOL}" "$(cfg "${data_dir}" model.base_url)"
rm -rf "${data_dir}"

# ─── Test 24: a converged config is not rewritten ──────────────────────────────
echo "test: an unchanged handout leaves config.yaml and the record byte-identical"
data_dir="$(mktemp -d)"
seed_core4_before "${data_dir}"
run_with_fixture_in_dir "${POOL_HANDOUT}" "${data_dir}"
h1="$(shasum "${data_dir}/config.yaml" "${data_dir}/.hub-managed-config.json" 2>/dev/null | awk '{print $1}' || true)"
touch -t 202001010000 "${data_dir}/config.yaml"
m1="$(ls -l "${data_dir}/config.yaml")"
run_with_fixture_in_dir "${POOL_HANDOUT}" "${data_dir}"
h2="$(shasum "${data_dir}/config.yaml" "${data_dir}/.hub-managed-config.json" 2>/dev/null | awk '{print $1}' || true)"
assert_eq "same bytes" "${h1}" "${h2}"
assert_eq "config.yaml not rewritten (mtime kept)" "${m1}" "$(ls -l "${data_dir}/config.yaml")"
rm -rf "${data_dir}"

# ─── Test 25: comments and unmanaged layout survive ────────────────────────────
echo "test: a user's comments survive a reconcile"
data_dir="$(mktemp -d)"
seed_core4_before "${data_dir}"
sed -i.bak 's/^model:$/# my notes about the model\nmodel:  # keep me/' "${data_dir}/config.yaml" && rm -f "${data_dir}/config.yaml.bak"
run_with_fixture_in_dir "${POOL_HANDOUT}" "${data_dir}"
assert_contains "top comment kept" "# my notes about the model" "$(cat "${data_dir}/config.yaml")"
assert_contains "inline comment kept" "model:  # keep me" "$(cat "${data_dir}/config.yaml")"
assert_eq "and the model still follows" "qwen3-coder:30b" "$(cfg "${data_dir}" model.default)"
rm -rf "${data_dir}"

# ─── Test 26: web and gateway start at once on one volume ──────────────────────
echo "test: concurrent bootstraps on a shared data dir converge on valid YAML"
for round in 1 2 3; do
  data_dir="$(mktemp -d)"
  seed_core4_before "${data_dir}"
  fx="$(mktemp)"; printf '%s\n' "${POOL_HANDOUT}" > "${fx}"
  HERMES_HOME="${data_dir}" BOOTSTRAP_FIXTURE_FILE="${fx}" "${SCRIPT}" >/dev/null 2>&1 &
  HERMES_HOME="${data_dir}" BOOTSTRAP_FIXTURE_FILE="${fx}" "${SCRIPT}" >/dev/null 2>&1 &
  wait
  assert_eq "round ${round}: model" "qwen3-coder:30b" "$(cfg "${data_dir}" model.default)"
  assert_eq "round ${round}: single model: key" "1" "$(grep -c '^model:' "${data_dir}/config.yaml")"
  assert_eq "round ${round}: single base_url in model" "1" "$(grep -c "^  base_url:" "${data_dir}/config.yaml")"
  assert_eq "round ${round}: no temp files left" "" "$(ls -A "${data_dir}" | grep -E '^\.(env\.hub-bootstrap|config\.yaml|\.hub-managed-config\.json)\.' || true)"
  rm -rf "${data_dir}" "${fx}"
done

unset CI_HERMES_OLLAMA_NATIVE

# ─── Test 27: a slow first handout still arrives ────────────────────────────────
# A Hub's first handout after it starts can take 10 s (it probes Ollama addresses
# that may not answer, 3 s each). With --max-time 5 both tries timed out and Hermes
# started with no model and no config.yaml. This Hub answers after 6 s.
slow_hub() {  # $1 delay seconds, $2 file to write the port to
  python3 -c '
import http.server, sys, time
delay = float(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(delay)
        body = b"HERMES_DEFAULT_MODEL=qwen3.5:9b\nHERMES_OPENAI_API_KEY=ollama\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()
' "$1" "$2" &
}

if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  echo "test: a handout that takes 6 s to arrive is still written"
  data_dir="$(mktemp -d)"
  port_file="$(mktemp)"
  slow_hub 6 "${port_file}"
  hub_pid=$!
  for _ in $(seq 1 50); do [[ -s "${port_file}" ]] && break; sleep 0.1; done
  assert_eq "test Hub started" "yes" "$([[ -s "${port_file}" ]] && echo yes || echo no)"
  HERMES_HOME="${data_dir}" CI_HUB_URL="http://127.0.0.1:$(cat "${port_file}")" "${SCRIPT}" >/dev/null 2>&1 || true
  assert_contains "handout written" "HERMES_DEFAULT_MODEL=qwen3.5:9b" "$(cat "${data_dir}/.env.hub-bootstrap" 2>/dev/null || true)"

  echo "test: HUB_BOOTSTRAP_TIMEOUT still bounds the wait"
  rm -f "${data_dir}/.env.hub-bootstrap"
  start=$(date +%s)
  HERMES_HOME="${data_dir}" HUB_BOOTSTRAP_TIMEOUT=1 CI_HUB_URL="http://127.0.0.1:$(cat "${port_file}")" "${SCRIPT}" >/dev/null 2>&1 || true
  took=$(( $(date +%s) - start ))
  assert_eq "no handout when the Hub is slower than the limit" "no" "$([[ -f "${data_dir}/.env.hub-bootstrap" ]] && echo yes || echo no)"
  # 2 tries of 1 s plus the 2 s delay is 4 s. The lower bound proves both tries
  # waited; a request that failed at once would also leave no handout.
  assert_eq "waited for both tries (at least 3 s)" "yes" "$([[ ${took} -ge 3 ]] && echo yes || echo no)"
  assert_eq "gave up within the limit (2 tries of 1 s plus 2 s delay)" "yes" "$([[ ${took} -le 6 ]] && echo yes || echo no)"
  kill "${hub_pid}" 2>/dev/null || true
  wait "${hub_pid}" 2>/dev/null || true
  rm -rf "${data_dir}" "${port_file}"
else
  echo "test: SKIPPED slow-handout tests (need python3 and curl)" >&2
fi

echo "test: HUB_BOOTSTRAP_TIMEOUT=0 or a non-number falls back to 20 s"
# curl reads --max-time 0 as no limit and exits at once on a non-number.
data_dir="$(mktemp -d)"
for bad in 0 abc 1.5 -3; do
  out="$(HERMES_HOME="${data_dir}" HUB_BOOTSTRAP_TIMEOUT="${bad}" CI_HUB_URL="http://127.0.0.1:1" "${SCRIPT}" 2>&1 || true)"
  assert_contains "HUB_BOOTSTRAP_TIMEOUT=${bad} is refused" "HUB_BOOTSTRAP_TIMEOUT=${bad} is not a positive whole number of seconds; using 20" "${out}"
done
out="$(HERMES_HOME="${data_dir}" HUB_BOOTSTRAP_TIMEOUT=7 CI_HUB_URL="http://127.0.0.1:1" "${SCRIPT}" 2>&1 || true)"
assert_not_contains "HUB_BOOTSTRAP_TIMEOUT=7 is accepted" "not a positive whole number" "${out}"
rm -rf "${data_dir}"

# ─── Summary ────────────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
