#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# traditional-catalog-harness.sh — real macOS acceptance for the four
# traditional-Chinese catalogue entries (rime-bopomofo, rime-cangjie,
# rime-quick, rime-cantonese).
#
# Per entry, one process: the real PackageManager reads the pinned upstream
# archives through prepareRecommended (strict SHA-256, every declared archive
# required), installSchemeImport runs the real store transaction, and its
# deploy callback starts the real RimeBridge/librime engine on the staging
# directories so librime itself compiles dictionaries, prisms, tables and
# schemas into user/build. After the commit a fresh prebuilt engine types a code
# read off the installed dictionary row and the installed spelling algebra; the
# candidate list must be non-empty. Licences/notices from every archive must be
# installed byte-identically, and default.yaml must publish exactly the
# catalogue entry's advertised schema list (bopomofo advertises bopomofo_tw and
# bopomofo), with its main schema first.
#
# The engine-level contract lives in harness-mac/traditional-catalog-main.swift;
# this wrapper builds it against the pinned macOS engine, runs the four entries
# serially (one engine per process) and reports librime deploy log lines.
#
# Opt-in: doing nothing unless TRADITIONAL_CATALOG_NATIVE=1 is deliberate; the
# real deploy writes compiled data and takes minutes, so it is never part of an
# ordinary gate. The XCTest TraditionalCatalogNativeInstallTests skips unless
# the same variable is set.
#
# Usage:
#   TRADITIONAL_CATALOG_NATIVE=1 \
#   TRADITIONAL_CATALOG_SOURCES=<dir with pinned zips> \
#     Tools/BuildRimeIOS/scripts/traditional-catalog-harness.sh
#
# Environment:
#   TRADITIONAL_CATALOG_NATIVE            1 enables the run; anything else skips
#   TRADITIONAL_CATALOG_SOURCES           directory holding <repository>-<revision>.zip
#                                         (default <repo>/.local/test-schemes, else the
#                                         sibling songyan-android checkout's copy)
#   TRADITIONAL_CATALOG_OPENCC            shared OpenCC data (default
#                                         <repo>/Resources/EngineResources/opencc)
#   TRADITIONAL_CATALOG_ITEMS             comma-separated catalogue ids (default all four)
#   NATIVE_ENGINE_ROOT                    pinned macOS engine root (read-only)
#   HARNESS_OUTPUT_ROOT                   where the run directory is created
#
# The pinned archives are never downloaded here. Fetch the exact same files with
# songyan-android's scripts/fetch-test-schemes.sh, which writes
# <repository>-<revision>.zip into .local/test-schemes; this script defaults to
# that directory (or the sibling songyan-android checkout's copy).
#
# Exit: 0 all entries installed/deployed/typed with candidates; 1 any contract
# or deploy-log failure; 64 usage; 2 missing inputs.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

if [[ "${TRADITIONAL_CATALOG_NATIVE:-0}" != "1" ]]; then
  say "SKIP: opt-in macOS native catalogue acceptance is off; set TRADITIONAL_CATALOG_NATIVE=1 to run the four entries"
  exit 0
fi

DEFAULT_ARCHIVES="${PROJECT_ROOT}/.local/test-schemes"
if [[ ! -d "${DEFAULT_ARCHIVES}" && -d "${PROJECT_ROOT}/../songyan-android/.local/test-schemes" ]]; then
  DEFAULT_ARCHIVES="${PROJECT_ROOT}/../songyan-android/.local/test-schemes"
fi
ARCHIVES="${TRADITIONAL_CATALOG_SOURCES:-${DEFAULT_ARCHIVES}}"
OPENCC="${TRADITIONAL_CATALOG_OPENCC:-${PROJECT_ROOT}/Resources/EngineResources/opencc}"
ITEMS="${TRADITIONAL_CATALOG_ITEMS:-rime-bopomofo,rime-cangjie,rime-quick,rime-cantonese}"

[[ -d "${ARCHIVES}" ]] || die "pinned archive directory not found: ${ARCHIVES}"
[[ -f "${OPENCC}/t2s.json" && -f "${OPENCC}/s2twp.json" ]] || die "shared OpenCC data incomplete: ${OPENCC}"
[[ -f "${MAC_PREFIX}/lib/librime.a" ]] || die \
  "missing ${MAC_PREFIX}/lib/librime.a; set NATIVE_ENGINE_ROOT to the pinned macOS engine root"
