#!/usr/bin/env bash
# Builds the pinned QuickJS-ng for the iOS platform of the current build (simulator or device).
# Xcode calls this from a build phase; it is also usable by hand with the same inputs.
#
# Inputs (from the Xcode environment):
#   SRCROOT, DERIVED_FILE_DIR, SDKROOT, PLATFORM_NAME, ARCHS, IPHONEOS_DEPLOYMENT_TARGET
# Outputs are kept per platform, so a device link can never force_load a simulator object:
#   ${DERIVED_FILE_DIR}/quickjs/${PLATFORM_NAME}/libquickjs.a
#   ${DERIVED_FILE_DIR}/script-generated/songyan_script_bootstrap.inc
set -euo pipefail

: "${SRCROOT:?run from Xcode or set SRCROOT}" "${DERIVED_FILE_DIR:?set DERIVED_FILE_DIR}" "${SDKROOT:?set SDKROOT}" "${PLATFORM_NAME:?set PLATFORM_NAME}"
ARCHS="${ARCHS:-arm64}"
DEPLOYMENT="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
case "${PLATFORM_NAME}" in
  iphonesimulator) TARGET_SUFFIX="-simulator" ;;
  iphoneos) TARGET_SUFFIX="" ;;
  *)
    echo "quickjs: unsupported platform ${PLATFORM_NAME}" >&2
    exit 65
    ;;
esac
OUT="${DERIVED_FILE_DIR}/quickjs/${PLATFORM_NAME}"
GENERATED="${DERIVED_FILE_DIR}/script-generated"
mkdir -p "${OUT}" "${GENERATED}"

# The pin and its archive digest are checked by fetch-quickjs.sh before anything is compiled.
export QUICKJS_CACHE="${DERIVED_FILE_DIR}/quickjs-vendor"
SOURCE="$("${SRCROOT}/Tools/Script/scripts/fetch-quickjs.sh")"

ln -sfn "${SOURCE}" "${DERIVED_FILE_DIR}/quickjs-include"
python3 "${SRCROOT}/Tools/Script/scripts/embed-text.py" \
  "${SRCROOT}/Tools/Script/src/bootstrap.js" \
  "${GENERATED}/songyan_script_bootstrap.inc" songyan_script_bootstrap

objects=()
for arch in ${ARCHS}; do
  for name in quickjs libregexp libunicode dtoa; do
    object="${OUT}/${name}-${arch}.o"
    xcrun clang -target "${arch}-apple-ios${DEPLOYMENT}${TARGET_SUFFIX}" -isysroot "${SDKROOT}" \
      -std=gnu11 -O2 -D_GNU_SOURCE -fPIC -c "${SOURCE}/${name}.c" -o "${object}"
    objects+=("${object}")
  done
done
xcrun libtool -static -o "${OUT}/libquickjs.a" "${objects[@]}" >/dev/null
printf 'quickjs: %s -> %s/libquickjs.a (%s, %s)\n' "${SOURCE}" "${OUT}" "${ARCHS}" "${PLATFORM_NAME}"
