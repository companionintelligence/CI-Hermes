#!/usr/bin/env bash
# Package the Companion Intelligence memory plugin for distribution, and decide
# whether a release actually changed it.
#
# WHY A TARBALL, AND WHY npm HOSTS IT
#
# Hermes has no plugin registry. Its loader scans $HERMES_HOME/plugins/<name>/ for a
# plugin.yaml and never looks at site-packages, so `pip install` of the plugin would
# put it somewhere Hermes cannot see. The official unit of installation IS a
# directory in the plugins dir — so the honest artifact is a tarball the user
# extracts there, which is exactly what the README documents.
#
# It is published to the npm registry purely as versioned tarball hosting with a
# predictable, anonymous URL:
#
#   https://registry.npmjs.org/@companionintelligence/hermes-memory/-/hermes-memory-<v>.tgz
#
# The user never runs npm — the documented install is one curl into the plugins dir.
# GitHub Release assets cannot serve this: the repo is private, so its assets are not
# anonymously downloadable. PyPI cannot either: it has no predictable file URL.
#
# VERSION STAMPING
#
# package.json carries the registry coordinate; plugin.yaml carries the version
# Hermes itself reports. Both are stamped so an installed plugin reports the version
# that was installed. The working tree keeps 1.0.0 in both — that is what the
# appliance image ships, since it copies this directory rather than downloading a
# release — and stamping happens in a staging copy, so this script never writes to
# the working tree.
#
# USAGE
#   pack-memory-plugin.sh --npm-version <tag>              # map a release tag to an npm version
#   pack-memory-plugin.sh --pack --version <v> --out <dir> # stage, stamp, npm pack; prints the tarball path
#   pack-memory-plugin.sh --compare <a.tgz> <b.tgz>        # 0 = same plugin, 1 = differs (version fields ignored)
#
# EXIT CODES
#   0  success, or --compare found the two tarballs equivalent
#   1  --compare found a real difference (for the publish workflow: publish)
#   2  usage or setup error
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)/ci-context/plugins/companionintelligence"
NORMALIZED="0.0.0-normalized"

die() { echo "$*" >&2; exit 2; }

