#!/bin/bash
# Tests for bootstrap-ci-context.sh — focused on the config.yaml reconcile:
# inline `child: []` handling, Companion Memory auto-activation, never
# clobbering an existing non-empty memory.provider, and the CI_SERVER_ENABLED
# off-switch.
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

# GNU `stat -c` / `touch -d` are not portable to macOS (BSD). Prefer GNU when
# present, otherwise use BSD forms so `pnpm test` works on contributor laptops.
file_mtime() {
  if stat -c %Y "$1" >/dev/null 2>&1; then
    stat -c %Y "$1"
  else
    stat -f %m "$1"
  fi
}

set_mtime() {
  local path="$1"
  if touch -d '2020-01-01 00:00:00' "$path" 2>/dev/null; then
    return 0
  fi
  touch -t 202001010000 "$path"
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

# LITERAL line-prefix negative check: a plain substring grep can't tell a 2-space
# `  base_url:` model key from a 4-space `    base_url:` auxiliary child (the former
# is a substring of the latter), and a grep -E check mis-handles prefixes with
# metacharacters (URLs with ".", "{"). `[[ "$line" == "$prefix"* ]]` matches the
# quoted prefix literally with a trailing wildcard, so callers pass plain text.
assert_no_line() {
  local label="$1" prefix="$2" haystack="$3" line
  while IFS= read -r line; do
    if [[ "${line}" == "${prefix}"* ]]; then
      echo "  ✗ ${label}"; echo "    expected NO line starting with: ${prefix}"; echo "    in: ${haystack}"; FAIL=$((FAIL + 1)); return
    fi
  done <<< "${haystack}"
  echo "  ✓ ${label}"; PASS=$((PASS + 1))
}

# Count occurrences of a 2-space-indented child key (e.g. `  enabled:`) across
# the whole file. The fixtures only ever have one section containing a given
# key, so a count > 1 means a duplicate mapping key was emitted.
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

# ─── Test 6b: whitespace-only credentials count as missing ───────────────────
echo "test: whitespace-only URL/token do not activate (plugin would strip them)"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
run_bootstrap "${data_dir}" "CI_SERVER_URL=   " "CI_SERVER_TOKEN=	"
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no provider for whitespace creds" "provider: companionintelligence" "${out}"
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

# ─── Test 8: HERMES_NUM_CTX (>=64K) is reconciled into both keys ──────────────
# A config generated before the Hub computed a context window has no
# model.ollama_num_ctx; the reconcile must add it from .env.hub-bootstrap so Ollama
# doesn't load the model at its oversized default. Because 65536 clears Hermes' 64K
# minimum, context_length is pinned to the same value so the agent's window matches.
echo "test: HERMES_NUM_CTX>=64K is written into model.ollama_num_ctx + context_length"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n  default: qwen3.6:27b\n' > "${data_dir}/config.yaml"
printf 'HERMES_NUM_CTX=65536\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_contains "model.ollama_num_ctx set" "ollama_num_ctx: 65536" "${out}"
assert_contains "model.context_length set (>=64K clears the minimum)" "context_length: 65536" "${out}"
assert_eq "single ollama_num_ctx key (no duplicate)" "1" "$(count_child_key "${data_dir}/config.yaml" ollama_num_ctx)"
assert_eq "single context_length key (no duplicate)" "1" "$(count_child_key "${data_dir}/config.yaml" context_length)"
rm -rf "${data_dir}"

# ─── Test 8b: a sub-64K HERMES_NUM_CTX sets ollama_num_ctx but NOT context_length ─
# Below Hermes' 64K minimum, pinning context_length would make the agent abort at
# startup — so we cap the KV cache via ollama_num_ctx and leave context_length to the
# agent's auto-detection (which resolves the model's true >=64K window).
echo "test: sub-64K HERMES_NUM_CTX sets ollama_num_ctx only (no context_length)"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n  default: qwen3.6:27b\n' > "${data_dir}/config.yaml"
printf 'HERMES_NUM_CTX=32768\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_contains "model.ollama_num_ctx set" "ollama_num_ctx: 32768" "${out}"
assert_not_contains "context_length NOT written below 64K (avoids startup abort)" "context_length:" "${out}"
rm -rf "${data_dir}"

# ─── Test 8c: a downgrade below 64K REMOVES a previously-pinned context_length ──
# A config pinned at >=64K on prior hardware must drop context_length when the Hub
# later recommends a sub-64K window, so the agent auto-detects instead of booting
# with a now-too-large pinned window (the "<min → context_length unset" contract).
echo "test: a downgrade below 64K removes a pre-existing context_length"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n  ollama_num_ctx: 65536\n  context_length: 65536\n' > "${data_dir}/config.yaml"
printf 'HERMES_NUM_CTX=32768\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_contains "ollama_num_ctx updated to new value" "ollama_num_ctx: 32768" "${out}"
assert_not_contains "stale context_length removed on downgrade" "context_length:" "${out}"
rm -rf "${data_dir}"

# ─── Test 8d: duplicate stale num_ctx keys are ALL migrated away ───────────────
# delete_child_scalar removes every occurrence, not just the first, so a config that
# somehow carried duplicates doesn't keep a stale copy.
echo "test: duplicate legacy num_ctx keys are all removed"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n  num_ctx: 111\n  num_ctx: 222\n' > "${data_dir}/config.yaml"
printf 'HERMES_NUM_CTX=65536\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_eq "no legacy num_ctx keys remain" "0" "$(count_child_key "${data_dir}/config.yaml" num_ctx)"
assert_contains "ollama_num_ctx set" "ollama_num_ctx: 65536" "${out}"
rm -rf "${data_dir}"

# ─── Test 9: a stale/legacy num_ctx is migrated to the Hub's current value ─────
# Upstream only reads ollama_num_ctx; a config carrying the dead num_ctx key (from
# a pre-fix appliance) must have it removed and the live keys set to the Hub value.
echo "test: a pre-existing legacy model.num_ctx is migrated and updated"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n  num_ctx: 262144\n' > "${data_dir}/config.yaml"
printf 'HERMES_NUM_CTX=65536\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_contains "ollama_num_ctx set to Hub value" "ollama_num_ctx: 65536" "${out}"
assert_contains "context_length set to Hub value (>=64K)" "context_length: 65536" "${out}"
assert_not_contains "legacy num_ctx key removed" "  num_ctx:" "${out}"
assert_not_contains "old value gone" "262144" "${out}"
assert_eq "single ollama_num_ctx key (no duplicate)" "1" "$(count_child_key "${data_dir}/config.yaml" ollama_num_ctx)"
rm -rf "${data_dir}"

# ─── Test 10: context reconcile is idempotent across two runs ────────────────
echo "test: context reconcile is idempotent (two runs identical)"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
printf 'HERMES_NUM_CTX=65536\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}"
hash1="$(shasum "${data_dir}/config.yaml" | awk '{print $1}')"
run_bootstrap "${data_dir}"
hash2="$(shasum "${data_dir}/config.yaml" | awk '{print $1}')"
assert_eq "two runs produce identical config.yaml" "${hash1}" "${hash2}"
rm -rf "${data_dir}"

# ─── Test 11: no HERMES_NUM_CTX → model context keys are not touched ──────────
echo "test: without HERMES_NUM_CTX no context window keys are written"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no ollama_num_ctx written" "ollama_num_ctx:" "${out}"
assert_not_contains "no context_length written" "context_length:" "${out}"
rm -rf "${data_dir}"

# ─── Test 12: a non-integer HERMES_NUM_CTX is ignored ────────────────────────
echo "test: a non-integer HERMES_NUM_CTX is ignored (treated as unset)"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
printf 'HERMES_NUM_CTX=not-a-number\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "garbage ollama_num_ctx not written" "ollama_num_ctx:" "${out}"
assert_not_contains "garbage context_length not written" "context_length:" "${out}"
rm -rf "${data_dir}"

# ─── Test 13: a quoted HERMES_NUM_CTX value is still applied ─────────────────
echo "test: HERMES_NUM_CTX=\"65536\" (quoted) is normalized and applied"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
printf 'HERMES_NUM_CTX="65536"\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_contains "quoted ollama_num_ctx applied" "ollama_num_ctx: 65536" "${out}"
assert_contains "quoted value also pins context_length (>=64K)" "context_length: 65536" "${out}"
assert_not_contains "no stray quotes in value" 'ollama_num_ctx: "' "${out}"
rm -rf "${data_dir}"

# ─── Test 14: HERMES_NUM_CTX=0 is rejected (not a meaningful window) ──────────
echo "test: HERMES_NUM_CTX=0 is treated as unset"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
printf 'HERMES_NUM_CTX=0\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "zero ollama_num_ctx not written" "ollama_num_ctx:" "${out}"
rm -rf "${data_dir}"

# ─── Test 15: .env.hub-bootstrap without HERMES_NUM_CTX must not abort ───────
# Under `set -euo pipefail` a no-match grep would fail the pipeline and abort the
# whole bootstrap. run_bootstrap does not swallow a non-zero exit, so a regression
# here crashes the suite; we also assert the rest of the reconcile still ran.
echo "test: a hub env file lacking HERMES_NUM_CTX still completes the reconcile"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
printf 'OPENAI_MODEL=qwen3.6:27b\nOLLAMA_HOST=http://host.docker.internal:11434\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" "${CREDS[@]}"
out="$(cat "${data_dir}/config.yaml")"
assert_contains "reconcile still ran (ci-runtime enabled)" "- ci-runtime" "${out}"
assert_not_contains "no ollama_num_ctx written without the key" "ollama_num_ctx:" "${out}"
rm -rf "${data_dir}"

# ─── Test 16: a fully-reconciled config is not rewritten (no mtime churn) ─────
echo "test: a second run does not rewrite an already-reconciled config.yaml"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
printf 'HERMES_NUM_CTX=65536\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" "${CREDS[@]}"
set_mtime "${data_dir}/config.yaml"
before="$(file_mtime "${data_dir}/config.yaml")"
run_bootstrap "${data_dir}" "${CREDS[@]}"
after="$(file_mtime "${data_dir}/config.yaml")"
assert_eq "config.yaml not rewritten when unchanged (mtime preserved)" "${before}" "${after}"
rm -rf "${data_dir}"

# ─── Test 17: reconcile adds an auxiliary block (native on + local ollama) ────
# A pre-existing config with no auxiliary section gets one so side-tasks resolve
# to the local Ollama instead of failing aux auto-detection.
echo "test: reconcile adds auxiliary providers (native on + ollama endpoint)"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n  default: gemma4:e2b\n' > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=http://172.17.0.1:11434/v1\nHERMES_OPENAI_API_KEY=ollama\nHERMES_DEFAULT_MODEL=gemma4:e2b\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
out="$(cat "${data_dir}/config.yaml")"
assert_contains "auxiliary section added" "auxiliary:" "${out}"
assert_contains "compression task added" "  compression:" "${out}"
assert_contains "vision task added" "  vision:" "${out}"
assert_contains "aux base_url at local ollama" "base_url: 'http://172.17.0.1:11434/v1'" "${out}"
assert_contains "aux api_key is the local sentinel" "api_key: 'ollama'" "${out}"
hash1="$(shasum "${data_dir}/config.yaml" | awk '{print $1}')"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
hash2="$(shasum "${data_dir}/config.yaml" | awk '{print $1}')"
assert_eq "auxiliary reconcile is idempotent" "${hash1}" "${hash2}"
rm -rf "${data_dir}"

# ─── Test 18: an existing auxiliary section is NOT clobbered (block form) ──────
echo "test: a user-configured auxiliary section is preserved"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\nauxiliary:\n  compression:\n    provider: openrouter\n' > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=http://172.17.0.1:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
out="$(cat "${data_dir}/config.yaml")"
assert_contains "existing auxiliary preserved" "provider: openrouter" "${out}"
# The user's auxiliary.compression must be left exactly as-is — no base_url injected.
# (A grep can't distinguish it from the intended providers.ollama base_url, so assert
# on the parsed structure.)
if python3 -c "import yaml,sys; a=yaml.safe_load(open('${data_dir}/config.yaml')).get('auxiliary',{}).get('compression',{}); sys.exit(0 if a.get('provider')=='openrouter' and 'base_url' not in a else 1)"; then
  echo "  ✓ user aux.compression untouched (no base_url injected)"; PASS=$((PASS + 1))
else
  echo "  ✗ user aux.compression was modified"; FAIL=$((FAIL + 1))
fi
rm -rf "${data_dir}"

# ─── Test 18b: an inline auxiliary section is NOT duplicated ──────────────────
echo "test: an inline 'auxiliary: {}' is detected (no duplicate top-level key)"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\nauxiliary: {}\n' > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=http://172.17.0.1:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
assert_eq "no duplicate auxiliary key" "1" "$(grep -cE '^auxiliary:' "${data_dir}/config.yaml")"
rm -rf "${data_dir}"

# ─── Test 19: no auxiliary block when the endpoint is unknown ─────────────────
echo "test: reconcile adds no auxiliary block without an endpoint in .env"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
printf 'HERMES_NUM_CTX=65536\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no auxiliary section without endpoint" "auxiliary:" "${out}"
rm -rf "${data_dir}"

# ─── Test 20: native flag OFF → no auxiliary block (true no-op) ───────────────
echo "test: reconcile adds no auxiliary block when CI_HERMES_OLLAMA_NATIVE is off"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=http://172.17.0.1:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no auxiliary section with flag off" "auxiliary:" "${out}"
rm -rf "${data_dir}"

# ─── Test 21: cloud endpoint (api_key != ollama) → no block, no key leak ──────
echo "test: reconcile writes no auxiliary block / no key leak for a cloud endpoint"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n' > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=https://api.openai.com/v1\nHERMES_OPENAI_API_KEY=sk-secret-cloud-key\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
out="$(cat "${data_dir}/config.yaml")"
assert_not_contains "no auxiliary section for cloud endpoint" "auxiliary:" "${out}"
assert_not_contains "cloud api key never written to config.yaml" "sk-secret-cloud-key" "${out}"
rm -rf "${data_dir}"

# ─── Test 22: reconcile pins model.base_url + api_key for a local endpoint ─────
# Surfaces the local box as the GUI picker's "custom" provider (num_ctx-aware).
# Local-gated only (NOT the native flag) — the picker mislabel breaks the GUI
# switch regardless of whether the native adapter is on, so we use the flag-OFF
# run here to prove independence.
echo "test: reconcile pins model.base_url + api_key for a local endpoint (flag off)"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n  default: gemma4:e2b\n' > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=http://172.17.0.1:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}"
out="$(cat "${data_dir}/config.yaml")"
assert_contains "model.base_url pinned" "  base_url: 'http://172.17.0.1:11434/v1'" "${out}"
assert_contains "model.api_key sentinel pinned" "  api_key: 'ollama'" "${out}"
assert_contains "provider stays ollama" "provider: ollama" "${out}"
assert_contains "providers.ollama registered for picker" "name: 'Ollama (local)'" "${out}"
assert_no_line "providers section opened (not inline {})" "providers: {" "${out}"
assert_not_contains "no auxiliary block (flag off)" "auxiliary:" "${out}"
rm -rf "${data_dir}"

# ─── Test 23: auto-heal a config an earlier GUI switch left on 'openai-api' ────
echo "test: reconcile heals provider openai-api -> ollama for a local endpoint"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: openai-api\n  default: qwen3.5:9b\n  ollama_num_ctx: 64000\n' > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=http://172.17.0.1:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
out="$(cat "${data_dir}/config.yaml")"
assert_contains "provider healed to ollama" "provider: ollama" "${out}"
assert_not_contains "openai-api provider removed" "provider: openai-api" "${out}"
assert_contains "endpoint pinned after heal" "  base_url: 'http://172.17.0.1:11434/v1'" "${out}"
assert_contains "providers.ollama registered after heal" "name: 'Ollama (local)'" "${out}"
rm -rf "${data_dir}"

# ─── Test 24: cloud endpoint → no model.base_url, no heal, no key leak ─────────
echo "test: reconcile leaves the model block alone for a cloud endpoint"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: openai-api\n  default: gpt-4o\n' > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=https://api.openai.com/v1\nHERMES_OPENAI_API_KEY=sk-secret-cloud-key\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
out="$(cat "${data_dir}/config.yaml")"
assert_contains "cloud provider left as-is (not healed)" "provider: openai-api" "${out}"
assert_not_contains "no model.base_url pinned for cloud" "base_url:" "${out}"
assert_not_contains "cloud key never written to config.yaml" "sk-secret-cloud-key" "${out}"
assert_not_contains "no providers.ollama picker entry for cloud" "Ollama (local)" "${out}"
rm -rf "${data_dir}"

# ─── Test 25: model endpoint reconcile is idempotent ──────────────────────────
echo "test: model.base_url/heal reconcile is idempotent"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: openai-api\n  default: qwen3.5:9b\n' > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=http://172.17.0.1:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
hash1="$(shasum "${data_dir}/config.yaml" | awk '{print $1}')"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
hash2="$(shasum "${data_dir}/config.yaml" | awk '{print $1}')"
assert_eq "two runs produce identical config.yaml" "${hash1}" "${hash2}"
rm -rf "${data_dir}"

# ─── Test 26: a user's explicit model.base_url is never clobbered ──────────────
echo "test: an existing model.base_url is preserved"
data_dir="$(mktemp -d)"
printf "model:\n  provider: ollama\n  default: gemma4:e2b\n  base_url: 'http://my-own-box:11434/v1'\n" > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=http://172.17.0.1:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
out="$(cat "${data_dir}/config.yaml")"
assert_contains "user base_url preserved" "base_url: 'http://my-own-box:11434/v1'" "${out}"
# 2-space anchor targets the model key only (aux uses 4 spaces): the hub endpoint
# must not be forced onto the model block over the user's own value.
assert_no_line "hub endpoint not forced over user model value" "  base_url: 'http://172.17.0.1:11434/v1'" "${out}"
rm -rf "${data_dir}"

# ─── Test 27: a user's own providers entry (different key) is preserved ────────
echo "test: ensure_provider_entry adds ollama without clobbering a user provider"
data_dir="$(mktemp -d)"
printf "model:\n  provider: ollama\n  default: gemma4:e2b\nproviders:\n  myremote:\n    name: 'My Remote'\n    base_url: 'https://remote.example/v1'\n" > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=http://172.17.0.1:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
out="$(cat "${data_dir}/config.yaml")"
assert_contains "user provider preserved" "name: 'My Remote'" "${out}"
assert_contains "ollama provider added alongside" "name: 'Ollama (local)'" "${out}"
assert_eq "single providers: key (no duplicate)" "1" "$(grep -cE '^providers:' "${data_dir}/config.yaml")"
rm -rf "${data_dir}"

# ─── Test 28: an existing providers.ollama is never clobbered (idempotent) ─────
echo "test: an existing providers.ollama entry is left untouched"
data_dir="$(mktemp -d)"
printf "model:\n  provider: ollama\n  default: gemma4:e2b\nproviders:\n  ollama:\n    name: 'My Own Ollama'\n    base_url: 'http://my-box:11434/v1'\n" > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=http://172.17.0.1:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
out="$(cat "${data_dir}/config.yaml")"
assert_contains "existing providers.ollama name preserved" "name: 'My Own Ollama'" "${out}"
assert_not_contains "our providers.ollama not forced over user's" "name: 'Ollama (local)'" "${out}"
rm -rf "${data_dir}"

# ─── Test 29: inline-empty 'providers: {}' (PyYAML re-dump) is opened cleanly ──
# A config re-dumped by Hermes serializes an empty mapping as `providers: {}`.
# ensure_provider_entry must open it into a block and add ollama — not append a
# second top-level providers: key.
echo "test: inline-empty 'providers: {}' is opened and gets the ollama entry"
data_dir="$(mktemp -d)"
printf 'model:\n  provider: ollama\n  default: gemma4:e2b\nproviders: {}\n' > "${data_dir}/config.yaml"
printf 'HERMES_OPENAI_BASE_URL=http://172.17.0.1:11434/v1\nHERMES_OPENAI_API_KEY=ollama\n' > "${data_dir}/.env.hub-bootstrap"
run_bootstrap "${data_dir}" CI_HERMES_OLLAMA_NATIVE=1
out="$(cat "${data_dir}/config.yaml")"
assert_contains "providers.ollama added from inline-empty" "name: 'Ollama (local)'" "${out}"
assert_eq "single providers: key (no duplicate)" "1" "$(grep -cE '^providers:' "${data_dir}/config.yaml")"
assert_no_line "inline-empty providers was opened" "providers: {}" "${out}"
if python3 -c "import yaml,sys; d=yaml.safe_load(open('${data_dir}/config.yaml')); sys.exit(0 if 'ollama' in (d.get('providers') or {}) else 1)"; then
  echo "  ✓ YAML valid, providers.ollama present"; PASS=$((PASS + 1))
else
  echo "  ✗ YAML invalid or providers.ollama missing"; FAIL=$((FAIL + 1))
fi
rm -rf "${data_dir}"

# ─── Summary ────────────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
