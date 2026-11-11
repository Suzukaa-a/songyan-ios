#!/usr/bin/env bash
# Fetches the pinned QuickJS-ng sources and prints the directory that contains them.
#
# The version, repository and archive digest live in Tools/BuildRimeIOS/QUICKJS-VERSIONS.env, next
# to the other shared engine pins, so both platforms read one file. A tag without a recorded digest, a download whose
# digest differs, or a source tree without the files the bridge compiles is refused: a build must
# never link an engine that changed under the same name.
#
# The sources are cached under the repository's git-ignored .local/ directory the same way the
# Rime engine sources are, so nothing third-party is committed. Re-running this script is cheap.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../.." && pwd)"
VERSIONS="${HERE}/../../BuildRimeIOS/QUICKJS-VERSIONS.env"
# shellcheck source=../../BuildRimeIOS/QUICKJS-VERSIONS.env
source "${VERSIONS}"

CACHE="${QUICKJS_CACHE:-${ROOT}/.local/script-vendor}"
ARCHIVE="${CACHE}/quickjs-ng-${QUICKJS_TAG}.tar.gz"
SOURCE="${CACHE}/quickjs-ng-${QUICKJS_TAG}"
URL="${QUICKJS_REPOSITORY}/archive/refs/tags/${QUICKJS_TAG}.tar.gz"

digest_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

mkdir -p "${CACHE}"
if [[ -f "${ARCHIVE}" ]]; then
  actual="$(digest_of "${ARCHIVE}")"
  if [[ "${actual}" != "${QUICKJS_ARCHIVE_SHA256}" ]]; then
    echo "quickjs: cached archive digest ${actual} differs from the pin ${QUICKJS_ARCHIVE_SHA256}; refusing to use ${ARCHIVE}" >&2
    exit 65
  fi
else
  download="${ARCHIVE}.download"
  echo "quickjs: downloading ${URL}" >&2
  curl -fsSL --retry 3 --connect-timeout 20 -o "${download}" "${URL}"
  actual="$(digest_of "${download}")"
  if [[ "${actual}" != "${QUICKJS_ARCHIVE_SHA256}" ]]; then
    # A single file, not a tree: leave the bad download for inspection rather than deleting it.
    echo "quickjs: downloaded archive digest ${actual} differs from the pin ${QUICKJS_ARCHIVE_SHA256}; kept ${download}" >&2
    exit 65
  fi
  mv "${download}" "${ARCHIVE}"
fi

if [[ ! -d "${SOURCE}" ]]; then
  # Unpack beside the cache first, then move the tree into place, so an interrupted extraction
  # never looks like a usable source tree.
  staging="${CACHE}/.unpack-${$}"
  mkdir -p "${staging}"
  tar -xzf "${ARCHIVE}" -C "${staging}"
  unpacked=""
  for candidate in "${staging}"/*/; do
    unpacked="${candidate%/}"
    break
  done
  if [[ -z "${unpacked}" || ! -d "${unpacked}" ]]; then
    echo "quickjs: ${ARCHIVE} did not contain a source directory; left ${staging} for inspection" >&2
    exit 65
  fi
  mv "${unpacked}" "${SOURCE}"
  rmdir "${staging}" 2>/dev/null || true
fi

for required in quickjs.c quickjs.h libregexp.c libunicode.c dtoa.c cutils.h list.h; do
  if [[ ! -f "${SOURCE}/${required}" ]]; then
    echo "quickjs: ${SOURCE} is missing ${required}; remove that directory and rerun" >&2
    exit 65
  fi
done

printf '%s\n' "${SOURCE}"
