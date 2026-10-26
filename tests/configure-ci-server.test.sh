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

# ─── Test 8: config.yaml directly in $HERMES_HOME (where Hermes keeps it) ────
# The image sets HERMES_HOME=/opt/data and Hermes writes /opt/data/config.yaml.
# The script only looked under */.hermes/, so it timed out after 30 s and Memory's
# MCP server was never registered. HOME points elsewhere here so only the
# $HERMES_HOME copy can be found.
echo "test: a config.yaml at \$HERMES_HOME/config.yaml gets the ci_server block"
data_dir="$(mktemp -d)"
home_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
env -i PATH="${PATH}" HOME="${home_dir}" HERMES_HOME="${data_dir}" \
  CI_SERVER_URL=http://ci-memory:8642 CI_SERVER_TOKEN=sk-home-1 \
  timeout 20 python3 "${SCRIPT}" >/dev/null 2>&1 || true
out="$(cat "${data_dir}/config.yaml")"
assert_contains "ci_server registered in \$HERMES_HOME/config.yaml" 'url: "http://ci-memory:8642/api/mcp"' "${out}"
assert_contains "api key written" 'x-api-key: "sk-home-1"' "${out}"
assert_eq "nothing written under HOME" "" "$(ls -A "${home_dir}")"
rm -rf "${data_dir}" "${home_dir}"

# ─── Test 9: it waits for \$HERMES_HOME/config.yaml when that is not there yet ─
echo "test: with no config yet, the script waits for \$HERMES_HOME/config.yaml"
data_dir="$(mktemp -d)"
home_dir="$(mktemp -d)"
env -i PATH="${PATH}" HOME="${home_dir}" HERMES_HOME="${data_dir}" \
  CI_SERVER_URL=http://ci-memory:8642 CI_SERVER_TOKEN=sk-late-1 \
  timeout 20 python3 "${SCRIPT}" >/dev/null 2>&1 &
pid=$!
sleep 2
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
wait "${pid}" || true
out="$(cat "${data_dir}/config.yaml")"
assert_contains "ci_server registered once config.yaml appeared" 'x-api-key: "sk-late-1"' "${out}"
rm -rf "${data_dir}" "${home_dir}"

# ─── Test 10: Disconnect removes the block this script wrote ────────────────
# Disconnect restarts the containers without CI_SERVER_URL/CI_SERVER_TOKEN and
# revokes the key. The block written on Connect would keep pointing Hermes at it.
echo "test: with the credentials gone, the block this script wrote is removed"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\nmcp_servers:\n  hub:\n    url: "http://ci-hub:5002/api/mcp"\n' > "${data_dir}/config.yaml"
env -i PATH="${PATH}" HOME="${data_dir}/home" HERMES_HOME="${data_dir}" \
  CI_SERVER_URL=http://gateway:8642 CI_SERVER_TOKEN=sk-connect-1 python3 "${SCRIPT}" >/dev/null 2>&1
assert_contains "registered on connect" 'x-api-key: "sk-connect-1"' "$(cat "${data_dir}/config.yaml")"
assert_eq "owner recorded without the key itself" "0" "$(grep -c 'sk-connect-1' "${data_dir}/.ci-server-mcp.json" || true)"
env -i PATH="${PATH}" HOME="${data_dir}/home" HERMES_HOME="${data_dir}" python3 "${SCRIPT}" >/dev/null 2>&1
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "ci_server block removed" "ci_server:" "${out}"
assert_not_contains "revoked key gone" "sk-connect-1" "${out}"
assert_contains "the hub block stays" 'url: "http://ci-hub:5002/api/mcp"' "${out}"
assert_contains "mcp_servers stays for the hub block" "mcp_servers:" "${out}"
assert_eq "owner record removed" "no" "$([[ -e "${data_dir}/.ci-server-mcp.json" ]] && echo yes || echo no)"
python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "${data_dir}/config.yaml" \
  && assert_eq "still valid YAML" ok ok || assert_eq "still valid YAML" ok broken
rm -rf "${data_dir}"

