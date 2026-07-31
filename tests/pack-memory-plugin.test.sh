#!/bin/bash
# Tests for scripts/pack-memory-plugin.sh — the packaging seam for the Companion
# Intelligence memory plugin.
#
# What these protect:
#
#   - the release-tag → npm-version mapping (a 4-segment same-day tag is not semver)
#   - `--compare`, which decides whether a release tag actually changed the plugin or
#     is an image-only release that should not mint a new version
#   - THE DOCUMENTED INSTALL ITSELF. The README tells users to extract the archive
#     into ~/.hermes/plugins/companionintelligence with --strip-components=1. If the
#     archive shape changes, that instruction silently produces a directory Hermes
#     cannot load — nothing else in this repo would catch it, so it is asserted here.
#
# Network-free: --compare takes two local tarballs, so the suite runs anywhere
# `npm run test:sh` does.
#
# Exit-code contract under test: 0 = success / tarballs equivalent, 1 = tarballs
# differ, 2 = usage or setup error.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/../scripts/pack-memory-plugin.sh"
PLUGIN_DIR="${HERE}/../ci-context/plugins/companionintelligence"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

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

run_status() {
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  printf '%s' "${status}"
}

echo "pack-memory-plugin.sh"

echo "release tag → npm version"
assert_eq "plain CalVer passes through" "2026.7.29" "$("${SCRIPT}" --npm-version 2026.7.29)"
assert_eq "same-day suffix becomes a prerelease" "2026.7.7-2" "$("${SCRIPT}" --npm-version 2026.7.7.2)"
assert_eq "a leading v is tolerated" "2026.8.1" "$("${SCRIPT}" --npm-version v2026.8.1)"
assert_eq "a non-release tag is a setup error" "2" "$(run_status "${SCRIPT}" --npm-version latest)"

echo "packing"
TGZ_A="$("${SCRIPT}" --pack --version 2026.8.1 --out "${WORK}/a")"
assert_eq "pack prints a path that exists" "yes" "$([[ -f "${TGZ_A}" ]] && echo yes || echo no)"

# LC_ALL=C so the expected order is byte order on every machine.
CONTENTS="$(tar -tzf "${TGZ_A}" | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "ships the plugin files and no Python tests" \
  "package/README.md package/__init__.py package/intent_catalog.py package/package.json package/plugin.yaml " \
  "${CONTENTS}"

assert_eq "plugin.yaml is stamped with the release version" "version: 2026.8.1" \
  "$(tar -xzOf "${TGZ_A}" package/plugin.yaml | grep '^version:')"
assert_eq "package.json is stamped too" "2026.8.1" \
  "$(tar -xzOf "${TGZ_A}" package/package.json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).version))')"

# Staging must not write to the checkout: a publish job that mutates the tree it just
# tested is a tree nobody reviewed.
assert_eq "the working tree is left unstamped" "version: 1.0.0" \
  "$(grep '^version:' "${PLUGIN_DIR}/plugin.yaml")"

echo "the documented install"
# Exactly what the README tells a user to run, against a plugin dir that already has
# a config.json — the upgrade case, where clobbering the user's credentials would be
# the worst possible failure.
HERMES_PLUGIN="${WORK}/hermes/plugins/companionintelligence"
mkdir -p "${HERMES_PLUGIN}"
printf '{"url":"https://memory.example.com"}\n' >"${HERMES_PLUGIN}/config.json"
tar -xz -C "${HERMES_PLUGIN}" --strip-components=1 -f "${TGZ_A}"

# The loader scans for plugin.yaml at the top of the plugin directory. If
# --strip-components=1 ever stops being right, this is what catches it.
assert_eq "plugin.yaml lands at the top level" "yes" \
  "$([[ -f "${HERMES_PLUGIN}/plugin.yaml" ]] && echo yes || echo no)"
assert_eq "the provider module lands beside it" "yes" \
  "$([[ -f "${HERMES_PLUGIN}/__init__.py" ]] && echo yes || echo no)"
assert_eq "no stray package/ directory" "no" \
  "$([[ -d "${HERMES_PLUGIN}/package" ]] && echo yes || echo no)"
assert_eq "an existing config.json survives the extract" '{"url":"https://memory.example.com"}' \
  "$(cat "${HERMES_PLUGIN}/config.json")"

echo "comparing"
TGZ_B="$("${SCRIPT}" --pack --version 2026.9.9 --out "${WORK}/b")"
assert_eq "same plugin at two versions compares equal" "0" "$(run_status "${SCRIPT}" --compare "${TGZ_A}" "${TGZ_B}")"

CHANGED="${WORK}/changed"
mkdir -p "${CHANGED}"
tar -xzf "${TGZ_B}" -C "${CHANGED}"
printf '\n# a real change\n' >>"${CHANGED}/package/__init__.py"
tar -czf "${WORK}/changed.tgz" -C "${CHANGED}" package
assert_eq "a changed plugin compares unequal" "1" "$(run_status "${SCRIPT}" --compare "${TGZ_A}" "${WORK}/changed.tgz")"

assert_eq "a missing tarball is a setup error" "2" "$(run_status "${SCRIPT}" --compare "${TGZ_A}" "${WORK}/nope.tgz")"
assert_eq "no mode is a usage error" "2" "$(run_status "${SCRIPT}")"

echo
echo "  ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
