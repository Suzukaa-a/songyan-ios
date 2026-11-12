#!/usr/bin/env bash
# A device build once linked the simulator QuickJS archive, which only Xcode notices at runtime
# (the app installs and then the extension cannot create a runtime). Check the unsigned device
# product itself: arm64 slices, the script engine in the binaries, the script resources and the
# privacy/legal files must all be there.
#
# Usage: Tools/CI/scripts/check-device-app.sh <HostApp.app>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

app=${1:?usage: check-device-app.sh <HostApp.app>}
[[ -d "$app" ]] || {
  echo "missing device app: $app" >&2
  exit 1
}

fail() {
  echo "device app check: $*" >&2
  exit 1
}

expect_arm64() {
  local binary=$1
  local archs
  archs=$(lipo -archs "$binary" 2>/dev/null) || fail "not a Mach-O binary: $binary"
  [[ "$archs" == "arm64" ]] || fail "$binary has architectures '$archs', expected only arm64"
}

# arm64 alone does not tell a device slice from an arm64 simulator slice; the load command does.
expect_device_platform() {
  local binary=$1 platform
  platform=$(xcrun vtool -show-build "$binary" 2>/dev/null | awk '/^ *platform /{print $2; exit}')
  [[ "$platform" == "IOS" ]] || fail "$binary is built for '${platform:-unknown}', expected IOS"
}

# Debug device builds keep the code in a *.debug.dylib; Release puts it in the binary.
expect_quickjs() {
  local binary=$1 found=0 candidate
  for candidate in "$binary" "${binary}.debug.dylib"; do
    [[ -f "$candidate" ]] || continue
    # Read the whole symbol table: grep -q would close the pipe early, and pipefail turns
    # the resulting SIGPIPE on nm into a false negative for a 60 MB dylib.
    if nm -a "$candidate" 2>/dev/null | grep 'JS_NewRuntime' >/dev/null; then
      found=1
      break
    fi
  done
  [[ $found -eq 1 ]] || fail "no QuickJS symbols in $binary (or its debug dylib)"
}

host_binary="${app}/HostApp"
extension="${app}/PlugIns/KeyboardExtension.appex"
extension_binary="${extension}/KeyboardExtension"
[[ -f "$host_binary" ]] || fail "missing $host_binary"
[[ -d "$extension" ]] || fail "missing $extension"
[[ -f "$extension_binary" ]] || fail "missing $extension_binary"

# A simulator slice in a device build links fine and only fails on the device.
expect_arm64 "$host_binary"
expect_arm64 "$extension_binary"
expect_quickjs "$host_binary"
expect_quickjs "$extension_binary"
expect_device_platform "$host_binary"
expect_device_platform "$extension_binary"
for dylib in "${host_binary}.debug.dylib" "${extension_binary}.debug.dylib"; do
  if [[ -f "$dylib" ]]; then
    expect_device_platform "$dylib"
  fi
done

[[ -f "${extension}/examples/minimal.js" ]] || fail "the extension bundle has no examples/minimal.js"
[[ -f "${app}/ai-guide.txt" ]] || fail "the host app has no ai-guide.txt"
[[ -f "${app}/PrivacyInfo.xcprivacy" ]] || fail "the host app has no PrivacyInfo.xcprivacy"
[[ -f "${extension}/PrivacyInfo.xcprivacy" ]] || fail "the extension has no PrivacyInfo.xcprivacy"

plist="${extension}/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$plist" 2>/dev/null |
  grep 'com.apple.keyboard-service' >/dev/null || fail "the extension point is not the keyboard service"

[[ -f "${app}/Legal/licenses/quickjs-ng-0.18.0-LICENSE.txt" ]] || fail "missing the QuickJS license"
grep -qi 'quickjs' "${app}/Legal/ThirdPartyNotices-iOS.txt" || fail "the iOS notices do not mention QuickJS"

echo "device app check passed: $app"
