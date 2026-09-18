#!/bin/bash
# Tests for patches/check_ollama_native_contract.py — the build-time guard that
# refuses an image whose upstream no longer has the functions the ollama-native
# shim hooks. Runs against synthetic source trees so it needs no Hermes checkout;
# the Dockerfile runs the same script against the real /opt/hermes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../patches/check_ollama_native_contract.py"

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
  if echo "${haystack}" | grep -qF -- "${needle}"; then
    echo "  ✓ ${label}"
    PASS=$((PASS + 1))
  else
    echo "  ✗ ${label}"
    echo "    expected to contain: ${needle}"
    echo "    in:                  ${haystack}"
    FAIL=$((FAIL + 1))
  fi
}

# A minimal tree carrying every target the shim hooks, in the shapes the check
# must accept: plain defs, a kw-only signature, a re-export by import, and a
# staticmethod on a class in a file the method search has to find by walking.
make_good_tree() {
  local root="$1"
  mkdir -p "${root}/agent" "${root}/providers" "${root}/hermes_cli"
  cat > "${root}/agent/agent_runtime_helpers.py" <<'PY'
def create_openai_client(agent, client_kwargs: dict, *, reason: str, shared: bool):
    return None
PY
  cat > "${root}/agent/auxiliary_client.py" <<'PY'
def resolve_provider_client(provider, model=None):
    return None, None


def resolve_vision_provider_client(provider=None, model=None, *, base_url=None):
    return None, None, None
PY
  cat > "${root}/providers/__init__.py" <<'PY'
def get_provider_profile(name: str):
    return None
PY
  cat > "${root}/agent/ssl_verify.py" <<'PY'
def resolve_httpx_verify(*, ca_bundle=None, ssl_verify=None, base_url=""):
    return True
PY
  cat > "${root}/hermes_cli/providers.py" <<'PY'
def custom_provider_slug(display_name: str, provider_key: str = "") -> str:
    return display_name
PY
  cat > "${root}/hermes_cli/config_providers.py" <<'PY'
def get_compatible_custom_providers(config=None):
    return []
PY
  cat > "${root}/hermes_cli/config.py" <<'PY'
from hermes_cli.config_providers import (  # noqa: F401  (re-exported)
    get_compatible_custom_providers,
)


def load_config_readonly():
    return {}
PY
  cat > "${root}/agent/client_lifecycle.py" <<'PY'
class ClientLifecycleMixin:
    @staticmethod
    def _build_keepalive_http_client(base_url: str = "", *, verify=True):
        return None
PY
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "contract holds on a complete tree"
make_good_tree "${TMP}/good"
rc=0; out="$(python3 "${SCRIPT}" --root "${TMP}/good" 2>&1)" || rc=$?
assert_eq "exit 0" "0" "${rc}"
assert_contains "reports the count of targets checked" "9 hook targets present" "${out}"
json="$(python3 "${SCRIPT}" --root "${TMP}/good" --json)"
assert_contains "--json says ok" '"ok": true' "${json}"

echo "a renamed hook target fails the build"
make_good_tree "${TMP}/renamed"
sed -i 's/def create_openai_client/def create_openai_client_v2/' "${TMP}/renamed/agent/agent_runtime_helpers.py"
rc=0; out="$(python3 "${SCRIPT}" --root "${TMP}/renamed" 2>&1)" || rc=$?
assert_eq "exit 1" "1" "${rc}"
assert_contains "names the missing function" '`create_openai_client` is no longer bound' "${out}"
assert_contains "explains the consequence" "silently fall back to /v1" "${out}"

echo "a dropped positional parameter fails the build"
make_good_tree "${TMP}/param"
sed -i 's/def create_openai_client(agent, client_kwargs: dict, \*, reason: str, shared: bool)/def create_openai_client(agent, *, reason: str, shared: bool)/' \
  "${TMP}/param/agent/agent_runtime_helpers.py"
rc=0; out="$(python3 "${SCRIPT}" --root "${TMP}/param" 2>&1)" || rc=$?
assert_eq "exit 1" "1" "${rc}"
assert_contains "names the lost parameter" "lost parameter(s) ['client_kwargs']" "${out}"

echo "a re-export that disappears fails the build"
make_good_tree "${TMP}/reexport"
# Drop the whole re-export (the import spans three lines), leaving a valid module.
printf 'def load_config_readonly():\n    return {}\n' > "${TMP}/reexport/hermes_cli/config.py"
rc=0; out="$(python3 "${SCRIPT}" --root "${TMP}/reexport" 2>&1)" || rc=$?
assert_eq "exit 1" "1" "${rc}"
assert_contains "names the missing re-export" '`get_compatible_custom_providers` is no longer bound' "${out}"

echo "the agent method is found wherever upstream keeps it"
make_good_tree "${TMP}/moved"
mv "${TMP}/moved/agent/client_lifecycle.py" "${TMP}/moved/run_agent.py"
rc=0; out="$(python3 "${SCRIPT}" --root "${TMP}/moved" 2>&1)" || rc=$?
assert_eq "exit 0 with the method in run_agent.py" "0" "${rc}"
rm "${TMP}/moved/run_agent.py"
rc=0; out="$(python3 "${SCRIPT}" --root "${TMP}/moved" 2>&1)" || rc=$?
assert_eq "exit 1 once it is gone" "1" "${rc}"
assert_contains "names the missing method" 'method `_build_keepalive_http_client` not found' "${out}"

echo "a missing module is reported, not crashed on"
make_good_tree "${TMP}/nofile"
rm "${TMP}/nofile/providers/__init__.py"
rc=0; out="$(python3 "${SCRIPT}" --root "${TMP}/nofile" 2>&1)" || rc=$?
assert_eq "exit 1" "1" "${rc}"
assert_contains "names the file" "providers/__init__.py: file missing" "${out}"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
