#!/usr/bin/env bash
# Run optimized keyboard performance tests through XCTest/XCUITest.
# Usage: sim-benchmark.sh [label] (or make benchmark).
# Uses a dedicated iPhone 17 Pro simulator; SIM_NAME, SIM_RUNTIME and CI_OUTPUT_ROOT may override defaults.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/xcode.sh
source "${SCRIPT_DIR}/lib/xcode.sh"
# shellcheck source=lib/sim.sh
source "${SCRIPT_DIR}/lib/sim.sh"
require_xcode >/dev/null
export SIM_NAME="${SIM_NAME:-Songyan-Perf-Isolated}"
export SIM_RUNTIME="${SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"
export CONFIGURATION=Release PERF_MEASUREMENT=1
"${SCRIPT_DIR}/sim-stage.sh" --no-launch
UDID="$(resolve_sim_udid)"
OUT="$(new_run_dir "keyboard-performance-${1:-run}")"
# shellcheck disable=SC2016  # Xcode expands the inherited build setting.
SWIFT_FLAGS='$(inherited) -D SONGYAN_PERF'
if [[ "${CI_SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then SWIFT_FLAGS+=' -disable-sandbox'; fi
CFFIXED_USER_HOME="${CI_ROOT}/.local/xcode-build-home" \
xcodebuild test -project "${CI_ROOT}/Songyan.xcodeproj" -scheme KeyboardPerformance \
  -configuration Release -destination "platform=iOS Simulator,id=${UDID}" \
  -derivedDataPath "${CI_ROOT}/.local/dev-derived" -jobs "${XCODE_BUILD_JOBS:-4}" \
  -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile \
  -packageCachePath "${CI_ROOT}/.local/xcode-package-cache" \
  -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_DIR:-${CI_ROOT}/.local/dev-derived/SourcePackages}" \
  -enableCodeCoverage NO -parallel-testing-enabled NO -resultBundlePath "${OUT}/KeyboardPerformance.xcresult" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM='' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  "OTHER_SWIFT_FLAGS=${SWIFT_FLAGS}" > "${OUT}/xcodebuild.log" 2>&1 \
  || { tail -60 "${OUT}/xcodebuild.log" >&2; exit 1; }
xcrun xcresulttool get test-results metrics --path "${OUT}/KeyboardPerformance.xcresult" \
  > "${OUT}/metrics.json"
printf '[perf] XCTest results: %s\n[perf] metrics: %s\n' "${OUT}/KeyboardPerformance.xcresult" "${OUT}/metrics.json"
