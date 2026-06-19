#!/bin/bash
# Tests for bootstrap-ci-context.sh — focused on the config.yaml reconcile:
# inline `child: []` handling, Companion Memory auto-activation, the marker
# guard, and the CI_SERVER_ENABLED off-switch.
#
# The script hard-codes a few /app paths (plugin source, skills dir, the
# configure-ci-server.py call). None exist in a test checkout, but each is
# guarded (`[[ -d ... ]]` / `|| true`), so the script still runs to completion
# and performs the config.yaml edits we assert on here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../bootstrap-ci-context.sh"

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

# Count occurrences of a 2-space-indented child key (e.g. `  enabled:`) so we
# can prove no duplicate mapping keys are emitted under a section.
count_child_key() {
  local file="$1" key="$2"
  grep -cE "^  ${key}:" "${file}" || true
}

# Run the bootstrap with HERMES_HOME pointed at data_dir; remaining args are
# extra KEY=VALUE env assignments (e.g. CI_SERVER_URL=...). The bootstrap is
# expected to exit 0 in these fixtures; we do NOT swallow a non-zero exit so a
# real bootstrap failure aborts the run (set -e) instead of letting assertions
# pass against a partially-updated config.
run_bootstrap() {
  local data_dir="$1"; shift
  env -i PATH="${PATH}" HERMES_HOME="${data_dir}" "$@" \
    bash "${SCRIPT}" >/dev/null 2>&1
}

CREDS=(CI_SERVER_URL=http://host.docker.internal:8642 CI_SERVER_TOKEN=sk-test-123)

# ─── Test 1: real first-edit (model-only config) activates cleanly ───────────
echo "test: model-only config gets clean plugin + provider activation"
data_dir="$(mktemp -d)"
cat > "${data_dir}/config.yaml" <<'EOF'
model:
  provider: ollama
  default: 'qwen2.5:7b'
EOF
run_bootstrap "${data_dir}" "${CREDS[@]}"
out="$(cat "${data_dir}/config.yaml")"
assert_contains "ci-runtime enabled" "- ci-runtime" "${out}"
assert_contains "companionintelligence enabled" "- companionintelligence" "${out}"
assert_contains "memory.provider selected" "provider: companionintelligence" "${out}"
assert_eq "single enabled: key (no duplicate)" "1" "$(count_child_key "${data_dir}/config.yaml" enabled)"
rm -rf "${data_dir}"

# ─── Test 2: empty provider (Hermes' "built-in only" default) is filled ──────
echo "test: empty memory.provider is treated as unset and gets activated"
data_dir="$(mktemp -d)"
cat > "${data_dir}/config.yaml" <<'EOF'
model:
  provider: ollama
memory:
  provider: ''
EOF
run_bootstrap "${data_dir}" "${CREDS[@]}"
out="$(cat "${data_dir}/config.yaml")"
assert_contains "empty provider filled with ours" "provider: companionintelligence" "${out}"
rm -rf "${data_dir}"

# ─── Test 3: inline `enabled: []` / `disabled: [...]` reconciled w/o dup key ──
echo "test: inline empty-list form is opened instead of duplicated"
data_dir="$(mktemp -d)"
cat > "${data_dir}/config.yaml" <<'EOF'
model:
  provider: ollama
plugins:
  enabled: []
  disabled:
    - companionintelligence
EOF
run_bootstrap "${data_dir}" "${CREDS[@]}"
out="$(cat "${data_dir}/config.yaml")"
assert_eq "single enabled: key (no duplicate)" "1" "$(count_child_key "${data_dir}/config.yaml" enabled)"
assert_contains "ci-runtime enabled" "- ci-runtime" "${out}"
assert_contains "companionintelligence moved into enabled" "- companionintelligence" "${out}"
assert_contains "disabled emptied" "disabled: []" "${out}"
rm -rf "${data_dir}"

# ─── Test 4: idempotent across two runs ──────────────────────────────────────
echo "test: running twice is idempotent and produces no duplicate keys"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
run_bootstrap "${data_dir}" "${CREDS[@]}"
hash1="$(shasum "${data_dir}/config.yaml" | awk '{print $1}')"
run_bootstrap "${data_dir}" "${CREDS[@]}"
hash2="$(shasum "${data_dir}/config.yaml" | awk '{print $1}')"
assert_eq "two runs produce identical config.yaml" "${hash1}" "${hash2}"
assert_eq "still a single enabled: key" "1" "$(count_child_key "${data_dir}/config.yaml" enabled)"
rm -rf "${data_dir}"

# ─── Test 5: never clobber a non-empty provider (upgrade / hand-picked) ──────
# A pre-existing install already has another provider set BEFORE the first
# auto-activation run. With creds present, that provider must be preserved and
# our plugin must not be force-selected — including on this very first run.
echo "test: an existing non-empty provider is never clobbered (no marker needed)"
data_dir="$(mktemp -d)"
cat > "${data_dir}/config.yaml" <<'EOF'
model:
  provider: ollama
memory:
  provider: someother-memory
EOF
run_bootstrap "${data_dir}" "${CREDS[@]}"
out="$(cat "${data_dir}/config.yaml")"
assert_contains "user provider preserved" "provider: someother-memory" "${out}"
assert_not_contains "our provider not selected" "provider: companionintelligence" "${out}"
assert_not_contains "our plugin not force-enabled" "- companionintelligence" "${out}"
rm -rf "${data_dir}"

# ─── Test 6: no credentials → no activation ──────────────────────────────────
echo "test: without credentials nothing is activated"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no memory provider written" "provider: companionintelligence" "${out}"
rm -rf "${data_dir}"

# ─── Test 7: CI_SERVER_ENABLED=false is an explicit off-switch ───────────────
echo "test: CI_SERVER_ENABLED=false disables activation even with creds"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
run_bootstrap "${data_dir}" "${CREDS[@]}" CI_SERVER_ENABLED=false
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "memory provider not selected" "provider: companionintelligence" "${out}"
rm -rf "${data_dir}"

# ─── Test 7b: off-switch is case-insensitive and whitespace-tolerant ─────────
echo "test: CI_SERVER_ENABLED='FALSE ' (mixed case + space) also disables"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
run_bootstrap "${data_dir}" "${CREDS[@]}" "CI_SERVER_ENABLED=FALSE "
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "memory provider not selected" "provider: companionintelligence" "${out}"
rm -rf "${data_dir}"

# ─── Summary ────────────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
