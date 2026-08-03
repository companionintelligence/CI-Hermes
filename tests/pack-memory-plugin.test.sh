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
# The allowlist probe below is the one thing this suite writes OUTSIDE its temp dir —
# it has to land in the real plugin directory to be seen by the check under test. So
# it is cleaned up by the same trap: interrupt the suite (Ctrl-C, a cancelled CI job)
# between creating and removing it and it stays in the checkout, after which every
# subsequent `--pack` fails with exit 2 until somebody works out why.
STRAY="${PLUGIN_DIR}/__packaging_probe.py"
trap 'rm -rf "${WORK}"; rm -f "${STRAY}"' EXIT

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
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "  ✓ ${label}"
    PASS=$((PASS + 1))
  else
    echo "  ✗ ${label}"
    echo "    expected output to contain: ${needle}"
    echo "    got: ${haystack}"
    FAIL=$((FAIL + 1))
  fi
}

run_status() {
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  printf '%s' "${status}"
}

TREE_YAML_VERSION="$(grep '^version:' "${PLUGIN_DIR}/plugin.yaml")"
TREE_PKG_VERSION="$(node -e 'console.log(require(process.argv[1]).version)' "${PLUGIN_DIR}/package.json")"

echo "pack-memory-plugin.sh"

echo "release tag → npm version"
assert_eq "plain CalVer passes through" "2026.7.29" "$("${SCRIPT}" --npm-version 2026.7.29)"
assert_eq "same-day suffix becomes a prerelease" "2026.7.7-2" "$("${SCRIPT}" --npm-version 2026.7.7.2)"
assert_eq "a leading v is tolerated" "2026.8.1" "$("${SCRIPT}" --npm-version v2026.8.1)"
assert_eq "a non-release tag is a setup error" "2" "$(run_status "${SCRIPT}" --npm-version latest)"
assert_eq "a zero-padded tag is refused" "2" "$(run_status "${SCRIPT}" --npm-version v2026.08.01)"
# The two validators must agree. They did not: npm_version allowed a hyphen inside the
# prerelease and --pack did not, so v2026.8.1-rc-1 mapped cleanly and then failed the
# pack — after the whole CI gate had run. Assert the round trip, not each half.
assert_eq "a hyphenated prerelease maps" "2026.8.1-rc-1" "$("${SCRIPT}" --npm-version v2026.8.1-rc-1)"
assert_eq "and the version it maps to is one --pack accepts" "0" \
  "$(run_status "${SCRIPT}" --pack --version "$("${SCRIPT}" --npm-version v2026.8.1-rc-1)" --out "${WORK}/pre")"

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
# tested is a tree nobody reviewed. Captured rather than hardcoded, so a legitimate
# version bump does not fail this for an unrelated reason. Both files are checked —
# asserting only plugin.yaml would miss stamp_package_json writing in place.
assert_eq "plugin.yaml in the working tree is untouched" "${TREE_YAML_VERSION}" \
  "$(grep '^version:' "${PLUGIN_DIR}/plugin.yaml")"
assert_eq "package.json in the working tree is untouched" "${TREE_PKG_VERSION}" \
  "$(node -e 'console.log(require(process.argv[1]).version)' "${PLUGIN_DIR}/package.json")"
# `private: true` is what stops a stray `npm publish` from the plugin directory
# burning a version and moving the `latest` dist-tag the change-guard reads.
assert_eq "the working tree keeps private: true" "true" \
  "$(node -e 'console.log(require(process.argv[1]).private)' "${PLUGIN_DIR}/package.json")"
assert_eq "the published tarball drops private" "undefined" \
  "$(tar -xzOf "${TGZ_A}" package/package.json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(String(JSON.parse(s).private)))')"

echo "the files allowlist covers the plugin directory"
# The guard against the worst failure this script can produce. `files` is a
# hand-maintained allowlist while the appliance image copies the whole directory, so
# splitting a module out of __init__.py without updating `files` ships it in the
# image, omits it from the tarball, and makes every future release compare as
# "identical" and skip — leaving stock users importing a module that is not there,
# on a permanently green pipeline.
printf 'PROBE = 1\n' >"${STRAY}"
# One pack, not two: status and output come from the same run, so they cannot describe
# different invocations and the suite does not stage and pack the plugin twice.
STRAY_STATUS=0
STRAY_OUT="$("${SCRIPT}" --pack --version 2026.8.2 --out "${WORK}/stray" 2>&1)" || STRAY_STATUS=$?
rm -f "${STRAY}"
assert_eq "an unlisted file in the plugin dir fails the pack" "2" "${STRAY_STATUS}"
assert_contains "and names the offending file" "__packaging_probe.py" "${STRAY_OUT}"

