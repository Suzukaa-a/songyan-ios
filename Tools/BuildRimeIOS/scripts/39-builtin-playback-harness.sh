#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 39-builtin-playback-harness.sh — macOS real-engine replay of the built-in
# playback fixtures (including the four script-state cases), plus the real
# engine projection capture used to regenerate the committed projection
# fixtures.
#
# The JSON fixture is the single source of truth: playback-cases-to-tsv.py
# parses it with the Python standard library, resolves every layout to the
# deployed schema id from the staged shared tree, and writes a TSV. The C++
# harness (harness-mac/builtin-playback-main.cc) only feeds those cases to a
# real, pinned librime 1.17.0 process: rb_select_schema -> rb_set_option for the
# case's options -> rb_process_key per key -> first-page `expect_first`
# assertion -> find/page/select -> commit_text comparison. Existing cases keep
# the plain find-and-commit contract and run unchanged.
#
# Staging: the shared directory is a copy of Resources/BuiltinPackages/Basic
# plus Resources/EngineResources/opencc, which is where librime's simplifier
# looks for `<shared>/opencc/<config>.json`. The user directory is fresh per
# run; projection capture writes the requested fixture output directory.
#
# Usage:
#   NATIVE_ENGINE_ROOT="$PWD/.local/engine" \
#     Tools/BuildRimeIOS/scripts/39-builtin-playback-harness.sh
#
#   ... 39-builtin-playback-harness.sh --capture-projections
#     Regenerate the two committed real-engine projection fixtures from the
#     staged data. Run this only after the dictionary/schema that owns the new
#     syllables has landed; this script never edits the dictionary or fixtures
#     itself.
#
# Environment:
#   NATIVE_ENGINE_ROOT        pinned macOS engine root (read-only; default
#                             <repo>/.local/engine; pass the main repository's
#                             engine root when this worktree has none)
#   BUILTIN_PLAYBACK_CASES    default Tests/EngineFixtures/Builtin/playback_cases.json
#   BUILTIN_PLAYBACK_PACKAGE  default Resources/BuiltinPackages/Basic
#   BUILTIN_PLAYBACK_OPENCC   default Resources/EngineResources/opencc
#   BUILTIN_PLAYBACK_SHARED   reuse an already staged shared tree (skips the copy)
#   BUILTIN_PLAYBACK_MODE     source|prebuilt (default source: real cold deploy)
#   BUILTIN_PLAYBACK_COMPILED compiled generation for prebuilt mode
#   BUILTIN_PLAYBACK_RECORD   1 prints per-case preedit/candidates (evidence only)
#   BUILTIN_PLAYBACK_REQUIRE_FIRST_FOR_OPTIONS  default 1
#   BUILTIN_PLAYBACK_OPTION_GROUP  default simplification,zht,zh_tw,zh_hk
#   BUILTIN_PLAYBACK_MAX_PAGES     default 40
#   BUILTIN_PLAYBACK_PROJECTION_DIR output directory for --capture-projections
#   BUILTIN_PLAYBACK_USER          reuse a user directory instead of a fresh one
#
# Exit: 0 all cases passed (or projections captured); 2 replay/engine failure;
# 3 fixture/preprocess failure; 64 usage.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

say() { printf '\n[Harness] %s\n' "$*" >&2; }

usage() {
  printf 'usage: %s [--capture-projections]\n' "$(basename "$0")" >&2
  exit 64
}

CAPTURE=0
case "${1:-}" in
  "") ;;
  --capture-projections) CAPTURE=1 ;;
  -h | --help) usage ;;
  *) usage ;;
esac
[[ $# -le 1 ]] || usage

PACKAGE="${BUILTIN_PLAYBACK_PACKAGE:-${PROJECT_ROOT}/Resources/BuiltinPackages/Basic}"
OPENCC="${BUILTIN_PLAYBACK_OPENCC:-${PROJECT_ROOT}/Resources/EngineResources/opencc}"
CASES="${BUILTIN_PLAYBACK_CASES:-${PROJECT_ROOT}/Tests/EngineFixtures/Builtin/playback_cases.json}"
MODE="${BUILTIN_PLAYBACK_MODE:-source}"
COMPILED="${BUILTIN_PLAYBACK_COMPILED:-}"
RECORD="${BUILTIN_PLAYBACK_RECORD:-0}"
REQUIRE_FIRST="${BUILTIN_PLAYBACK_REQUIRE_FIRST_FOR_OPTIONS:-1}"
OPTION_GROUP="${BUILTIN_PLAYBACK_OPTION_GROUP:-simplification,zht,zh_tw,zh_hk}"
MAX_PAGES="${BUILTIN_PLAYBACK_MAX_PAGES:-40}"

case "${MODE}" in
  source | prebuilt) ;;
  *) die "BUILTIN_PLAYBACK_MODE must be source or prebuilt: ${MODE}" ;;
esac
[[ "${REQUIRE_FIRST}" == "0" || "${REQUIRE_FIRST}" == "1" ]] || die \
  "BUILTIN_PLAYBACK_REQUIRE_FIRST_FOR_OPTIONS must be 0 or 1"
[[ "${RECORD}" == "0" || "${RECORD}" == "1" ]] || die "BUILTIN_PLAYBACK_RECORD must be 0 or 1"
[[ "${MAX_PAGES}" =~ ^[0-9]+$ && "${MAX_PAGES}" -ge 1 ]] || die \
  "BUILTIN_PLAYBACK_MAX_PAGES must be a positive integer"
if [[ "${MODE}" == "prebuilt" ]]; then
  [[ -n "${COMPILED}" && -d "${COMPILED}" ]] || die \
    "BUILTIN_PLAYBACK_COMPILED must point at a compiled generation for prebuilt mode"
