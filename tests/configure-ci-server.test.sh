#!/bin/bash
# Tests for configure-ci-server.py — focused on MCP server registration:
# fresh registration, credential reconcile when the install-dialog URL/key
# change, and idempotency when nothing changed.
#
# The config path is resolved from CONFIG_PATHS, whose first entry is
# ~/.hermes/config.yaml. We point HOME at a temp dir so the script reads/writes
# an isolated config there. HERMES_HOME is set to the same dir so the (optional)
# plugin copy step stays inside the sandbox.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../configure-ci-server.py"

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

# Run configure-ci-server.py against an isolated config under $data_dir/.hermes.
# Remaining args are extra KEY=VALUE env assignments (CI_SERVER_URL=..., etc.).
run_configure() {
  local data_dir="$1"; shift
  env -i PATH="${PATH}" HOME="${data_dir}" HERMES_HOME="${data_dir}" "$@" \
    python3 "${SCRIPT}" >/dev/null 2>&1
}

CONFIG_REL=".hermes/config.yaml"

# ─── Test 1: fresh config gets a ci_server MCP block ─────────────────────────
echo "test: credentials with no existing block register a ci_server entry"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
printf 'model:\n  provider: ollama\n' > "${data_dir}/${CONFIG_REL}"
run_configure "${data_dir}" CI_SERVER_URL=http://host.docker.internal:8642 CI_SERVER_TOKEN=sk-test-123
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_contains "ci_server registered" "ci_server:" "${out}"
assert_contains "url ends in /api/mcp" 'url: "http://host.docker.internal:8642/api/mcp"' "${out}"
assert_contains "api key written" 'x-api-key: "sk-test-123"' "${out}"
rm -rf "${data_dir}"

# ─── Test 2: changed dialog credentials are reconciled in place ──────────────
echo "test: a changed URL/token updates the existing ci_server block"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
cat > "${data_dir}/${CONFIG_REL}" <<'EOF'
model:
  provider: ollama
mcp_servers:
  ci_server:
    url: "http://old-host:1111/api/mcp"
    headers:
      x-api-key: "sk-old-key"
    timeout: 180
    connect_timeout: 60
EOF
run_configure "${data_dir}" CI_SERVER_URL=http://new-host:8642 CI_SERVER_TOKEN=sk-new-key
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_contains "url updated" 'url: "http://new-host:8642/api/mcp"' "${out}"
assert_contains "key updated" 'x-api-key: "sk-new-key"' "${out}"
assert_not_contains "old url gone" "old-host" "${out}"
assert_not_contains "old key gone" "sk-old-key" "${out}"
assert_eq "single ci_server block (no duplicate)" "1" "$(count_lines "${data_dir}/${CONFIG_REL}" "^  ci_server:")"
rm -rf "${data_dir}"

# ─── Test 3: unchanged credentials are idempotent (no rewrite) ───────────────
echo "test: re-running with unchanged credentials leaves config byte-identical"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
printf 'model:\n  provider: ollama\n' > "${data_dir}/${CONFIG_REL}"
run_configure "${data_dir}" CI_SERVER_URL=http://host.docker.internal:8642 CI_SERVER_TOKEN=sk-test-123
hash1="$(shasum "${data_dir}/${CONFIG_REL}" | awk '{print $1}')"
run_configure "${data_dir}" CI_SERVER_URL=http://host.docker.internal:8642 CI_SERVER_TOKEN=sk-test-123
hash2="$(shasum "${data_dir}/${CONFIG_REL}" | awk '{print $1}')"
assert_eq "two runs produce identical config.yaml" "${hash1}" "${hash2}"
assert_eq "single ci_server block (no duplicate)" "1" "$(count_lines "${data_dir}/${CONFIG_REL}" "^  ci_server:")"
rm -rf "${data_dir}"

# ─── Test 4: incomplete credentials register nothing ─────────────────────────
echo "test: URL without token does not register an MCP block"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
printf 'model:\n  provider: ollama\n' > "${data_dir}/${CONFIG_REL}"
run_configure "${data_dir}" CI_SERVER_URL=http://host.docker.internal:8642
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_not_contains "no ci_server block" "ci_server:" "${out}"
rm -rf "${data_dir}"

line_no() {
  local file="$1" pattern="$2"
  grep -nE "${pattern}" "${file}" | head -1 | cut -d: -f1
}

# ─── Test 5: mcp_servers not last → block stays nested under the section ─────
# After Hermes re-dumps config.yaml, mcp_servers may be followed by other
# top-level keys. The block must be inserted inside the section, not at EOF.
echo "test: ci_server is nested under mcp_servers even when it is not the last key"
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
run_configure "${data_dir}" CI_SERVER_URL=http://host.docker.internal:8642 CI_SERVER_TOKEN=sk-test-123
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_contains "ci_server registered" 'url: "http://host.docker.internal:8642/api/mcp"' "${out}"
assert_contains "existing server preserved" "http://other/api/mcp" "${out}"
assert_contains "agent section intact" "max_turns: 90" "${out}"
mcp_line="$(line_no "${data_dir}/${CONFIG_REL}" '^mcp_servers:')"
ci_line="$(line_no "${data_dir}/${CONFIG_REL}" '^  ci_server:')"
agent_line="$(line_no "${data_dir}/${CONFIG_REL}" '^agent:')"
nested="$([[ -n "${ci_line}" && "${mcp_line}" -lt "${ci_line}" && "${ci_line}" -lt "${agent_line}" ]] && echo yes || echo no)"
assert_eq "ci_server sits between mcp_servers and agent (correctly nested)" "yes" "${nested}"
rm -rf "${data_dir}"

# ─── Test 6: a comment mentioning ci_server is not mistaken for a block ──────
echo "test: a 'ci_server:' inside a comment does not block real registration"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
cat > "${data_dir}/${CONFIG_REL}" <<'EOF'
model:
  provider: ollama
# mcp_servers.ci_server: configured by the Hub at install time
EOF
run_configure "${data_dir}" CI_SERVER_URL=http://host.docker.internal:8642 CI_SERVER_TOKEN=sk-test-123
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_contains "real block registered" 'url: "http://host.docker.internal:8642/api/mcp"' "${out}"
assert_contains "real ci_server key present" "ci_server:" "${out}"
rm -rf "${data_dir}"

# ─── Test 7: a re-indented existing block is still reconciled ────────────────
# A different YAML emitter may use 4-space indentation. Detection keys off the
# actual indentation of the ci_server line, so reconcile must still apply.
echo "test: a 4-space-indented ci_server block is reconciled, not skipped"
data_dir="$(mktemp -d)"
mkdir -p "${data_dir}/.hermes"
cat > "${data_dir}/${CONFIG_REL}" <<'EOF'
model:
    provider: ollama
mcp_servers:
    ci_server:
        url: "http://old-host:1111/api/mcp"
        headers:
            x-api-key: "sk-old-key"
        timeout: 180
        connect_timeout: 60
EOF
run_configure "${data_dir}" CI_SERVER_URL=http://new-host:8642 CI_SERVER_TOKEN=sk-new-key
out="$(cat "${data_dir}/${CONFIG_REL}")"
assert_contains "re-indented url updated" 'url: "http://new-host:8642/api/mcp"' "${out}"
assert_contains "re-indented key updated" 'x-api-key: "sk-new-key"' "${out}"
assert_not_contains "old key gone" "sk-old-key" "${out}"
rm -rf "${data_dir}"

# ─── Summary ────────────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