[[ -d "${MAC_PREFIX}/include" ]] || die "missing ${MAC_PREFIX}/include (pinned dependency headers)"
command -v swift >/dev/null 2>&1 || die "swift not found; select a full Xcode with DEVELOPER_DIR"
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcodebuild -version >/dev/null 2>&1; then
  die "no full Xcode selected; export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
fi
say "developer dir: $(xcode-select -p 2>/dev/null || true)"

# MARK: - Real PackageManager module (SwiftPM build owned by this harness)

if [[ -n "${TRADITIONAL_CATALOG_PM_BIN:-}" ]]; then
  # Under swift test this package is already built and its build lock is held by
  # the test process, so a nested swift build would wait on that lock forever;
  # reuse the products the test process built.
  say "reuse PackageManager products: ${TRADITIONAL_CATALOG_PM_BIN}"
  PM_BIN="${TRADITIONAL_CATALOG_PM_BIN}"
else
  say "build PackageManager module"
  swift build --package-path "${PROJECT_ROOT}/Packages/PackageManager" --force-resolved-versions >/dev/null
  PM_BIN="$(swift build --package-path "${PROJECT_ROOT}/Packages/PackageManager" --show-bin-path 2>/dev/null | tail -1)"
fi
for object in PackageManager.o KeyboardCore.o Yams.o CYaml.o ZIPFoundation.o; do
  [[ -f "${PM_BIN}/${object}" ]] || die "missing ${PM_BIN}/${object}"
done
PM_CHECKOUTS="${PROJECT_ROOT}/Packages/PackageManager/.build/checkouts"

GEN_INCLUDE="$(rime_generated_include)"
RUN_DIR="$(new_harness_dir traditional-catalog)"
say "run dir: ${RUN_DIR}"

# MARK: - Native bridge + shims

prepare_native_bridge
# The component registry check (rb_component_available) only exists in the
# grammar-enabled bridge; these four schemes need no grammar module, so the
# octagram registration stays a no-op.
compile_bridge_c -DRB_WITH_GRAMMAR=1
cat >"${RUN_DIR}/rb_grammar_noop.cc" <<'EOF'
void rime_require_module_octagram();
extern "C" void rb_require_grammar(void) {}
EOF
"${MAC_CXX}" -std=c++17 -O2 -c -isysroot "${MACOS_SDK}" -mmacosx-version-min=13.0 \
  "${RUN_DIR}/rb_grammar_noop.cc" -o "${RUN_DIR}/rb_grammar_noop.o"
compile_bridge_cpp rime_spelling
compile_bridge_cpp rime_display_map
compile_bridge_cpp rime_grammar_diagnostics
compile_bridge_cpp rime_opencc

say "compile learning C adapter"
python3 "${PROJECT_ROOT}/Tools/BuildRimeIOS/scripts/build-learning-support.py" \
  --sdk "${MACOS_SDK}" --target arm64-apple-macos13.0 \
  --kit-include-dir "${MAC_PREFIX}/include" \
  --output-dir "${RUN_DIR}/learning-support"

