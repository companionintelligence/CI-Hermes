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
# Files that may turn up in the plugin directory but must not ship. Anything in the
# directory matching none of these MUST appear in the tarball — see
# assert_files_cover_plugin_dir for why that check exists at all.
#
# The first three are real: the plugin's own unittest files are checked in, and
# __pycache__/*.pyc appear the moment anyone runs them. `config.json` is defensive
# only — `hermes memory setup` writes it to $HERMES_HOME/companionintelligence/,
# never into the plugin directory (see the plugin's __init__.py), which is what lets
# the README promise that `rm -rf`-ing this directory cannot destroy credentials.
NOT_PUBLISHED=('*_test.py' '*.pyc' '__pycache__/*' 'config.json')

die() { echo "$*" >&2; exit 2; }

# Temp dirs are registered here and removed by a single EXIT trap. A per-function
# `trap ... RETURN` does not fire when the function exits (every `die`) or when
# errexit aborts it, which leaked a full copy of the plugin source per failure.
TMPDIRS=()
cleanup() {
  local d
  for d in "${TMPDIRS[@]:-}"; do
    if [[ -n "${d}" && -d "${d}" ]]; then rm -rf "${d}"; fi
  done
  # Explicit: the trap's exit status becomes the script's, so a falsy last command
  # here turns a successful run into a failure.
  return 0
}
trap cleanup EXIT

# Sets MKTEMP_DIR rather than printing it. A `$(mktempdir)` would run in a subshell,
# where the TMPDIRS append is discarded and the directory is never cleaned up.
MKTEMP_DIR=""
mktempdir() {
  MKTEMP_DIR="$(mktemp -d)" || die "mktemp failed"
  TMPDIRS+=("${MKTEMP_DIR}")
}

# Fail if the plugin directory contains a file the tarball does not ship.
#
# THIS IS THE MOST IMPORTANT CHECK IN THE SCRIPT. `files` in package.json is a
# hand-maintained allowlist, but the appliance image copies the whole directory. Split
# a module out of __init__.py without touching `files`, and: the image gets it, the
# tarball does not, --compare finds the two tarballs identical so the release is
# logged as "image-only" and skipped, and every later release repeats the skip. Stock
# users are left on a version whose remaining files import a module that is not
# there. It never self-heals and the job stays green throughout.
assert_files_cover_plugin_dir() {
  local tarball="${1}"
  local shipped missing=()
  shipped="$(tar -tzf "${tarball}" | sed 's|^package/||' | grep -v '/$' | LC_ALL=C sort)" \
    || die "could not list ${tarball}"

  # Captured before the loop rather than piped straight into `while`. A process
  # substitution discards the producer's exit status, so a `find` that failed — an
  # unreadable directory, or the GNU-only `-printf` this once used, which BSD/macOS
  # find rejects outright — fed the loop zero lines, left `missing` empty, and made
  # THIS check return success while packing a short tarball. The one check that must
  # never fail open was the one that did. `-print` plus a `./` strip is the portable
  # equivalent, and pipefail keeps a failing `find` fatal through the pipe.
  local listing
  listing="$(cd "${PLUGIN_DIR}" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort)" \
    || die "could not list ${PLUGIN_DIR}"
  [[ -n "${listing}" ]] || die "found no files in ${PLUGIN_DIR}"

  # Plain `if`s throughout: under errexit a bare `[[ ... ]] && cmd` whose test is
  # false returns non-zero and aborts the function rather than skipping the line.
  local rel skip pattern
  while IFS= read -r rel; do
    skip=0
    for pattern in "${NOT_PUBLISHED[@]}"; do
      # shellcheck disable=SC2053 -- glob match is intended
      if [[ "${rel}" == ${pattern} ]]; then
        skip=1
      fi
    done
    if [[ "${skip}" -eq 0 ]]; then
      if ! grep -qxF "${rel}" <<<"${shipped}"; then
        missing+=("${rel}")
      fi
    fi
  done <<<"${listing}"

  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'These files are in the plugin directory but the published tarball does not ship them:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    printf 'Add them to "files" in package.json, or to NOT_PUBLISHED in %s if they are deliberately excluded.\n' "$0" >&2
    exit 2
  fi
}

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
  # No leading zeros in any segment: npm silently rewrites 2026.08.01 to 2026.8.1 at
  # publish time, after which the registry version, the version stamped into the
  # shipped plugin, and the URL the workflow verifies all disagree.
  if [[ "${tag}" =~ (^|\.)0[0-9] ]]; then
    die "tag '${1}' has a zero-padded segment; npm would silently renumber it"
  fi
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
  # A temp file plus mv, because in-place sed differs between GNU and BSD. The
  # version is validated by the caller, so it carries no sed metacharacters.
  sed -E "s/^version:.*/version: ${version}/" "${path}" >"${path}.tmp" \
    || die "could not rewrite ${path}"
  mv "${path}.tmp" "${path}" || die "could not replace ${path}"
}