fi
[[ -d "${PACKAGE}" ]] || die "built-in package not found: ${PACKAGE}"
[[ -f "${OPENCC}/s2t.json" && -f "${OPENCC}/s2twp.json" && -f "${OPENCC}/s2hk.json" ]] || die \
  "opencc data is incomplete under ${OPENCC}"
[[ -f "${MAC_PREFIX}/lib/librime.a" ]] || die \
  "missing ${MAC_PREFIX}/lib/librime.a; set NATIVE_ENGINE_ROOT to the pinned macOS engine root"
[[ -d "${MAC_PREFIX}/include" ]] || die "missing ${MAC_PREFIX}/include (pinned dependency headers)"

RUN_DIR="$(new_harness_dir builtin-playback)"
SHARED="${BUILTIN_PLAYBACK_SHARED:-}"
if [[ -z "${SHARED}" ]]; then
  SHARED="${RUN_DIR}/shared"
  mkdir -p "${SHARED}/opencc"
  cp -R "${PACKAGE}/." "${SHARED}/"
  cp -R "${OPENCC}/." "${SHARED}/opencc/"
fi
[[ -f "${SHARED}/default.yaml" ]] || die "staged shared data missing default.yaml: ${SHARED}"
[[ -f "${SHARED}/opencc/s2twp.json" ]] || die "staged shared data missing opencc: ${SHARED}"
USER_DIR="${BUILTIN_PLAYBACK_USER:-}"
if [[ -z "${USER_DIR}" ]]; then
  USER_DIR="$(new_isolated_dir "${RUN_DIR}/user")"
fi
[[ -d "${USER_DIR}" ]] || die "user directory is missing: ${USER_DIR}"

GEN_INCLUDE="$(rime_generated_include)"
prepare_native_bridge
compile_bridge_c
compile_bridge_cpp rime_spelling
compile_bridge_cpp rime_display_map
MAIN_FLAGS=()
for flag in "${MAC_CXX_FLAGS[@]}"; do
  [[ "${flag}" == "-c" ]] || MAIN_FLAGS+=("${flag}")
done
BIN="${RUN_DIR}/builtin-playback"
say "compile playback harness (-O2) against ${MAC_PREFIX}"
"${MAC_CXX}" "${MAIN_FLAGS[@]}" -Wall -Wextra -Werror \
  "${IOS_TOOLS_DIR}/harness-mac/builtin-playback-main.cc" \
  "${RUN_DIR}/rime_bridge.o" "${RUN_DIR}/rime_spelling.o" "${RUN_DIR}/rime_display_map.o" \
  "${MAC_LINK_FLAGS[@]}" \
  -o "${BIN}"

if [[ "${CAPTURE}" == "1" ]]; then
  PROJECTION_DIR="${BUILTIN_PLAYBACK_PROJECTION_DIR:-}"
  if [[ -z "${PROJECTION_DIR}" ]]; then
    PROJECTION_DIR="${PROJECT_ROOT}/Packages/PackageManager/Tests/PackageManagerTests/Fixtures"
  fi
  [[ -d "${PROJECTION_DIR}" ]] || die "projection fixture directory is missing: ${PROJECTION_DIR}"
  say "capture real-engine projections -> ${PROJECTION_DIR}"
  for schema in songyan_quanpin songyan_flypy; do
    RAW="${RUN_DIR}/${schema}.projection.raw.json"
    "${BIN}" --mode "${MODE}" --shared "${SHARED}" --user "${USER_DIR}" \
      --dump-projection "${schema}" >"${RAW}"
    python3 - "${RAW}" "${PROJECTION_DIR}/${schema}.projection.json" <<'PY'
import json
import sys

source, destination = sys.argv[1], sys.argv[2]
indent = 1
try:
    with open(destination, encoding="utf-8") as existing:
        head = existing.read(256)
    indent = 2 if head.startswith('{\n  "') else 1
except OSError:
    pass
with open(source, encoding="utf-8") as stream:
    document = json.load(stream)
with open(destination, "w", encoding="utf-8") as stream:
    json.dump(document, stream, ensure_ascii=False, indent=indent, sort_keys=True)
    stream.write("\n")
PY
    say "captured ${schema}: ${PROJECTION_DIR}/${schema}.projection.json"
  done
  say "now run Tools/BuildRimeIOS/scripts/gen-builtin-companions.sh to regenerate the 6 companions"
  exit 0
fi

CASES_TSV="${RUN_DIR}/cases.tsv"
say "preprocess ${CASES} -> ${CASES_TSV}"
PREPROCESS=(
  --fixtures "${CASES}"
  --shared "${SHARED}"
  --output "${CASES_TSV}"
  --option-group "${OPTION_GROUP}"
)
if [[ "${REQUIRE_FIRST}" == "1" ]]; then
  PREPROCESS+=(--require-first-for-options)
fi
python3 "${IOS_TOOLS_DIR}/scripts/playback-cases-to-tsv.py" "${PREPROCESS[@]}"

ARGS=(
  --mode "${MODE}"
  --shared "${SHARED}"
  --user "${USER_DIR}"
  --cases "${CASES_TSV}"
  --label builtin-playback
  --max-pages "${MAX_PAGES}"
)
if [[ -n "${COMPILED}" ]]; then
  ARGS+=(--compiled "${COMPILED}")
fi
if [[ "${RECORD}" == "1" ]]; then
  ARGS+=(--record)
fi
say "replay playback fixtures through the real librime engine"
STATUS=0
"${BIN}" "${ARGS[@]}" || STATUS=$?
say "harness dir: ${RUN_DIR}"
exit "${STATUS}"
