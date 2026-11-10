#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# kagiroi-source-build-harness.sh — real macOS native source build + prebuilt
# reopen for a no-nico kagiroi package. It reuses the existing drivers and
# flags instead of a new framework:
#   * harness-mac/builtin-playback-main.cc (source/prebuilt modes, first
#     candidate and committed-text assertions);
#   * lib/harness.sh (pinned librime/boost flags, C bridge and shims);
#   * the pinned librime-lua + Lua 5.4.9 prefix from kagiroi-performance-harness.sh.
#
# Usage:
#   KAGIROI_SOURCE=/path/to/prepared/source \
#   NATIVE_ENGINE_ROOT=/path/to/songyan-ios/.local/engine \
#     Tools/BuildRimeIOS/scripts/kagiroi-source-build-harness.sh
#
# Environment: KAGIROI_SOURCE (required prepared source directory),
# KAGIROI_SOURCE_BUILD_ROOT (<repo>/.scratch/kagiroi-source-build),
# KAGIROI_SOURCE_OUT (<repo>/.local/kagiroi-source-build), KAGIROI_SOURCE_ARTIFACT
# (<out>/kagiroi-source, must not exist), KAGIROI_LUA_PREFIX
# (<repo>/.local/kagiroi-perf/prefix), KAGIROI_PROBE_TEXT (nihongo),
# KAGIROI_EXPECT_PREEDIT (にほんご), KAGIROI_EXPECT_CANDIDATE (日本語),
# KAGIROI_PRELUDE (<repo>/Packages/PackageManager/Sources/PackageManager/
# Resources/RimePrelude), KAGIROI_LUA_SOURCE / KAGIROI_PLUGIN_SOURCE.
# Exit 0 only after the source deployment and both prebuilt reopens pass; any
# missing fixture, engine failure or wrong preedit/candidate exits non-zero.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

say() { printf '\n[Harness] %s\n' "$*" >&2; }
: "${KAGIROI_SOURCE:?set KAGIROI_SOURCE to the prepared source directory}"
SOURCE_DIR="${KAGIROI_SOURCE}"
PRELUDE_DIR="${KAGIROI_PRELUDE:-${PROJECT_ROOT}/Packages/PackageManager/Sources/PackageManager/Resources/RimePrelude}"
BUILD_ROOT="${KAGIROI_SOURCE_BUILD_ROOT:-${PROJECT_ROOT}/.scratch/kagiroi-source-build}"
OUT_ROOT="${KAGIROI_SOURCE_OUT:-${PROJECT_ROOT}/.local/kagiroi-source-build}"
ARTIFACT="${KAGIROI_SOURCE_ARTIFACT:-${OUT_ROOT}/kagiroi-source}"
LUA_PREFIX="${KAGIROI_LUA_PREFIX:-${PROJECT_ROOT}/.local/kagiroi-perf/prefix}"
PROBE_TEXT="${KAGIROI_PROBE_TEXT:-nihongo}"
EXPECT_PREEDIT="${KAGIROI_EXPECT_PREEDIT:-にほんご}"
EXPECT_CANDIDATE="${KAGIROI_EXPECT_CANDIDATE:-日本語}"
JOBS="${KAGIROI_SOURCE_JOBS:-4}"
[[ -d "${SOURCE_DIR}" && -f "${SOURCE_DIR}/kagiroi.schema.yaml" && -f "${SOURCE_DIR}/default.yaml" ]] || die \
  "source is not a deployable kagiroi package (needs default.yaml and kagiroi.schema.yaml): ${SOURCE_DIR}"
[[ ! -e "${SOURCE_DIR}/kagiroi.nico.dict.yaml" ]] || die \
  "refusing a source tree that still contains kagiroi.nico.dict.yaml: ${SOURCE_DIR}"
[[ -d "${SOURCE_DIR}/lua/kagiroi" && -d "${SOURCE_DIR}/opencc" && -d "${PRELUDE_DIR}" ]] || die \
  "source/prelude is incomplete: ${SOURCE_DIR} ${PRELUDE_DIR}"