# Map a release tag to a valid npm version.
#
# Release tags are CalVer vYYYY.M.D with an optional same-day suffix. Four segments
# is not semver and npm rejects it, so the suffix becomes a prerelease:
# 2026.7.7.2 -> 2026.7.7-2.
#
# Known wart, accepted: semver sorts a prerelease BELOW its release, so 2026.7.7-2
# ranks under 2026.7.7 even though it ships later. It does not bite in practice
# because the install URL names an exact version and npm's `latest` dist-tag follows
# publish order rather than sort order.
npm_version() {
  local tag="${1#v}"
  [[ -n "${tag}" ]] || die "empty tag"
  if [[ "${tag}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)$ ]]; then
    printf '%s-%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  elif [[ "${tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    printf '%s\n' "${tag}"
  else
    die "tag '${1}' is not a release tag this script can map to an npm version"
  fi
}

# Rewrite the `version:` value in a plugin.yaml. Deliberately a line edit rather than
# a YAML round-trip: the file is ten lines we own, and a round-trip would need PyYAML
# present wherever this runs and would reformat the rest of the file as a side effect.
stamp_plugin_yaml() {
  local path="${1}" version="${2}"
  grep -qE '^version:' "${path}" || die "no version: line in ${path}"
  # A temp file plus mv, because in-place sed differs between GNU and BSD.
  sed -E "s/^version:.*/version: ${version}/" "${path}" >"${path}.tmp"
  mv "${path}.tmp" "${path}"
}

stamp_package_json() {
  local path="${1}" version="${2}"
  VERSION="${version}" node -e '
    const fs = require("node:fs");
    const p = process.argv[1];
    const doc = JSON.parse(fs.readFileSync(p, "utf8"));
    doc.version = process.env.VERSION;
    fs.writeFileSync(p, JSON.stringify(doc, null, 2) + "\n");
  ' "${path}"
}

do_pack() {
  local version="${1}" outdir="${2}"
  [[ -n "${version}" ]] || die "--pack needs --version"
  [[ -n "${outdir}" ]] || die "--pack needs --out"
  [[ -d "${PLUGIN_DIR}" ]] || die "no plugin directory at ${PLUGIN_DIR}"

  mkdir -p "${outdir}"
  local stage
  stage="$(mktemp -d)"
  trap 'rm -rf "${stage}"' RETURN

  cp -R "${PLUGIN_DIR}/." "${stage}/"
  [[ -f "${stage}/plugin.yaml" ]] || die "expected plugin.yaml in the plugin directory"
  [[ -f "${stage}/package.json" ]] || die "expected package.json in the plugin directory"
  stamp_plugin_yaml "${stage}/plugin.yaml" "${version}"
  stamp_package_json "${stage}/package.json" "${version}"

  # `npm pack` applies the `files` allowlist, which is what keeps the plugin's own
  # ~39KB of Python tests out of the published artifact.
  local tarball
  tarball="$(cd "${stage}" && npm pack --silent --pack-destination "${outdir}")"
  [[ -n "${tarball}" ]] || die "npm pack produced no tarball"
  printf '%s\n' "${outdir%/}/${tarball}"
}

# Compare two packed tarballs, ignoring the stamped version fields, so this answers
# "did the plugin change" rather than "is this a different release".
#
# Network-free by design: the publish workflow downloads the published tarball and
# hands both paths here, so the seam stays testable offline.
do_compare() {
  local a="${1}" b="${2}"
  [[ -f "${a}" ]] || die "no such tarball: ${a}"
  [[ -f "${b}" ]] || die "no such tarball: ${b}"

  local work
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' RETURN

  # Plain `if`s rather than `[[ ... ]] && cmd`: under `set -e` a false test makes the
  # whole && list return non-zero, which aborts the function instead of skipping.
  local side src
  for side in a b; do
    mkdir -p "${work}/${side}"
    if [[ "${side}" == "b" ]]; then src="${b}"; else src="${a}"; fi
    # npm tarballs root everything under package/; strip it so the trees compare directly.
    tar -xzf "${src}" -C "${work}/${side}" --strip-components=1
    if [[ -f "${work}/${side}/plugin.yaml" ]]; then
      stamp_plugin_yaml "${work}/${side}/plugin.yaml" "${NORMALIZED}"
    fi
    if [[ -f "${work}/${side}/package.json" ]]; then
      stamp_package_json "${work}/${side}/package.json" "${NORMALIZED}"
    fi
  done

  if diff -r "${work}/a" "${work}/b" >/dev/null 2>&1; then
    return 0
  fi
  diff -r "${work}/a" "${work}/b" >&2 || true
  return 1
}

MODE=""
VERSION=""
OUTDIR=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "${1}" in
    --npm-version) MODE="npm-version"; shift; ARGS+=("${1:-}"); shift || true ;;
    --pack)        MODE="pack"; shift ;;
    --compare)     MODE="compare"; shift ;;
    --version)     shift; VERSION="${1:-}"; shift || true ;;
    --out)         shift; OUTDIR="${1:-}"; shift || true ;;
    -h|--help)
      cat <<'USAGE'
pack-memory-plugin.sh --npm-version <tag>              map a release tag to an npm version
pack-memory-plugin.sh --pack --version <v> --out <dir> stage, stamp, npm pack; prints the tarball path
pack-memory-plugin.sh --compare <a.tgz> <b.tgz>        0 = same plugin, 1 = differs (version fields ignored)
USAGE
      exit 0 ;;
    *)             ARGS+=("${1}"); shift ;;
  esac
done

case "${MODE}" in
  npm-version) npm_version "${ARGS[0]:-}" ;;
  pack)        do_pack "${VERSION}" "${OUTDIR}" ;;
  compare)     do_compare "${ARGS[0]:-}" "${ARGS[1]:-}" ;;
  *)           die "usage: $0 --npm-version <tag> | --pack --version <v> --out <dir> | --compare <a.tgz> <b.tgz>" ;;
esac
