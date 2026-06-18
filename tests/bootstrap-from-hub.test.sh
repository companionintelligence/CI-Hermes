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

# ─── Test 1: HERMES_ keys are translated to OPENAI_* and originals kept ─────
echo "test: translates HERMES_OPENAI_BASE_URL to OPENAI_API_BASE and OPENAI_BASE_URL"
fixture=$'HERMES_OPENAI_BASE_URL=http://ci-hub-ollama:11434/v1\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL=hermes4-70b\nHERMES_DEFAULT_MODEL_BACKEND_ID=hermes4:70b\nHERMES_EMBEDDINGS_MODEL=nomic-embed-text\n'
out="$(run_with_fixture "${fixture}")"
assert_contains "OPENAI_API_BASE present" "OPENAI_API_BASE=http://ci-hub-ollama:11434/v1" "${out}"
assert_contains "OPENAI_BASE_URL alias present" "OPENAI_BASE_URL=http://ci-hub-ollama:11434/v1" "${out}"
assert_contains "CUSTOM_BASE_URL alias present" "CUSTOM_BASE_URL=http://ci-hub-ollama:11434/v1" "${out}"
assert_contains "OPENAI_API_KEY present" "OPENAI_API_KEY=ollama" "${out}"
assert_contains "CUSTOM_API_KEY alias present" "CUSTOM_API_KEY=ollama" "${out}"
assert_contains "OPENAI_MODEL present" "OPENAI_MODEL=hermes4-70b" "${out}"
assert_contains "HERMES_INFERENCE_MODEL alias present" "HERMES_INFERENCE_MODEL=hermes4-70b" "${out}"
assert_contains "OPENAI_EMBEDDINGS_MODEL present" "OPENAI_EMBEDDINGS_MODEL=nomic-embed-text" "${out}"
assert_contains "original HERMES_ key preserved" "HERMES_DEFAULT_MODEL=hermes4-70b" "${out}"
assert_contains "BACKEND_ID passthrough preserved" "HERMES_DEFAULT_MODEL_BACKEND_ID=hermes4:70b" "${out}"

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

# ─── Test 11: numeric HERMES_NUM_CTX is written as model.num_ctx ─────────────
echo "test: numeric HERMES_NUM_CTX is written under model in config.yaml"
data_dir="$(mktemp -d)"
fixture="$(printf 'HERMES_DEFAULT_MODEL=qwen3.5:9b\nHERMES_NUM_CTX=32768\n')"
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_contains "model.num_ctx written from HERMES_NUM_CTX" "num_ctx: 32768" "${config_out}"
rm -rf "${data_dir}"

# ─── Test 12: non-numeric HERMES_NUM_CTX is ignored ─────────────────────────
echo "test: non-numeric HERMES_NUM_CTX is ignored (no num_ctx line)"
data_dir="$(mktemp -d)"
fixture="$(printf 'HERMES_DEFAULT_MODEL=qwen3.5:9b\nHERMES_NUM_CTX=not-a-number\n')"
run_with_fixture_in_dir "${fixture}" "${data_dir}"
config_out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no num_ctx line for non-numeric value" "num_ctx:" "${config_out}"
assert_contains "model still configured" "default: 'qwen3.5:9b'" "${config_out}"
rm -rf "${data_dir}"

# ─── Summary ────────────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