[[ -f "${MAC_PREFIX}/lib/librime.a" ]] || die \
  "missing ${MAC_PREFIX}/lib/librime.a; set NATIVE_ENGINE_ROOT to the pinned macOS engine root"
[[ "${JOBS}" =~ ^[1-8]$ ]] || die "KAGIROI_SOURCE_JOBS must be 1..8"
mkdir -p "${OUT_ROOT}"
[[ ! -e "${ARTIFACT}" ]] || die "artifact already exists (move it away; this script never deletes): ${ARTIFACT}"

# Reuse the pinned Lua archives; build them once into the host root if absent.
ensure_lua_prefix() {
  if [[ -f "${LUA_PREFIX}/lib/librime-lua.a" && -f "${LUA_PREFIX}/lib/liblua.a" ]]; then
    say "reuse pinned Lua plugin prefix ${LUA_PREFIX}"; return 0; fi
  local lua_source="${KAGIROI_LUA_SOURCE:-}" plugin_source="${KAGIROI_PLUGIN_SOURCE:-}" candidate
  for candidate in "${NATIVE_ENGINE_ROOT}/plugin-sources/src" "${NATIVE_ENGINE_ROOT}/../ios-engine/plugin-sources/src"; do
    [[ -n "${lua_source}" ]] && break
    if [[ -d "${candidate}/lua-5.4.9" && -d "${candidate}/librime-lua" ]]; then
      lua_source="${candidate}/lua-5.4.9"; plugin_source="${candidate}/librime-lua"; fi; done
  [[ -n "${lua_source}" && -n "${plugin_source}" ]] || die \
    "missing ${LUA_PREFIX}/lib archives; set KAGIROI_LUA_SOURCE and KAGIROI_PLUGIN_SOURCE"
  local cmake="${NATIVE_ENGINE_ROOT}/tools/cmake/CMake.app/Contents/bin/cmake"
  [[ -x "${cmake}" ]] || cmake="$(command -v cmake || true)"
  [[ -n "${cmake}" && -x "${cmake}" ]] || die "no CMake under ${NATIVE_ENGINE_ROOT}/tools or PATH"
  LUA_PREFIX="$(new_isolated_dir "${BUILD_ROOT}/lua-prefix")"
  say "build pinned Lua 5.4.9 + librime-lua into ${LUA_PREFIX} (-O2, ${JOBS} jobs)"
  cp -R "${MAC_PREFIX}/include" "${LUA_PREFIX}/include"
  "${cmake}" -S "${IOS_TOOLS_DIR}/lua" -B "${LUA_PREFIX}/lua-build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG" \
    -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_INSTALL_PREFIX="${LUA_PREFIX}" -DLUA_SOURCE="${lua_source}" -DPLUGIN_SOURCE="${plugin_source}" \
    -DRIME_SOURCE="${LIBRIME_SRC}" -DBOOST_SOURCE="${BOOST_SRC}" \
    -DRIME_GENERATED_INCLUDE="${GEN_INCLUDE}" >&2
  "${cmake}" --build "${LUA_PREFIX}/lua-build" --target install -j "${JOBS}" >&2
  [[ -f "${LUA_PREFIX}/lib/librime-lua.a" && -f "${LUA_PREFIX}/lib/liblua.a" ]] || die \
    "Lua plugin build did not produce static archives in ${LUA_PREFIX}/lib"
}

stage_input() {
  local input="$1" name
  cp -R "${SOURCE_DIR}/." "${input}/"
  for name in default.yaml key_bindings.yaml punctuation.yaml symbols.yaml; do
    [[ -f "${input}/${name}" ]] || cp "${PRELUDE_DIR}/${name}" "${input}/${name}"; done
  mkdir -p "${input}/frontend-rime-prelude"
  for name in LICENSE AUTHORS PROVENANCE.md COPYING; do
    [[ -f "${input}/frontend-rime-prelude/${name}" ]] || \
      cp "${PRELUDE_DIR}/${name}" "${input}/frontend-rime-prelude/${name}"; done
}