# ─── Test 11: an mcp_servers section left empty goes too ─────────────────────
echo "test: removing the only MCP server also removes the empty mcp_servers key"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
env -i PATH="${PATH}" HOME="${data_dir}/home" HERMES_HOME="${data_dir}" \
  CI_SERVER_URL=http://gateway:8642 CI_SERVER_TOKEN=sk-connect-2 python3 "${SCRIPT}" >/dev/null 2>&1
env -i PATH="${PATH}" HOME="${data_dir}/home" HERMES_HOME="${data_dir}" CI_SERVER_ENABLED=false \
  CI_SERVER_URL=http://gateway:8642 CI_SERVER_TOKEN=sk-connect-2 python3 "${SCRIPT}" >/dev/null 2>&1
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "CI_SERVER_ENABLED=false removes it too" "ci_server:" "${out}"
assert_not_contains "no empty mcp_servers left" "mcp_servers:" "${out}"
assert_contains "the rest of the file stays" "provider: ollama" "${out}"
rm -rf "${data_dir}"

# ─── Test 12: a block this script didn't write, or one edited since, stays ──
echo "test: a hand-written block, or one whose key was changed, is left alone"
data_dir="$(mktemp -d)"
printf 'mcp_servers:\n  ci_server:\n    url: "http://mine:8642/api/mcp"\n    headers:\n      x-api-key: "sk-mine"\n' > "${data_dir}/config.yaml"
env -i PATH="${PATH}" HOME="${data_dir}/home" HERMES_HOME="${data_dir}" python3 "${SCRIPT}" >/dev/null 2>&1
assert_contains "hand-written block kept" 'x-api-key: "sk-mine"' "$(cat "${data_dir}/config.yaml")"
rm -rf "${data_dir}"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
env -i PATH="${PATH}" HOME="${data_dir}/home" HERMES_HOME="${data_dir}" \
  CI_SERVER_URL=http://gateway:8642 CI_SERVER_TOKEN=sk-connect-3 python3 "${SCRIPT}" >/dev/null 2>&1
sed -i 's/sk-connect-3/sk-edited-by-hand/' "${data_dir}/config.yaml"
env -i PATH="${PATH}" HOME="${data_dir}/home" HERMES_HOME="${data_dir}" python3 "${SCRIPT}" >/dev/null 2>&1
assert_contains "edited block kept" 'x-api-key: "sk-edited-by-hand"' "$(cat "${data_dir}/config.yaml")"
rm -rf "${data_dir}"

# ─── Test 13: the other container's locked edit is not lost ─────────────────
# Both containers patch config.yaml at start. bootstrap-ci-context.sh and
# reconcile-hub-config.py hold .hub-config.lock across their read-modify-write.
# Here another writer holds it, reads the file, waits and writes its edit back.
# Unlocked, this script would add its block in between and lose it.
echo "test: the block is added after another locked writer is done, not lost under it"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
python3 - "${data_dir}/config.yaml" <<'PY' &
import fcntl, os, sys, time
path = sys.argv[1]
lock = open(os.path.join(os.path.dirname(path), ".hub-config.lock"), "a+")
fcntl.flock(lock, fcntl.LOCK_EX)
text = open(path).read()
open(path + ".held", "w").close()
time.sleep(2)
open(path, "w").write(text + "skills:\n  external_dirs:\n    - /app/ci-context/skills\n")
fcntl.flock(lock, fcntl.LOCK_UN)
PY
holder=$!
for _ in $(seq 1 50); do [[ -e "${data_dir}/config.yaml.held" ]] && break; sleep 0.1; done
env -i PATH="${PATH}" HOME="${data_dir}/home" HERMES_HOME="${data_dir}" \
  CI_SERVER_URL=http://gateway:8642 CI_SERVER_TOKEN=sk-race-1 timeout 20 python3 "${SCRIPT}" >/dev/null 2>&1 || true
wait "${holder}"
out="$(cat "${data_dir}/config.yaml")"
assert_contains "the other writer's edit survives" "external_dirs:" "${out}"
assert_contains "and so does the ci_server block" 'x-api-key: "sk-race-1"' "${out}"
rm -rf "${data_dir}"

# ─── Summary ────────────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
