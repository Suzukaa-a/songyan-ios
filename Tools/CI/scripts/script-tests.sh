#!/usr/bin/env bash
# Runs the shared script contract and execution cases inside an iOS simulator through XCTest.
# The case files are the originals under Tools/Script/tests; they are bundled into the test
# bundle as folder references, not copied into the repository.
#
# Env: SIM_NAME (default Songyan-ScriptTests), SIM_DEVICE_TYPE (default iPhone-17-Pro),
#      SIM_RUNTIME (default newest iOS), DEVELOPER_DIR, CONFIGURATION (default Debug).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/xcode.sh
source "${SCRIPT_DIR}/lib/xcode.sh"

SIM_NAME="${SIM_NAME:-Songyan-ScriptTests}"
CONFIGURATION="${CONFIGURATION:-Debug}"
case "${CONFIGURATION}" in Debug|Release) ;; *) echo "CONFIGURATION must be Debug|Release" >&2; exit 64 ;; esac
DERIVED="${CI_OUTPUT_ROOT}/script-tests"
LOG="${DERIVED}/xcodebuild.log"
mkdir -p "${DERIVED}"

require_xcode >/dev/null
SIMCTL=(xcrun simctl)

UDID="$("${SIMCTL[@]}" list devices available | awk -v n="${SIM_NAME}" '$0 ~ "^ +"n" \\(" {match($0,/[0-9A-F-]{36}/); print substr($0,RSTART,RLENGTH); exit}')"
if [[ -z "${UDID}" ]]; then
  # Some iOS runtimes in a fresh Xcode cannot pair with the preferred device type, so try the
  # requested runtime first and then every available one, newest first.
  RUNTIME_CANDIDATES=()
  [[ -z "${SIM_RUNTIME:-}" ]] || RUNTIME_CANDIDATES+=("${SIM_RUNTIME}")
  while IFS= read -r runtime; do RUNTIME_CANDIDATES+=("${runtime}"); done < <(
    "${SIMCTL[@]}" list runtimes available | awk '/^iOS / {print $NF}' | sort -r)
  UDID=""
  for runtime in ${RUNTIME_CANDIDATES[@]+"${RUNTIME_CANDIDATES[@]}"}; do
    if UDID="$("${SIMCTL[@]}" create "${SIM_NAME}" \
      "com.apple.CoreSimulator.SimDeviceType.${SIM_DEVICE_TYPE:-iPhone-17-Pro}" "${runtime}" 2>/dev/null)"; then
      echo "[script-tests] created simulator ${SIM_NAME} (${runtime})"
      break
    fi
    UDID=""
  done
  [[ -n "${UDID}" ]] || {
    echo "[script-tests] cannot create a simulator for ${SIM_DEVICE_TYPE:-iPhone-17-Pro}" >&2
    exit 1
  }
fi
state="$("${SIMCTL[@]}" list devices | grep "${UDID}" | sed -E 's/.*\(([A-Za-z]+)\)[[:space:]]*$/\1/')"
[[ "${state}" == Booted ]] || "${SIMCTL[@]}" boot "${UDID}"
"${SIMCTL[@]}" bootstatus "${UDID}" -b >/dev/null

echo "[script-tests] simulator ${SIM_NAME} ${UDID}"
"${DEVELOPER_DIR}/usr/bin/xcodebuild" \
  -project "${CI_ROOT}/Songyan.xcodeproj" -scheme ScriptContract -configuration "${CONFIGURATION}" \
  -destination "platform=iOS Simulator,id=${UDID}" \
  -derivedDataPath "${DERIVED}" \
  -packageCachePath "${CI_ROOT}/.local/xcode-package-cache" \
  -clonedSourcePackagesDirPath "${DERIVED}/SourcePackages" \
  -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM='' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  test >"${LOG}" 2>&1 || {
    tail -40 "${LOG}" >&2
    echo "[script-tests] failed; full log: ${LOG}" >&2
    exit 1
  }
grep -E "Test Case .* (passed|failed)|Executed [0-9]+ test|contract cases:|execution cases:" "${LOG}" | tail -8
echo "[script-tests] log: ${LOG}"