assert_runtime_evidence() {
  local log="$1" label="$2" preedit first commit
  grep -q "^SUMMARY.*passed=1.*failed=0.*first_checked=1" "${log}" || \
    die "${label}: SUMMARY is not one passing first-candidate case (see ${log})"
  grep -q $'^PASS\t1\t' "${log}" || die "${label}: case did not pass (see ${log})"
  preedit="$(awk -F'\t' '$1=="RECORD"{sub(/^preedit=/,"",$5); print $5}' "${log}")"
  first="$(awk -F'\t' '$1=="RECORD"{sub(/^first=/,"",$6); print $6}' "${log}")"
  commit="$(awk -F'\t' '$1=="COMMIT"{print $3}' "${log}")"
  [[ "${preedit}" == "${EXPECT_PREEDIT}" ]] || die "${label}: preedit \"${preedit}\" != \"${EXPECT_PREEDIT}\" (${log})"
  [[ "${first}" == "${EXPECT_CANDIDATE}" ]] || die "${label}: first candidate \"${first}\" != \"${EXPECT_CANDIDATE}\" (${log})"
  [[ "${commit}" == "${EXPECT_CANDIDATE}" ]] || die "${label}: committed \"${commit}\" != \"${EXPECT_CANDIDATE}\" (${log})"
  say "${label}: preedit=${preedit} first=${first} commit=${commit}"
}
GEN_INCLUDE="$(rime_generated_include)"
ensure_lua_prefix
RUN_DIR="$(new_isolated_dir "${BUILD_ROOT}/run")"
say "compile builtin-playback driver with Lua (-O2) against ${MAC_PREFIX}"
prepare_native_bridge
compile_bridge_c -DRB_WITH_LUA=1
for shim in rime_spelling rime_display_map rime_lua_link; do compile_bridge_cpp "${shim}"; done
MAIN_FLAGS=()
for flag in "${MAC_CXX_FLAGS[@]}"; do [[ "${flag}" == "-c" ]] || MAIN_FLAGS+=("${flag}"); done
BIN="${RUN_DIR}/builtin-playback"
"${MAC_CXX}" "${MAIN_FLAGS[@]}" -Wall -Wextra -Werror \
  "${IOS_TOOLS_DIR}/harness-mac/builtin-playback-main.cc" "${RUN_DIR}/rime_bridge.o" \
  "${RUN_DIR}/rime_spelling.o" "${RUN_DIR}/rime_display_map.o" "${RUN_DIR}/rime_lua_link.o" \
  -Xlinker "${LUA_PREFIX}/lib/librime-lua.a" -Xlinker "${LUA_PREFIX}/lib/liblua.a" \
  "${MAC_LINK_FLAGS[@]}" -o "${BIN}"

INPUT="$(new_isolated_dir "${BUILD_ROOT}/input")"
INPUT_CASES="${RUN_DIR}/probe.tsv"
stage_input "${INPUT}"
printf 'kagiroi\tromaji\tkagiroi\t-\t%s\t%s\t%s\n' "${PROBE_TEXT}" "${EXPECT_CANDIDATE}" "${EXPECT_CANDIDATE}" > "${INPUT_CASES}"
SOURCE_USER="$(new_isolated_dir "${BUILD_ROOT}/source-user")"
SOURCE_LOG="${OUT_ROOT}/source-deploy.log"
say "source mode: real cold deployment ${INPUT} -> ${SOURCE_USER}/build"
if ! "${BIN}" --mode source --shared "${INPUT}" --user "${SOURCE_USER}" --cases "${INPUT_CASES}" \
    --label kagiroi-source --record --max-pages 40 >"${SOURCE_LOG}" 2>&1; then
  tail -30 "${SOURCE_LOG}" >&2; die "source-mode cold deployment failed (see ${SOURCE_LOG})"; fi