# RimeBridge is compiled flat so it links the macOS shim instead of the iOS
# XCFramework; only the module imports are dropped.
mkdir -p "${RUN_DIR}/flat"
for source in "${PROJECT_ROOT}"/Packages/RimeBridge/Sources/RimeBridge/*.swift; do
  base="$(basename "${source}")"
  sed -e 's/^import KeyboardCore$//' -e 's/^import RimeBridge$//' "${source}" >"${RUN_DIR}/flat/${base}"
done

# Bundle.module in PackageManager resolves the resource bundle next to the
# executable for command-line tools; keep the package bundles there.
find "${PM_BIN}" -maxdepth 1 -name '*.bundle' -exec cp -R {} "${RUN_DIR}/" \;

say "compile traditional-catalogue harness (-O2) against ${MAC_PREFIX}"
swiftc -O -parse-as-library \
  -Xcc -fmodule-map-file="${RUN_DIR}/RimeKitModule/module.modulemap" \
  -Xcc -fmodule-map-file="${PM_CHECKOUTS}/Yams/Sources/CYaml/include/module.modulemap" \
  -Xcc -fmodule-map-file="${PM_CHECKOUTS}/ZIPFoundation/Sources/CZLib/module.modulemap" \
  -Xcc -fmodule-map-file="${RUN_DIR}/learning-support/module/module.modulemap" \
  -I "${RUN_DIR}/RimeKitModule" -I "${MAC_PREFIX}/include" -I "${PM_BIN}" \
  -I "${RUN_DIR}/learning-support/module" \
  "${IOS_TOOLS_DIR}/harness-mac/traditional-catalog-main.swift" \
  "${RUN_DIR}/flat"/*.swift \
  "${PM_BIN}/PackageManager.o" "${PM_BIN}/KeyboardCore.o" "${PM_BIN}/Yams.o" \
  "${PM_BIN}/CYaml.o" "${PM_BIN}/ZIPFoundation.o" \
  "${RUN_DIR}/rime_bridge.o" "${RUN_DIR}/rime_spelling.o" "${RUN_DIR}/rime_display_map.o" \
  "${RUN_DIR}/rime_grammar_diagnostics.o" "${RUN_DIR}/rime_opencc.o" \
  "${RUN_DIR}/rb_grammar_noop.o" \
  "${RUN_DIR}/learning-support/RimeLeversSupport.o" \
  "${MAC_LINK_FLAGS[@]}" \
  -target arm64-apple-macos13.0 -o "${RUN_DIR}/harness"

# MARK: - Entries, serially, one engine per process

FAILED=0
SUMMARY="${RUN_DIR}/summary.tsv"
: >"${SUMMARY}"
IFS=',' read -r -a ITEM_ARRAY <<<"${ITEMS}"
for item in "${ITEM_ARRAY[@]}"; do
  [[ -n "${item}" ]] || continue
  say "entry: ${item}"
  STORE="${RUN_DIR}/store-${item}"
  LOG="${RUN_DIR}/${item}.log"
  ERRFILE="${RUN_DIR}/${item}.stderr.log"
  REPORT="${RUN_DIR}/${item}.json"
  set +e
  "${RUN_DIR}/harness" --item "${item}" --archives "${ARCHIVES}" --opencc "${OPENCC}" \
    --root "${STORE}" --report "${REPORT}" 2>"${ERRFILE}" | tee "${LOG}"
  STATUS=$?
  set -e

  # librime logs deploy warnings/errors to stderr; never ignore them. Errors and
  # explicit missing-dependency lines fail the run. A resolver's "nonexistent config
  # file" line is only acceptable when this deploy produced that path afterwards (a
  # compiled artifact under user/build, or an installed source file) or when it names
  # librime's own lazily created per-user state. Anything else is a real missing
  # reference and fails the entry.
  grep -E '^[EW][0-9]' "${ERRFILE}" >"${RUN_DIR}/${item}.deploy.log" 2>/dev/null || true
  ENGINE_ERRORS=0
  MISSING_LOGS=0
  RESOLVER_WARNINGS=0
  COLD_WARNINGS=0
  OPTIONAL_WARNINGS=0
  UNRESOLVED_WARNINGS=0
  if [[ -s "${RUN_DIR}/${item}.deploy.log" ]]; then
    ENGINE_ERRORS="$(grep -c '^E[0-9]' "${RUN_DIR}/${item}.deploy.log" || true)"
    MISSING_LOGS="$(grep -Eic 'missing input schema|skipped unsatisfied dependency|cannot find|not found|no such file' \
      "${RUN_DIR}/${item}.deploy.log" || true)"
    RESOLVER_WARNINGS="$(grep -c 'nonexistent config file' "${RUN_DIR}/${item}.deploy.log" || true)"
    grep -E '^E[0-9]' "${RUN_DIR}/${item}.deploy.log" >&2 || true
    if [[ "${RESOLVER_WARNINGS}" != "0" ]]; then
      set +e
      MISSING_WARNINGS="$(python3 - "${REPORT}" "${RUN_DIR}/${item}.deploy.log" "${RUN_DIR}/${item}.warnings.json" <<'PY'
import json
import os
import re
import sys

report_path, log_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
roots = []
try:
    with open(report_path, encoding="utf-8") as handle:
        report = json.load(handle)
    roots = [report.get(key) or "" for key in ("resourceRoot", "userDataRoot", "buildRoot")]
except (OSError, ValueError):
    roots = []
user_root = roots[1] if len(roots) > 1 else ""

# Cold-start probes: librime asks for its own per-user state and the optional grammar
# configuration before creating them. Their absence at deploy time is normal.
optional_user_config = {"user.yaml", "installation.yaml", "grammar.yaml"}


def produced(path):
    candidates = [path]
    if not path.startswith("build/") and not os.path.isabs(path):
        candidates.append("build/" + path)
    for candidate in candidates:
        if os.path.exists(candidate):
            return True
    if os.path.isabs(path):
        return False
    for root in roots:
        if not root:
            continue
        for candidate in candidates:
            if os.path.exists(os.path.join(root, candidate)):
                return True
        if os.path.exists(os.path.join(root, "build", os.path.basename(path))):
            return True
    return False


def optional_user_config_path(path):
    if not os.path.isabs(path) or not user_root:
        return False
    return os.path.dirname(os.path.normpath(path)) == os.path.normpath(
        user_root
    ) and os.path.basename(path) in optional_user_config


report = {"coldGenerated": [], "optionalUserConfig": [], "requiredMissing": []}
with open(log_path, encoding="utf-8", errors="replace") as handle:
    for line in handle:
        if "nonexistent config file" not in line:
            continue
        match = re.search(r"nonexistent config file '([^']+)'", line)
        path = (
            match.group(1)
            if match
            else line.split("nonexistent config file", 1)[1].strip().strip("'\"")
        )
        if not path:
            continue
        if produced(path):
            report["coldGenerated"].append(path)
        elif optional_user_config_path(path):
            report["optionalUserConfig"].append(path)
        else:
            report["requiredMissing"].append(path)
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(report, handle, indent=2, sort_keys=True)
for path in report["requiredMissing"]:
    print(path)
sys.exit(1 if report["requiredMissing"] else 0)
PY
)"
      CHECK_STATUS=$?
      set -e
      if [[ -f "${RUN_DIR}/${item}.warnings.json" ]]; then
        read -r COLD_WARNINGS OPTIONAL_WARNINGS <<<"$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(len(d["coldGenerated"]),len(d["optionalUserConfig"]))' "${RUN_DIR}/${item}.warnings.json")"
      fi
      if [[ "${CHECK_STATUS}" != "0" ]]; then
        UNRESOLVED_WARNINGS="$(printf '%s\n' "${MISSING_WARNINGS}" | grep -c . || true)"
        say "  deploy resolver warnings for required files this deploy never produced:"
        printf '%s\n' "${MISSING_WARNINGS}" | sed 's/^/    /' >&2
      fi
      say "  deploy resolver warnings: ${RESOLVER_WARNINGS} (cold probes ${COLD_WARNINGS}, optional user config ${OPTIONAL_WARNINGS}, required missing ${UNRESOLVED_WARNINGS}; see ${RUN_DIR}/${item}.warnings.json and ${RUN_DIR}/${item}.deploy.log)"
    fi
  fi
  if [[ "${STATUS}" != "0" || "${ENGINE_ERRORS}" != "0" || "${MISSING_LOGS}" != "0" \
    || "${UNRESOLVED_WARNINGS}" != "0" ]]; then
    FAILED=1
    printf '%s\tfail\tengineErrors=%s\tmissingDependencyLogs=%s\tresolverWarnings=%s\tcoldProbes=%s\toptionalUserConfigs=%s\trequiredMissing=%s\n' \
      "${item}" "${ENGINE_ERRORS}" "${MISSING_LOGS}" "${RESOLVER_WARNINGS}" "${COLD_WARNINGS}" "${OPTIONAL_WARNINGS}" "${UNRESOLVED_WARNINGS}" >>"${SUMMARY}"
  else
    printf '%s\tpass\tengineErrors=0\tmissingDependencyLogs=0\tresolverWarnings=%s\tcoldProbes=%s\toptionalUserConfigs=%s\trequiredMissing=0\n' \
      "${item}" "${RESOLVER_WARNINGS}" "${COLD_WARNINGS}" "${OPTIONAL_WARNINGS}" >>"${SUMMARY}"
  fi
done

say "summary"
cat "${SUMMARY}" >&2
if [[ "${FAILED}" != "0" ]]; then
  die "traditional catalogue native acceptance failed; run dir: ${RUN_DIR}"
fi
say "all ${#ITEM_ARRAY[@]} entries installed, deployed natively and typed with candidates"
say "harness dir: ${RUN_DIR}"