#!/usr/bin/env bash
# Package a device build from build-app.sh into an ad-hoc signed IPA (Release by default).
# Ad-hoc signing carries the entitlements, so AltStore or Sideloadly can re-sign
# it under the installer's own team and keep the shared App Group. A Debug build is accepted
# for the S0 device probe, whose engine archive is already linked into that build.
#
# TEAMID is optional (ten uppercase letters/digits when given). The public release IPA is signed for
# no team: the installer re-signs it under theirs, so the team-prefixed keychain-access-groups entry
# ($(AppIdentifierPrefix)group.app.songyan.shared) is left out, and the App Group stays. codesign does
# not expand build settings, so any other unexpanded one still fails instead of shipping a literal.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CONFIGURATION=Release
if [[ $# -eq 3 && "$1" == --configuration ]]; then
  CONFIGURATION="$2"
  shift 2
fi
[[ $# -eq 1 ]] || { echo "usage: package-ipa.sh [--configuration Debug|Release] <output.ipa>" >&2; exit 64; }
[[ "${CONFIGURATION}" == Debug || "${CONFIGURATION}" == Release ]] \
  || { echo "invalid configuration: ${CONFIGURATION}" >&2; exit 64; }
OUTPUT="$1"
[[ ! -e "${OUTPUT}" ]] || { echo "refusing to overwrite ${OUTPUT}" >&2; exit 1; }

PRODUCT="${CI_OUTPUT_ROOT}/app-builds/${CONFIGURATION}-device/DerivedData/Build/Products/${CONFIGURATION}-iphoneos/HostApp.app"
[[ -x "${PRODUCT}/HostApp" && -x "${PRODUCT}/PlugIns/KeyboardExtension.appex/KeyboardExtension" ]] \
  || { echo "no ${CONFIGURATION} device build; run build-app.sh ${CONFIGURATION} device first" >&2; exit 1; }
# A local override would ship someone else's identity.
[[ ! -e "${CI_ROOT}/Config/Local.xcconfig" ]] \
  || { echo "Config/Local.xcconfig overrides the shipped identity" >&2; exit 1; }

STAGE="$(new_run_dir package-ipa)"
mkdir -p "${STAGE}/Payload"
ditto "${PRODUCT}" "${STAGE}/Payload/HostApp.app"
APP="${STAGE}/Payload/HostApp.app"

# codesign does not expand build settings. Expand them before signing; an unexpanded setting is
# refused instead of shipping a literal.
python3 "${SCRIPT_DIR}/expand-device-entitlements.py" \
  --root "${CI_ROOT}" --output-dir "${STAGE}"

# Inside out: nested frameworks and dylibs (a Debug build keeps its code in *.debug.dylib),
# then the extension, then the app.
while IFS= read -r nested; do
  codesign --force --sign - --timestamp=none "${nested}"
done < <(find "${APP}" -type d -name '*.framework' -prune | sort
         find "${APP}" -type f -name '*.dylib' -not -path '*.framework/*' | sort)
codesign --force --sign - --timestamp=none \
  --entitlements "${STAGE}/KeyboardExtension.entitlements" "${APP}/PlugIns/KeyboardExtension.appex"
codesign --force --sign - --timestamp=none --entitlements "${STAGE}/HostApp.entitlements" "${APP}"
codesign --verify --deep --strict "${APP}"

mkdir -p "$(dirname "${OUTPUT}")"
ditto -c -k --sequesterRsrc --keepParent "${STAGE}/Payload" "${OUTPUT}"
printf '[CI] IPA: %s\n' "${OUTPUT}"
