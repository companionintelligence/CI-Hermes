#!/bin/bash
# End to end: after a Hub handout change and a normal app restart through the Hub,
# the web container (dashboard + terminal sessions) and the gateway container must
# run the same model and endpoint — and a config.yaml corrected while they run must
# reach them without one.
#
# Runs the real entrypoint.sh and gateway-entrypoint.sh, at the same time, on one
# shared data dir — as the Hub restarts the app — with the real bootstrap scripts,
# reconciler and env loaders. `hermes` is tests/fixtures/fake_hermes.py, which
# resolves the model and endpoint with upstream Hermes' precedence and records it;
# the Node server is tests/fixtures/fake-server.cjs, which opens a terminal session
# through the real hub-env.cjs.
#
# Found live on core-4 (2026-09-17): config.yaml still named a first-boot gemma3:1b
# on host Ollama while the Hub handed out the pool with qwen3-coder:30b, and env
# CUSTOM_BASE_URL / HERMES_INFERENCE_MODEL would have outranked a corrected
# config.yaml in every running process anyway.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

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

if ! command -v node >/dev/null 2>&1 || ! python3 -c "import yaml" 2>/dev/null; then
  echo "hub-handout-restart: needs node and python3 with PyYAML" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# /app as the image lays it out, pointing at this checkout.
app="${work}/app"
mkdir -p "${app}"
for f in bootstrap-from-hub.sh bootstrap-ci-context.sh reconcile-hub-config.py hub-env.sh hub-env.cjs entrypoint.sh gateway-entrypoint.sh; do
  ln -s "${ROOT}/${f}" "${app}/${f}"
done
ln -s "${HERE}/fixtures/fake-server.cjs" "${app}/server.cjs"

# A venv whose `hermes` is the fake.
venv="${work}/venv"
mkdir -p "${venv}/bin"
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "${HERE}/fixtures/fake_hermes.py" > "${venv}/bin/hermes"
chmod +x "${venv}/bin/hermes"
printf 'export PATH="%s/bin:${PATH}"\n' "${venv}" > "${venv}/bin/activate"

data="${work}/data"
out="${work}/out"
mkdir -p "${data}"

POOL=http://ci-os-hub:5002/api/inference/pool/v1
POOL_B=http://ci-os-hub-b:5002/api/inference/pool/v1
HOST_OLLAMA=http://172.17.0.1:11434/v1
CLOUD=https://api.openai.com/v1

handout_local() {  # base model num_ctx
  printf 'HERMES_OPENAI_BASE_URL=%s\nHERMES_OPENAI_API_KEY=ollama\nCI_INFERENCE_BACKEND=ollama\nHERMES_DEFAULT_MODEL=%s\nHERMES_EMBEDDINGS_MODEL=nomic-embed-text\nHERMES_NUM_CTX=%s\n' "$1" "$2" "$3"
}

container_env() {
  env -i PATH="${PATH}" HOME="${work}" HERMES_HOME="${data}" \
    CI_HERMES_APP_DIR="${app}" CI_HERMES_VENV="${venv}" \
    BOOTSTRAP_FIXTURE_FILE="${work}/handout.env" DOCKER_HOST_GATEWAY_IP=192.0.2.1 \
    CI_HERMES_OLLAMA_NATIVE=1 FAKE_HERMES_OUT="${out}" "$@"
}

# Restart both containers at once against a handout, as the Hub does.
restart_app() {
  printf '%s\n' "$1" > "${work}/handout.env"
  rm -rf "${out}"
  mkdir -p "${out}"
  local web gateway rc=0
  container_env bash "${app}/entrypoint.sh" > "${work}/web.log" 2>&1 &
  web=$!
  container_env bash "${app}/gateway-entrypoint.sh" gateway run > "${work}/gateway.log" 2>&1 &
  gateway=$!
  wait "${web}" || rc=1
  wait "${gateway}" || rc=1
  if [[ "${rc}" != 0 ]]; then
    echo "  ✗ a container failed to start"
    sed 's/^/    web: /' "${work}/web.log"
    sed 's/^/    gateway: /' "${work}/gateway.log"
    FAIL=$((FAIL + 1))
  fi
}

# field <role> <key> → what that process resolved at start.
field() {
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); v=r["resolved"].get(sys.argv[2]) if sys.argv[2] in r["resolved"] else r["env"].get(sys.argv[2], "<unset>"); print(v)' "${out}/$1.json" "$2" 2>/dev/null || echo "<no record>"
}

# replay <role> <key> → what that still-running process resolves NOW, with the env
# it started with and the current config.yaml.
replay() {
  python3 "${HERE}/fixtures/fake_hermes.py" --replay "${out}/$1.json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"
}

expect_all() {  # label key want
  local role
  for role in dashboard terminal gateway; do
    assert_eq "$1: ${role} $2" "$3" "$(field "${role}" "$2")"
  done
}

# The data dir v2026.8.9 left on core-4: config.yaml from the first-boot handout,
# and an env file that exports the overrides.
seed_core4() {
  cat > "${data}/config.yaml" <<YAML
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
YAML
  printf 'CUSTOM_BASE_URL=%s\nHERMES_OPENAI_BASE_URL=%s\nCUSTOM_API_KEY=ollama\nHERMES_OPENAI_API_KEY=ollama\nOPENAI_MODEL=gemma3:1b\nHERMES_INFERENCE_MODEL=gemma3:1b\nHERMES_DEFAULT_MODEL=gemma3:1b\nHERMES_NUM_CTX=32768\n' \
    "${HOST_OLLAMA}" "${HOST_OLLAMA}" > "${data}/.env.hub-bootstrap"
}