stamp_package_json() {
  local path="${1}" version="${2}"
  VERSION="${version}" node -e '
    const fs = require("node:fs");
    const p = process.argv[1];
    const doc = JSON.parse(fs.readFileSync(p, "utf8"));
    doc.version = process.env.VERSION;
    // `private: true` stays in the working tree so a stray `npm publish` from the
    // plugin directory refuses; it is stripped only here, in the staging copy that
    // becomes the published artifact. Without that, a local publish would burn a
    // version number AND move the `latest` dist-tag the change-guard reads.
    if (process.env.STRIP_PRIVATE === "1") { delete doc.private; }
    fs.writeFileSync(p, JSON.stringify(doc, null, 2) + "\n");
  ' "${path}" || die "could not stamp $(basename "${path}")"
}

do_pack() {
  local version="${1}" outdir="${2}"
  [[ -n "${version}" ]] || die "--pack needs --version"
  [[ -n "${outdir}" ]] || die "--pack needs --out"
  [[ -d "${PLUGIN_DIR}" ]] || die "no plugin directory at ${PLUGIN_DIR}"
  # Validate rather than trust. This is load-bearing beyond hygiene: the version is
  # substituted into a `sed` replacement below, where an `&` expands to the whole
  # match and a `/` ends the expression — one produces a corrupt manifest at exit 0,
  # the other an error that collides with the documented exit codes. Rejecting the
  # input up front is simpler than escaping it.
  #
  # The prerelease class must stay in step with npm_version's, hyphen included.
  # It did not, and the gap was reachable: tag v2026.8.1-rc-1 satisfies the
  # workflow's tag glob and npm_version emits it unchanged, then --pack rejected it
  # — a release that failed here, after the full CI gate had already run. A hyphen
  # is inert in a sed replacement, so accepting it costs nothing.
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
    || die "--version '${version}' is not a valid release version"

  mkdir -p "${outdir}" || die "could not create ${outdir}"
  # Absolute, because npm pack runs after `cd "${stage}"` and would otherwise
  # resolve a relative --out inside the staging dir, which is then deleted.
  outdir="$(cd "${outdir}" && pwd)" || die "could not resolve ${outdir}"

  local stage
  mktempdir; stage="${MKTEMP_DIR}"

  cp -R "${PLUGIN_DIR}/." "${stage}/"
  [[ -f "${stage}/plugin.yaml" ]] || die "expected plugin.yaml in the plugin directory"
  [[ -f "${stage}/package.json" ]] || die "expected package.json in the plugin directory"
  stamp_plugin_yaml "${stage}/plugin.yaml" "${version}"
  STRIP_PRIVATE=1 stamp_package_json "${stage}/package.json" "${version}"

  # `npm pack` applies the `files` allowlist, which is what keeps the plugin's own
  # ~39KB of Python tests out of the published artifact.
  local tarball
  tarball="$(cd "${stage}" && npm pack --silent --pack-destination "${outdir}")" \
    || die "npm pack failed"
  [[ -n "${tarball}" ]] || die "npm pack produced no tarball"
  assert_files_cover_plugin_dir "${outdir%/}/${tarball}"
  printf '%s\n' "${outdir%/}/${tarball}"
}