assert_runtime_evidence "${SOURCE_LOG}" "source-mode deploy"
COMPILED="${SOURCE_USER}/build"
for table in kagiroi kagiroi_romaji kagiroi_kanji kagiroi_ansikana kagiroi_szromaji kagiroi_matrix; do
  for suffix in table reverse prism; do [[ -f "${COMPILED}/${table}.${suffix}.bin" ]] || \
    die "missing ${table}.${suffix}.bin in ${COMPILED}"; done; done

USER_DIR="$(new_isolated_dir "${BUILD_ROOT}/prebuilt-user")"
PREBUILT_LOG="${OUT_ROOT}/prebuilt-reopen.log"
say "prebuilt reopen: ${COMPILED} (no maintenance)"
"${BIN}" --mode prebuilt --shared "${INPUT}" --compiled "${COMPILED}" --user "${USER_DIR}" \
  --cases "${INPUT_CASES}" --label kagiroi-prebuilt-reopen --record --max-pages 40 \
  >"${PREBUILT_LOG}" 2>&1 || { tail -30 "${PREBUILT_LOG}" >&2; die "prebuilt reopen failed (see ${PREBUILT_LOG})"; }
assert_runtime_evidence "${PREBUILT_LOG}" "prebuilt reopen"

say "assemble runtime artifact ${ARTIFACT}"
mkdir -p "${ARTIFACT}"
cp -R "${INPUT}/lua" "${INPUT}/opencc" "${INPUT}/frontend-rime-prelude" "${ARTIFACT}/"
cp "${INPUT}/punctuation.yaml" "${INPUT}/key_bindings.yaml" "${INPUT}/symbols.yaml" "${ARTIFACT}/"
cp "${COMPILED}"/* "${ARTIFACT}/"
ARTIFACT_USER="$(new_isolated_dir "${BUILD_ROOT}/artifact-user")"
ARTIFACT_LOG="${OUT_ROOT}/prebuilt-artifact.log"
say "prebuilt reopen of the self-contained artifact (shared == compiled)"
"${BIN}" --mode prebuilt --shared "${ARTIFACT}" --compiled "${ARTIFACT}" --user "${ARTIFACT_USER}" \
  --cases "${INPUT_CASES}" --label kagiroi-artifact --record --max-pages 40 \
  >"${ARTIFACT_LOG}" 2>&1 || { tail -30 "${ARTIFACT_LOG}" >&2; die "artifact reopen failed (see ${ARTIFACT_LOG})"; }
assert_runtime_evidence "${ARTIFACT_LOG}" "artifact reopen"

SUMMARY="${OUT_ROOT}/summary.json"
python3 - "${SUMMARY}" "${SOURCE_DIR}" "${COMPILED}" "${ARTIFACT}" "${PROBE_TEXT}" \
  "${EXPECT_PREEDIT}" "${EXPECT_CANDIDATE}" "${SOURCE_LOG}" "${PREBUILT_LOG}" "${ARTIFACT_LOG}" <<'PY'
import json
import sys
from pathlib import Path

summary, source, compiled, artifact, text, preedit, candidate, *logs = sys.argv[1:]
def stats(directory):
    files = [path for path in Path(directory).rglob("*") if path.is_file()]
    return {"path": directory, "files": len(files), "bytes": sum(path.stat().st_size for path in files)}

with open(summary, "w", encoding="utf-8") as stream:
    json.dump({
        "source": stats(source), "compiled": stats(compiled), "artifact": stats(artifact),
        "probe": {"text": text, "preedit": preedit, "first_candidate": candidate, "committed": candidate},
        "verification": {"source_mode": "pass", "prebuilt_reopen": "pass", "artifact_reopen": "pass"},
        "logs": logs, "driver_source": "Tools/BuildRimeIOS/harness-mac/builtin-playback-main.cc",
    }, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
PY
say "artifact: ${ARTIFACT}"
say "summary: ${SUMMARY}"
printf '%s\n' "${ARTIFACT}"