# The excluded set must still not trip it, or every pack fails and the guard gets
# deleted by the next person in a hurry.
assert_eq "the plugin's own Python tests do not trip it" "0" \
  "$(run_status "${SCRIPT}" --pack --version 2026.8.3 --out "${WORK}/ok")"

# The guard has to fail CLOSED. It did not: the listing was piped straight into a
# `while` via process substitution, whose exit status is discarded, so a `find` that
# failed — BSD/macOS have no -printf — produced zero lines, an empty `missing`, and a
# green pack that shipped a short tarball. Simulated with a find that always fails,
# which is exactly what a non-GNU find does with -printf.
FAKEBIN="${WORK}/fakebin"
mkdir -p "${FAKEBIN}"
printf '#!/bin/sh\necho "find: -printf: unknown primary or operator" >&2\nexit 1\n' >"${FAKEBIN}/find"
chmod +x "${FAKEBIN}/find"
FAILCLOSED=0
PATH="${FAKEBIN}:${PATH}" "${SCRIPT}" --pack --version 2026.8.4 --out "${WORK}/failclosed" \
  >/dev/null 2>&1 || FAILCLOSED=$?
assert_eq "a listing failure is a setup error, not a silent pass" "2" "${FAILCLOSED}"

echo "the documented install"
# Exactly what the README tells a user to run, over a plugin dir that already holds an
# unrelated file — the upgrade case, asserting the extract only adds the archive's own
# entries. config.json stands in for that file because it is the shape someone would
# expect to find here; note the plugin actually keeps it in
# $HERMES_HOME/companionintelligence/, OUTSIDE this directory, which is precisely why
# the README can tell users to `rm -rf` the plugin dir before upgrading.
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
assert_eq "an unrelated existing file survives the extract" '{"url":"https://memory.example.com"}' \
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

# Exit 1 means exactly one thing to the publish workflow: "the plugin changed, ship
# it". An internal failure surfacing as 1 would silently become a release, so a
# corrupt input must be 2 and never 1.
printf 'not a tarball\n' >"${WORK}/corrupt.tgz"
assert_eq "a corrupt tarball is a setup error, not a difference" "2" \
  "$(run_status "${SCRIPT}" --compare "${TGZ_A}" "${WORK}/corrupt.tgz")"

# `&` in a sed replacement expands to the whole match, which silently produced a
# valid-looking tarball with a corrupt plugin.yaml. The version must be refused.
assert_eq "a sed-hostile --version is refused" "2" \
  "$(run_status "${SCRIPT}" --pack --version '1.0.0-x&y' --out "${WORK}/hostile")"
assert_eq "a slash in --version is refused" "2" \
  "$(run_status "${SCRIPT}" --pack --version 'a/b' --out "${WORK}/hostile2")"
# `tar --strip-components=1` drops single-component members and still exits 0, so a
# differently rooted tarball extracts to nothing. Two of those must not compare equal.
mkdir -p "${WORK}/flat"
printf 'name: x\nversion: 1.0.0\n' >"${WORK}/flat/plugin.yaml"
tar -czf "${WORK}/flat1.tgz" -C "${WORK}/flat" plugin.yaml
tar -czf "${WORK}/flat2.tgz" -C "${WORK}/flat" plugin.yaml
assert_eq "two empty extractions are not called identical" "2" \
  "$(run_status "${SCRIPT}" --compare "${WORK}/flat1.tgz" "${WORK}/flat2.tgz")"

# One of the two tarballs is fetched from the registry, so its member names are the
# only input here this script does not produce itself. A member resolving outside the
# extraction directory must be a setup error (2), never a difference (1) — and must not
# rely on the local tar refusing it, since GNU tar errors out where bsdtar skips the
# member and still exits 0.
mkdir -p "${WORK}/evil/sub/package"
printf 'x\n' >"${WORK}/evil/ESCAPED"
printf 'x\n' >"${WORK}/evil/sub/package/plugin.yaml"
# -P keeps the `..` that tar would otherwise strip while writing the archive.
( cd "${WORK}/evil/sub" && tar -cPzf "${WORK}/traverse.tgz" package ../ESCAPED ) 2>/dev/null
# Assert the fixture itself, or a tar that strips `..` at create time would make the
# check below pass for entirely the wrong reason.
assert_contains "the traversal fixture really carries a .. member" "../ESCAPED" \
  "$(tar -tzf "${WORK}/traverse.tgz" 2>/dev/null)"
assert_eq "a path-traversing tarball is a setup error" "2" \
  "$(run_status "${SCRIPT}" --compare "${TGZ_A}" "${WORK}/traverse.tgz")"

assert_eq "no mode is a usage error" "2" "$(run_status "${SCRIPT}")"

echo
echo "  ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
