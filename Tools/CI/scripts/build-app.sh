#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/xcode.sh
source "${SCRIPT_DIR}/lib/xcode.sh"

[[ $# -eq 2 || ( $# -eq 3 && "$3" == --locked ) ]] \
  || { echo "usage: build-app.sh <Debug|Release> <simulator|device>" >&2; exit 64; }
if [[ $# -eq 2 ]]; then
  exec python3 "${SCRIPT_DIR}/lib/native-lock.py" "${CI_OUTPUT_ROOT}/locks/xcode-build.lock" -- \
    bash "${BASH_SOURCE[0]}" "$@" --locked
fi
CONFIGURATION="$1"
PLATFORM="$2"
[[ "${CONFIGURATION}" == Debug || "${CONFIGURATION}" == Release ]] \
  || { echo "invalid configuration: ${CONFIGURATION}" >&2; exit 64; }

case "${PLATFORM}" in
  simulator)
    SDK=iphonesimulator
    DESTINATION='generic/platform=iOS Simulator'
    EXTRA=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)
    ;;
  device)
    SDK=iphoneos
    DESTINATION='generic/platform=iOS'
    EXTRA=(ARCHS=arm64)
    ;;
  *)
    echo "invalid platform: ${PLATFORM}" >&2
    exit 64
    ;;
esac

require_xcode
RUN_DIR="$(new_run_dir "app-${CONFIGURATION}-${PLATFORM}")"
# These unsigned caches are separate from sim-stage's signed dev-derived output.
# Each CI platform/configuration also has its own manifest preferences, so a
# simultaneous sim-stage cannot change the sandbox setting for this build.
BUILD_ROOT="${CI_OUTPUT_ROOT}/app-builds/${CONFIGURATION}-${PLATFORM}"
BUILD_HOME="${BUILD_ROOT}/home"
SWIFT_SANDBOX_OPTIONS=()
mkdir -p "${BUILD_HOME}/Library/Preferences"
if [[ "${CI_SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then
  defaults write "${BUILD_HOME}/Library/Preferences/.GlobalPreferences" IDEPackageSupportDisableManifestSandbox -bool YES
  # shellcheck disable=SC2016  # $(inherited) is an Xcode build setting, not a shell expansion
  SWIFT_SANDBOX_OPTIONS=('OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox')
else
  defaults write "${BUILD_HOME}/Library/Preferences/.GlobalPreferences" IDEPackageSupportDisableManifestSandbox -bool NO
fi
# A probe build is one S0_PROBE_ARCHIVE: it links the probe engine and compiles the probe switch
# into both targets. Only a Debug build takes it; Release leaves the settings empty.
S0_SETTINGS=()
if [[ "${CONFIGURATION}" == Debug && -n "${S0_PROBE_ARCHIVE:-}" ]]; then
  S0_SETTINGS=(
    "S0_QUICKJS_LDFLAGS=-Wl,-force_load,${S0_PROBE_ARCHIVE}"
    "S0_PROBE_CONDITIONS=SONGYAN_S0_PROBE"
    # The operator gives the LAN URL when building; nothing on a device can write the App Group
    # defaults the extension reads, so the host app embeds these and seeds them on launch.
    "SONGYAN_S0_PROBE_HTTP_URL=${S0_PROBE_HTTP_URL:-}"
    "SONGYAN_S0_PROBE_HTTPS_URL=${S0_PROBE_HTTPS_URL:-}"
  )
  # A device Debug IPA is re-signed by an installer that only knows about frameworks, so keep the
  # code in the target binaries instead of a *.debug.dylib it would leave unsigned.
  if [[ "${PLATFORM}" == device ]]; then
    S0_SETTINGS+=("ENABLE_DEBUG_DYLIB=NO")
  fi
fi
# A release build stamps the tag's version; everyday builds keep the project's own.
VERSION_SETTINGS=()
[[ -z "${APP_VERSION:-}" ]] || VERSION_SETTINGS+=("MARKETING_VERSION=${APP_VERSION}")
[[ -z "${APP_BUILD:-}" ]] || VERSION_SETTINGS+=("CURRENT_PROJECT_VERSION=${APP_BUILD}")
CFFIXED_USER_HOME="${BUILD_HOME}" \
"${DEVELOPER_DIR}/usr/bin/xcodebuild" \
  -project "${CI_ROOT}/Songyan.xcodeproj" \
  -scheme HostApp -configuration "${CONFIGURATION}" \
  -sdk "${SDK}" -destination "${DESTINATION}" \
  -derivedDataPath "${BUILD_ROOT}/DerivedData" \
  -packageCachePath "${CI_ROOT}/.local/xcode-package-cache" \
  -clonedSourcePackagesDirPath "${SOURCE_PACKAGES_DIR:-${CI_OUTPUT_ROOT}/xcode-source-packages}" \
  -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile \
  -jobs "${XCODE_BUILD_JOBS:-4}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  ${SWIFT_SANDBOX_OPTIONS[@]+"${SWIFT_SANDBOX_OPTIONS[@]}"} \
  ${S0_SETTINGS[@]+"${S0_SETTINGS[@]}"} \
  ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} \
  "${EXTRA[@]}" build | tee "${RUN_DIR}/xcodebuild.log"

printf '\n[CI] App build output: %s\n' "${RUN_DIR}"