# Compare two packed tarballs, ignoring the stamped version fields, so this answers
# "did the plugin change" rather than "is this a different release".
#
# Network-free by design: the publish workflow downloads the published tarball and
# hands both paths here, so the seam stays testable offline.
#
# Every failure in here `die`s with 2 rather than being allowed to surface as 1.
# Exit 1 means one thing to the caller — "the plugin changed, publish it" — so an
# internal error leaking out as 1 would silently turn into a release. Only the final
# diff may produce 1.
#
# Refuse a tarball whose member names could be written outside the extraction
# directory, before unpacking it.
#
# Not a theoretical concern to the extent that tar is already careful: GNU tar 1.35
# refuses a `..` member outright ("Member name contains '..'", exit 2) and strips a
# leading `/`, and `do_compare` dies on that non-zero exit. But bsdtar on macOS skips
# such members and still exits 0, which hands the comparison a partial tree that reads
# as "the plugin changed" — and one of the two tarballs comes from the registry, the
# only input here this script does not produce itself. Check it rather than depend on
# which tar happens to be installed.
assert_tarball_members_safe() {
  local tarball="${1}" listing member unsafe=()
  listing="$(tar -tzf "${tarball}")" || die "could not list ${tarball}"
  while IFS= read -r member; do
    case "${member}" in
      /*|../*|*/../*|*/..|..) unsafe+=("${member}") ;;
    esac
  done <<<"${listing}"
  if [[ "${#unsafe[@]}" -gt 0 ]]; then
    printf 'Refusing %s — these member names would escape the extraction directory:\n' \
      "${tarball}" >&2
    printf '  %s\n' "${unsafe[@]}" >&2
    die "unsafe tarball member names"
  fi
}

do_compare() {
  local a="${1}" b="${2}"
  [[ -f "${a}" ]] || die "no such tarball: ${a}"
  [[ -f "${b}" ]] || die "no such tarball: ${b}"

  local work
  mktempdir; work="${MKTEMP_DIR}"

  # Plain `if`s rather than `[[ ... ]] && cmd`: under `set -e` a false test makes the
  # whole && list return non-zero, which aborts the function instead of skipping.
  local side src
  for side in a b; do
    mkdir -p "${work}/${side}" || die "could not create ${work}/${side}"
    if [[ "${side}" == "b" ]]; then src="${b}"; else src="${a}"; fi
    # npm tarballs root everything under package/; strip it so the trees compare directly.
    assert_tarball_members_safe "${src}"
    tar -xzf "${src}" -C "${work}/${side}" --strip-components=1 \
      || die "could not extract ${src}"
    if [[ -f "${work}/${side}/plugin.yaml" ]]; then
      stamp_plugin_yaml "${work}/${side}/plugin.yaml" "${NORMALIZED}"
    fi
    if [[ -f "${work}/${side}/package.json" ]]; then
      stamp_package_json "${work}/${side}/package.json" "${NORMALIZED}"
    fi
  done

  # Both extracted trees must be non-empty. `tar --strip-components=1` silently drops
  # entries with fewer than two path components and still exits 0, so a differently
  # rooted tarball would extract to nothing and compare equal to another one — a
  # permanent "identical, image-only release" skip.
  local side
  for side in a b; do
    if [[ -z "$(ls -A "${work}/${side}")" ]]; then
      die "extracted an empty tree from the ${side} tarball; refusing to call that identical"
    fi
  done

  # diff exits 0 same, 1 differs, 2 TROUBLE. Mapping anything non-zero to 1 would turn
  # an unreadable file into a publish.
  local diff_status=0
  diff -r "${work}/a" "${work}/b" >/dev/null 2>&1 || diff_status=$?
  if [[ "${diff_status}" -eq 0 ]]; then
    return 0
  fi
  if [[ "${diff_status}" -ne 1 ]]; then
    die "diff failed with status ${diff_status} while comparing the tarballs"
  fi
  # --brief: the payload is a 35KB __init__.py and a full unified diff of it helps
  # nobody in a workflow log.
  diff -rq "${work}/a" "${work}/b" >&2 || true
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
