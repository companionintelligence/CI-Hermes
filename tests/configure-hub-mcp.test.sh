#!/bin/bash
# Tests for configure-hub-mcp.py — Hub MCP registration with SSE + Bearer auth,
# coexistence with ci_server, idempotent reconcile, and skip when disabled.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../configure-hub-mcp.py"

PASS=0
FAIL=0

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

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF -- "${needle}"; then
    echo "  ✗ ${label}"
    echo "    expected to NOT contain: ${needle}"
    echo "    in:                      ${haystack}"
    FAIL=$((FAIL + 1))
  else
    echo "  ✓ ${label}"
    PASS=$((PASS + 1))
  fi
}

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

count_lines() {
  local file="$1" pattern="$2"
  grep -cE "${pattern}" "${file}" || true
}

run_configure() {
  local data_dir="$1"; shift
  env -i PATH="${PATH}" HOME="${data_dir}" HERMES_HOME="${data_dir}" "$@" \
    python3 "${SCRIPT}" >/dev/null 2>&1
}

CONFIG_REL=".hermes/config.yaml"
HUB_URL="http://ci-os-hub:3000/api/mcp/sse"
HUB_KEY="hub-mcp-test-key"

# ─── Test 1: fresh config gets a hub MCP block ───────────────────────────────
echo "test: credentials with no existing block register a hub entry"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
printf 'model:\n  provider: ollama\n' > "${data_dir}/${CONFIG_REL}"
run_configure "${data_dir}" HUB_MCP_URL="${HUB_URL}" HUB_MCP_API_KEY="${HUB_KEY}"
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_contains "hub registered" "hub:" "${out}"
assert_contains "url is SSE endpoint" "url: \"${HUB_URL}\"" "${out}"
assert_contains "transport sse" "transport: sse" "${out}"
assert_contains "bearer auth" 'Authorization: "Bearer '"${HUB_KEY}"'"' "${out}"
rm -rf "${data_dir}"

# ─── Test 2: hub coexists with ci_server ─────────────────────────────────────
echo "test: hub block coexists with ci_server"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
cat > "${data_dir}/${CONFIG_REL}" <<'EOF'
model:
  provider: ollama
mcp_servers:
  ci_server:
    url: "http://host.docker.internal:8642/api/mcp"
    headers:
      x-api-key: "sk-test-123"
    timeout: 180
    connect_timeout: 60
EOF
run_configure "${data_dir}" HUB_MCP_URL="${HUB_URL}" HUB_MCP_API_KEY="${HUB_KEY}"
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_contains "hub registered" 'url: "'"${HUB_URL}"'"' "${out}"
assert_contains "ci_server preserved" "ci_server:" "${out}"
assert_contains "ci_server url intact" "host.docker.internal:8642" "${out}"
assert_eq "single hub block" "1" "$(count_lines "${data_dir}/${CONFIG_REL}" "^  hub:")"
rm -rf "${data_dir}"

# ─── Test 3: changed credentials are reconciled ──────────────────────────────
echo "test: changed URL/key updates the existing hub block"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
cat > "${data_dir}/${CONFIG_REL}" <<'EOF'
model:
  provider: ollama
mcp_servers:
  hub:
    url: "http://old-hub:3000/api/mcp/sse"
    transport: sse
    headers:
      Authorization: "Bearer old-key"
    timeout: 180
    connect_timeout: 60
EOF
run_configure "${data_dir}" HUB_MCP_URL="${HUB_URL}" HUB_MCP_API_KEY="${HUB_KEY}"
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_contains "url updated" "url: \"${HUB_URL}\"" "${out}"
assert_contains "key updated" 'Authorization: "Bearer '"${HUB_KEY}"'"' "${out}"
assert_not_contains "old url gone" "old-hub" "${out}"
assert_not_contains "old key gone" "old-key" "${out}"
rm -rf "${data_dir}"

