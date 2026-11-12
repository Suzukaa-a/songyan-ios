#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: Tools/CI/ci.sh <fast|packages|probes|extended|release|lint|format>

  fast      Clean-checkout tests without RimeKit or a simulator runtime
            (packages + probes).
  packages  Project-structure checks and the Swift package tests.
  probes    Production-source probes in Tests/IOS, run in parallel.
  extended  fast + serialized native harnesses + unsigned Debug app builds.
  release   extended + installed RimeKit check + unsigned Release builds.
  lint      swift-format (strict), shellcheck and ruff on tracked sources.
  format    Rewrite tracked Swift sources with swift-format; apply ruff fixes.

Build output:
  CI_OUTPUT_ROOT Root for logs, DerivedData and products of every mode
                 (default: .local/ci). Release products land in
                 $CI_OUTPUT_ROOT/app-builds/Release-<simulator|device>.

Environment for extended/release:
  DEVELOPER_DIR  Full Xcode developer directory (required if xcode-select is CLT).
  XCODE_DEV_DIR  Same Xcode directory for Tools/BuildRimeIOS native harnesses.
  Native harnesses require the pinned macOS librime sources, static prefix and
  generated build_config.h from Tools/BuildRime. NATIVE_ENGINE_ROOT may select
  an existing read-only engine root; LIBRIME_BUILD_CONFIG may select its header.
  These ignored inputs are not needed for fast, grammar-window or app builds.
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 64; }

packages() {
  python3 -m unittest discover -s "${ROOT}/Tests/ProjectStructure" -p 'test_*.py' -v
  source "${SCRIPT_DIR}/scripts/lib/xcode.sh"
  require_xcode
  "${SCRIPT_DIR}/scripts/test-swift-packages.sh"
}

# Offline production-source probes; no RimeKit prefix or Simulator runtime
# needed. Each module is an independent swiftc compile (they share one locked
# build of the production modules), so modules run side by side; a module's
# output is printed whole when it fails. Exit status 5 is unittest's "no tests
# ran": the simulator probes that are only run by hand.
probes() {
  # The full Xcode may be needed to compile SwiftUI macros.
  source "${SCRIPT_DIR}/scripts/lib/xcode.sh"
  require_xcode
  local logs
  logs="$(mktemp -d)"
  # shellcheck disable=SC2016 # the inner script reads its arguments as $2 and $3
  find "${ROOT}/Tests/IOS" -maxdepth 1 -name 'test_*.py' -exec basename {} .py \; | sort |
    xargs -P "${PROBE_JOBS:-$(sysctl -n hw.ncpu)}" -I{} sh -c '
      cd "$1" || exit 1
      python3 -m unittest -v "$2" >"$3/$2.log" 2>&1
      case $? in
        0) printf "ok   %s\n" "$2" ;;
        5) printf "skip %s (no test cases: run by hand)\n" "$2" ;;
        *) printf "FAIL %s\n" "$2"; cat "$3/$2.log"; exit 1 ;;
      esac' _ "${ROOT}/Tests/IOS" {} "${logs}"
}

fast() {
  packages
  probes
}

extended() {
  fast
  # Compile and exercise the production quick-symbol model and the shared
  # cross-process store. These probes need Xcode/Combine, not a Simulator.
  python3 -m unittest discover -s "${ROOT}/Tests/IOS" -p 'extended_*.py' -v
  "${SCRIPT_DIR}/scripts/run-native-harnesses.sh"
  "${SCRIPT_DIR}/scripts/build-app.sh" Debug simulator
  "${SCRIPT_DIR}/scripts/build-app.sh" Debug device
  check_device_app Debug
  # The shared script cases run in a simulator through XCTest; fast stays offline.
  "${SCRIPT_DIR}/scripts/script-tests.sh"
}

# The unsigned device product is what ships; a simulator slice or a missing script engine would
# only fail on a device, so check the bundle itself after each device build.
check_device_app() {
  local configuration="$1"
  "${SCRIPT_DIR}/scripts/check-device-app.sh" \
    "${CI_OUTPUT_ROOT:-${ROOT}/.local/ci}/app-builds/${configuration}-device/DerivedData/Build/Products/${configuration}-iphoneos/HostApp.app"
}

# Tracked sources only, so package build directories and vendored engine
# artifacts are never linted.
tracked() {
  git -C "${ROOT}" ls-files -z -- "$@" ':!:Packages/*/Vendored/**'
}

# FuzzyPinyinState.swift is a template with production code spliced in by its
# test, so it does not parse on its own.
swift_sources() {
  tracked 'Apps/*.swift' 'Packages/*.swift' 'Tools/*.swift' 'Tests/*.swift' \
    ':!:Tests/IOS/Fixtures/FuzzyPinyinState.swift'
}

# Prefer an installed ruff; otherwise run it through uv or pipx.
run_ruff() {
  if command -v ruff >/dev/null 2>&1; then
    ruff "$@"
  elif command -v uvx >/dev/null 2>&1; then
    uvx ruff "$@"
  elif command -v pipx >/dev/null 2>&1; then
    pipx run ruff "$@"
  else
    missing_tool ruff
  fi
}

# A missing optional linter is skipped locally but fails on CI.
missing_tool() {
  printf 'warning: %s is not installed; skipping it.\n' "$1" >&2
  [[ -z "${CI:-}" ]]
}

lint() {
  cd "${ROOT}"
  swift_sources | xargs -0 xcrun swift-format lint --strict --configuration .swift-format
  if command -v shellcheck >/dev/null 2>&1; then
    tracked '*.sh' | xargs -0 shellcheck
  else
    missing_tool shellcheck
  fi
  run_ruff check .
}

format() {
  cd "${ROOT}"
  swift_sources | xargs -0 xcrun swift-format format --in-place --configuration .swift-format
  run_ruff check --fix .
}

case "$1" in
  lint)
    lint
    ;;
  format)
    format
    ;;
  fast)
    fast
    ;;
  packages)
    packages
    ;;
  probes)
    probes
    ;;
  extended)
    extended
    ;;
  release)
    extended
    python3 "${ROOT}/Tools/BuildRimeIOS/scripts/export-rimekit.py" --check
    "${SCRIPT_DIR}/scripts/build-app.sh" Release simulator
    "${SCRIPT_DIR}/scripts/build-app.sh" Release device
    check_device_app Release
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac
