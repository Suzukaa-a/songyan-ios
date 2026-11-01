#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 38-resource-id-harness.sh — macOS regression for
# Tools/BuildRimeIOS/patches/librime-resource-id-confinement.patch.
#
# The macOS librime.a from Tools/BuildRime is unpatched, so this script applies
# every patch in Tools/BuildRimeIOS/patches to a copy of the pinned sources,
# compiles the two translation units the confinement patch changes and links
# them ahead of librime.a. harness-mac/resource-id-main.cc then deploys a schema
# whose user dictionary is an absolute path and whose dictionary names "../x",
# and checks that nothing outside the user folder is created or read while the
# schema keeps working.
#
# Nothing outside a fresh run directory is written except one mkdtemp folder in
# the system temporary directory, which the harness removes.
#
# Usage:
#   Tools/BuildRimeIOS/scripts/38-resource-id-harness.sh [--unpatched]
# --unpatched links the stock objects instead, to show the harness catches the
# escape (it is expected to fail).
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

UNPATCHED=0
[[ "${1:-}" == "--unpatched" ]] && UNPATCHED=1

GEN_INCLUDE="$(rime_generated_include)"
RUN_DIR="$(new_harness_dir resource-id)"
prepare_native_bridge

say "apply patches to a copy of librime"
PATCHED="${RUN_DIR}/librime"
mkdir -p "${PATCHED}"
cp -R "${LIBRIME_SRC}/src" "${LIBRIME_SRC}/include" "${PATCHED}/"
git init --quiet "${PATCHED}"
for patch in "${IOS_TOOLS_DIR}"/patches/*.patch; do
  git -C "${PATCHED}" apply "${patch}"
done

declare -a OBJECTS=()
if [[ "${UNPATCHED}" == 0 ]]; then
  say "compile patched resource.cc and deployment_tasks.cc"
  for unit in resource lever/deployment_tasks; do
    object="${RUN_DIR}/$(basename "${unit}").o"
    "${MAC_CXX}" -I"${PATCHED}/src" "${MAC_CXX_FLAGS[@]}" \
      "${PATCHED}/src/rime/${unit}.cc" -o "${object}"
    OBJECTS+=("${object}")
  done
fi

say "compile + link harness"
"${MAC_CXX}" -std=c++17 -O2 -isysroot "${MACOS_SDK}" -mmacosx-version-min=13.0 \
  -I"${MAC_PREFIX}/include" "${IOS_TOOLS_DIR}/harness-mac/resource-id-main.cc" \
  ${OBJECTS[@]+"${OBJECTS[@]}"} "${MAC_LINK_FLAGS[@]}" -o "${RUN_DIR}/harness"

say "run harness"
"${RUN_DIR}/harness" "${RUN_DIR}/run"
say "resource-id harness PASS; run dir ${RUN_DIR}"