# ─── Test 4: unchanged credentials are idempotent ────────────────────────────
echo "test: re-running with unchanged credentials leaves config byte-identical"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
printf 'model:\n  provider: ollama\n' > "${data_dir}/${CONFIG_REL}"
run_configure "${data_dir}" HUB_MCP_URL="${HUB_URL}" HUB_MCP_API_KEY="${HUB_KEY}"
hash1="$(shasum "${data_dir}/${CONFIG_REL}" | awk '{print $1}')"
run_configure "${data_dir}" HUB_MCP_URL="${HUB_URL}" HUB_MCP_API_KEY="${HUB_KEY}"
hash2="$(shasum "${data_dir}/${CONFIG_REL}" | awk '{print $1}')"
assert_eq "two runs produce identical config.yaml" "${hash1}" "${hash2}"
rm -rf "${data_dir}"

# ─── Test 5: HUB_MCP_ENABLED=false skips registration ────────────────────────
echo "test: HUB_MCP_ENABLED=false does not register hub MCP"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
printf 'model:\n  provider: ollama\n' > "${data_dir}/${CONFIG_REL}"
run_configure "${data_dir}" HUB_MCP_URL="${HUB_URL}" HUB_MCP_API_KEY="${HUB_KEY}" HUB_MCP_ENABLED=false
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_not_contains "no hub block" "hub:" "${out}"
rm -rf "${data_dir}"

# ─── Test 6: missing creds do not remove existing ci_server ──────────────────
echo "test: absent Hub creds do not remove ci_server block"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
cat > "${data_dir}/${CONFIG_REL}" <<'EOF'
model:
  provider: ollama
mcp_servers:
  ci_server:
    url: "http://host.docker.internal:8642/api/mcp"
    headers:
      x-api-key: "sk-test-123"
EOF
run_configure "${data_dir}"
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_contains "ci_server preserved" "ci_server:" "${out}"
assert_not_contains "no hub block added" "  hub:" "${out}"
rm -rf "${data_dir}"

# ─── Test 7: incomplete creds register nothing ───────────────────────────────
echo "test: URL without key does not register hub MCP"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
printf 'model:\n  provider: ollama\n' > "${data_dir}/${CONFIG_REL}"
run_configure "${data_dir}" HUB_MCP_URL="${HUB_URL}"
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_not_contains "no hub block" "hub:" "${out}"
rm -rf "${data_dir}"

line_no() {
  local file="$1" pattern="$2"
  grep -nE "${pattern}" "${file}" | head -1 | cut -d: -f1
}

# ─── Test 8: nested under mcp_servers when not last key ──────────────────────
echo "test: hub is nested under mcp_servers even when it is not the last key"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
cat > "${data_dir}/${CONFIG_REL}" <<'EOF'
model:
  provider: ollama
mcp_servers:
  existing:
    url: "http://other/api/mcp"
agent:
  max_turns: 90
EOF
run_configure "${data_dir}" HUB_MCP_URL="${HUB_URL}" HUB_MCP_API_KEY="${HUB_KEY}"
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_contains "hub registered" "url: \"${HUB_URL}\"" "${out}"
assert_contains "existing server preserved" "http://other/api/mcp" "${out}"
assert_contains "agent section intact" "max_turns: 90" "${out}"
mcp_line="$(line_no "${data_dir}/${CONFIG_REL}" '^mcp_servers:')"
hub_line="$(line_no "${data_dir}/${CONFIG_REL}" '^  hub:')"
agent_line="$(line_no "${data_dir}/${CONFIG_REL}" '^agent:')"
nested="$([[ -n "${hub_line}" && "${mcp_line}" -lt "${hub_line}" && "${hub_line}" -lt "${agent_line}" ]] && echo yes || echo no)"
assert_eq "hub sits between mcp_servers and agent" "yes" "${nested}"
rm -rf "${data_dir}"

# ─── Summary ────────────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
