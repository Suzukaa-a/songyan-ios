#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 44-opencc-harness.sh — macOS proof for the standalone OpenCC conversion ABI
# and its RimeBridge Swift adapter.
#
# Builds Tools/BuildRimeIOS/src/rime_opencc.cc, harness-mac/opencc-main.c and
# Packages/RimeBridge/Sources/RimeBridge/OpenCCConversion.swift against the pinned
# macOS OpenCC, then runs the REAL shipped configs and .ocd2 dictionaries from
# Resources/EngineResources/opencc. No librime archive is linked: a conversion
# must work without an engine and must never reach librime's process-global
# service/registry/session state.
#
# Nothing is deleted; all outputs go to a fresh isolated run dir. This does not
# rebuild the iOS XCFramework.
#
# Usage:
#   Tools/BuildRimeIOS/scripts/44-opencc-harness.sh
# Overrides:
#   NATIVE_ENGINE_ROOT   engine root holding prefix/ (default <repo>/.local/engine)
#   HARNESS_OUTPUT_ROOT  parent for the run dir (default <repo>/.scratch/native-harnesses)
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

CONFIG_DIR="${PROJECT_ROOT}/Resources/EngineResources/opencc"

[[ -f "${MAC_PREFIX}/lib/libopencc.a" ]] || die \
  "missing ${MAC_PREFIX}/lib/libopencc.a (run Tools/BuildRime)"
[[ -f "${CONFIG_DIR}/s2twp.json" ]] || die "missing the shipped OpenCC configs: ${CONFIG_DIR}"

RUN_DIR="$(new_harness_dir opencc-conversion)"

say "compile the C ABI"
"${MAC_CXX}" -std=c++17 -O2 -c -isysroot "${MACOS_SDK}" -mmacosx-version-min=13.0 \
  -DOpencc_BUILT_AS_STATIC -I"${SHIM_SRC_DIR}" -I"${MAC_PREFIX}/include" \
  "${SHIM_SRC_DIR}/rime_opencc.cc" -o "${RUN_DIR}/rime_opencc.o"
"${MAC_CC}" -std=c11 -O2 -c -isysroot "${MACOS_SDK}" -mmacosx-version-min=13.0 \
  -I"${SHIM_SRC_DIR}" "${IOS_TOOLS_DIR}/harness-mac/opencc-main.c" \
  -o "${RUN_DIR}/opencc-main.o"

# The link line carries no librime archive on purpose (see the header comment).
"${MAC_CXX}" -isysroot "${MACOS_SDK}" -target arm64-apple-macos13.0 \
  "${RUN_DIR}/opencc-main.o" "${RUN_DIR}/rime_opencc.o" \
  -Xlinker "${MAC_PREFIX}/lib/libopencc.a" -Xlinker "${MAC_PREFIX}/lib/libmarisa.a" \
  -lpthread -o "${RUN_DIR}/opencc-main"

say "run the C ABI checks"
"${RUN_DIR}/opencc-main" "${CONFIG_DIR}" "${RUN_DIR}"

say "stage the RimeKit module for the Swift adapter"
MODULE_DIR="${RUN_DIR}/RimeKitModule"
mkdir -p "${MODULE_DIR}"
cp "${MAC_PREFIX}/include/rime_api.h" "${MODULE_DIR}/"
cp "${SHIM_SRC_DIR}/rime_bridge.h" "${SHIM_SRC_DIR}/rime_opencc.h" "${MODULE_DIR}/"
cp "${IOS_TOOLS_DIR}/harness-mac/RimeKit.modulemap" "${MODULE_DIR}/module.modulemap"
cp "${IOS_TOOLS_DIR}/harness-mac/RimeKit.h" "${MODULE_DIR}/RimeKit.h"

say "compile the Swift adapter harness"
xcrun swiftc -swift-version 5 -O -sdk "${MACOS_SDK}" -target arm64-apple-macos13.0 \
  -Xcc -fmodule-map-file="${MODULE_DIR}/module.modulemap" \
  -I "${MODULE_DIR}" -I "${MAC_PREFIX}/include" \
  "${PROJECT_ROOT}/Packages/RimeBridge/Sources/RimeBridge/OpenCCConversion.swift" \
  "${IOS_TOOLS_DIR}/harness-mac/opencc-adapter-main.swift" \
  "${RUN_DIR}/rime_opencc.o" \
  -Xlinker "${MAC_PREFIX}/lib/libopencc.a" -Xlinker "${MAC_PREFIX}/lib/libmarisa.a" \
  -Xlinker -lc++ -Xlinker -lc++abi -lpthread \
  -o "${RUN_DIR}/opencc-adapter"

say "run the Swift adapter checks"
"${RUN_DIR}/opencc-adapter" "${CONFIG_DIR}" "${RUN_DIR}"

say "build the production tool runner"
PACKAGE_BUILD="${PROJECT_ROOT}/.local/native-harness-package-builds/QuickContentKit"
xcrun swift build --package-path "${PROJECT_ROOT}/Packages/QuickContentKit" \
  --scratch-path "${PACKAGE_BUILD}" --force-resolved-versions
BIN_DIR="$(xcrun swift build --package-path "${PROJECT_ROOT}/Packages/QuickContentKit" \
  --scratch-path "${PACKAGE_BUILD}" --show-bin-path)"
xcrun swiftc -swift-version 6 -O -sdk "${MACOS_SDK}" -target arm64-apple-macos13.0 \
  -Xcc -fmodule-map-file="${MODULE_DIR}/module.modulemap" \
  -I "${MODULE_DIR}" -I "${MAC_PREFIX}/include" -I "${BIN_DIR}" \
  "${PROJECT_ROOT}/Packages/RimeBridge/Sources/RimeBridge/OpenCCConversion.swift" \
  "${IOS_TOOLS_DIR}/harness-mac/opencc-tool-runner-main.swift" \
  -L "${BIN_DIR}" -lQuickContentKit "${RUN_DIR}/rime_opencc.o" \
  -Xlinker "${MAC_PREFIX}/lib/libopencc.a" -Xlinker "${MAC_PREFIX}/lib/libmarisa.a" \
  -Xlinker -lc++ -Xlinker -lc++abi -lpthread -o "${RUN_DIR}/opencc-tool-runner"
"${RUN_DIR}/opencc-tool-runner" "${CONFIG_DIR}"

say "harness dir: ${RUN_DIR}"