echo "test: core-4 upgrade — restart on the pool handout; web and gateway agree"
seed_core4
restart_app "$(handout_local "${POOL}" qwen3-coder:30b 65536)"
expect_all "pool" model "qwen3-coder:30b"
expect_all "pool" model_from "config"
expect_all "pool" base_url "${POOL}"
expect_all "pool" base_url_from "providers.ollama"
expect_all "pool" context_length "65536"
expect_all "pool" starts "True"
expect_all "pool" CUSTOM_BASE_URL "<unset>"
expect_all "pool" HERMES_INFERENCE_MODEL "<unset>"

echo "test: a config.yaml corrected mid-run reaches the running dashboard and gateway"
# A terminal session runs bootstrap-from-hub.sh on open (start-hermes.sh); nothing restarts.
printf '%s\n' "$(handout_local "${POOL_B}" qwen3.6:27b 131072)" > "${work}/handout.env"
container_env "${app}/bootstrap-from-hub.sh" > /dev/null 2>&1
for role in dashboard gateway; do
  assert_eq "live: running ${role} model" "qwen3.6:27b" "$(replay "${role}" model)"
  assert_eq "live: running ${role} endpoint" "${POOL_B}" "$(replay "${role}" base_url)"
done

echo "test: a restart on the changed handout; web and gateway agree"
restart_app "$(handout_local "${POOL_B}" qwen3.6:27b 131072)"
expect_all "pool B" model "qwen3.6:27b"
expect_all "pool B" base_url "${POOL_B}"
expect_all "pool B" context_length "131072"

echo "test: a transient cloud handout; web and gateway agree on the Hub endpoint and model"
# The Hub hands out a cloud provider whenever its local inference is down as the app
# fetches. Nobody moves to the paid provider, and nobody asks the local pool for
# the cloud model (the dashboard used to, through HERMES_INFERENCE_MODEL).
restart_app "$(printf 'HERMES_OPENAI_BASE_URL=%s\nHERMES_OPENAI_API_KEY=sk-test-cloud\nCI_INFERENCE_BACKEND=cloud\nHERMES_DEFAULT_MODEL=gpt-4o\n' "${CLOUD}")"
expect_all "cloud blip" model "qwen3.6:27b"
expect_all "cloud blip" base_url "${POOL_B}"
expect_all "cloud blip" HERMES_INFERENCE_MODEL "<unset>"
if grep -q "the Hub handed out a cloud provider" "${work}/web.log" "${work}/gateway.log"; then
  echo "  ✓ cloud blip: logged"; PASS=$((PASS + 1))
else
  echo "  ✗ cloud blip: not logged"; FAIL=$((FAIL + 1))
fi

echo "test: back to the Hub endpoint; web and gateway agree"
restart_app "$(handout_local "${POOL}" qwen3-coder:30b 65536)"
expect_all "local again" model "qwen3-coder:30b"
expect_all "local again" base_url "${POOL}"
expect_all "local again" api_key_source "providers.ollama:ollama"
expect_all "local again" CUSTOM_BASE_URL "<unset>"

echo "test: a sub-64K handout after a restart — everyone keeps the working model"
restart_app "$(handout_local "${HOST_OLLAMA}" gemma3:1b 32768)"
expect_all "sub-64K" model "qwen3-coder:30b"
expect_all "sub-64K" base_url "${POOL}"
expect_all "sub-64K" starts "True"
assert_eq "sub-64K: warning left for the terminal" "yes" "$([[ -s "${data}/.hub-inference-warning" ]] && echo yes || echo no)"
if grep -q "below Hermes' 64000-token minimum" "${work}/gateway.log" "${work}/web.log"; then
  echo "  ✓ sub-64K: ERROR in the container logs"; PASS=$((PASS + 1))
else
  echo "  ✗ sub-64K: no ERROR in the container logs"; FAIL=$((FAIL + 1))
fi

echo "test: a cloud-only install; web and gateway agree on the cloud endpoint"
rm -rf "${data}" && mkdir -p "${data}"
restart_app "$(printf 'HERMES_OPENAI_BASE_URL=%s\nHERMES_OPENAI_API_KEY=sk-test-cloud\nCI_INFERENCE_BACKEND=cloud\nHERMES_DEFAULT_MODEL=gpt-4o\n' "${CLOUD}")"
restart_app "$(printf 'HERMES_OPENAI_BASE_URL=%s\nHERMES_OPENAI_API_KEY=sk-test-cloud\nCI_INFERENCE_BACKEND=cloud\nHERMES_DEFAULT_MODEL=gpt-5\n' "${CLOUD}")"
expect_all "cloud only" model "gpt-5"
expect_all "cloud only" base_url "${CLOUD}"
expect_all "cloud only" api_key_source "env:OPENAI_API_KEY"
if grep -q "sk-test-cloud" "${data}/config.yaml" "${data}/.hub-managed-config.json" 2>/dev/null; then
  echo "  ✗ cloud only: the key reached config.yaml or the record"; FAIL=$((FAIL + 1))
else
  echo "  ✓ cloud only: the key stays out of config.yaml and the record"; PASS=$((PASS + 1))
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
