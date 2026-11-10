#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# kagiroi-performance-harness.sh — macOS per-key latency for Japanese (kagiroi,
# pinned librime 1.17.0 + pinned librime-lua) against the built-in pinyin scheme
# of the same key count.
#
# This is a real macOS process linked against the pinned macOS librime prefix.
# It is NOT the iOS simulator and does not report keyboard-extension memory or
# IME end-to-end latency; it measures one key path only: rb_process_key() to
# rb_snapshot_get(), single thread, at least 10 rounds with one discarded warmup
# round, composition cleared between rounds.
#
# The pinned macOS librime/dependency prefix is only read. The pinned Lua +
# librime-lua sources are compiled into this worktree (ARCHIVE-prefix under
# .local/kagiroi-perf) with the repository's own Tools/BuildRimeIOS/lua CMake
# project, -O2, at most 4 jobs; nothing under the main-repo cache is modified.
#
# Usage:
#   KAGIROI_SHARED=<shared data dir> KAGIROI_COMPILED=<compiled .bin dir> \
#     Tools/BuildRimeIOS/scripts/kagiroi-performance-harness.sh
#
# Fixtures are always passed in by the caller (nothing host-specific is baked
# into this script or the harness source):
#   KAGIROI_SHARED    shared data dir: default.yaml, kagiroi*.schema.yaml, lua/,
#                     opencc/ (an immutable published generation's shared tree)
#   KAGIROI_COMPILED  the compiled generation (default.yaml + *.bin + deployed
#                     schema yaml) produced by a real deployment
#   KAGIROI_SCHEMA    Japanese schema id (default kagiroi)
#   KAGIROI_PROBE_TEXT / KAGIROI_EXPECT_CANDIDATE  Japanese probe + assertion
#                     (defaults nihongo / 日本語)
#   KAGIROI_PERF_JAPANESE_TEXT / KAGIROI_PERF_PINYIN_TEXT  same-length key texts
#   KAGIROI_PERF_PINYIN_SCHEMA  default songyan_quanpin
#   KAGIROI_PERF_PINYIN_PACKAGE default <repo>/Resources/BuiltinPackages/Basic,
#                     copied to a fresh directory and deployed from source
#   KAGIROI_PERF_ROUNDS (default 10) / KAGIROI_PERF_WARMUP (default 1)
#   NATIVE_ENGINE_ROOT  pinned macOS engine root (read-only; default
#                     <repo>/.local/engine; pass the main repo's path here)
#   KAGIROI_LUA_SOURCE / KAGIROI_PLUGIN_SOURCE  override the pinned sources
#   KAGIROI_PERF_BUILD_ROOT (default <repo>/.local/kagiroi-perf) holds the
#                     compiled Lua plugin prefix; KAGIROI_PERF_REBUILD=1 forces
#                     a rebuild
#   KAGIROI_PERF_OUT  final combined JSON path (default <run-dir>/result.json)
#
# Output: one combined JSON document on stdout (Japanese block, pinyin block,
# comparison). Diagnostics go to stderr. A missing/empty fixture fails before
# any measurement, so a red run cannot be reported as data.
# ---------------------------------------------------------------------------
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

say() { printf '\n[Harness] %s\n' "$*" >&2; }

[[ -n "${KAGIROI_SHARED:-}" ]] || die \
  "set KAGIROI_SHARED to the published kagiroi shared data directory"
[[ -n "${KAGIROI_COMPILED:-}" ]] || die \
  "set KAGIROI_COMPILED to the compiled kagiroi generation directory"

JOBS="${KAGIROI_PERF_JOBS:-4}"
[[ "${JOBS}" =~ ^[1-4]$ ]] || die "KAGIROI_PERF_JOBS must be 1..4"
ROUNDS="${KAGIROI_PERF_ROUNDS:-10}"
WARMUP="${KAGIROI_PERF_WARMUP:-1}"
[[ "${ROUNDS}" =~ ^[0-9]+$ && "${ROUNDS}" -ge 10 ]] || die "KAGIROI_PERF_ROUNDS must be >= 10"
[[ "${WARMUP}" =~ ^[0-9]+$ ]] || die "KAGIROI_PERF_WARMUP must be a non-negative integer"

KAGIROI_SCHEMA="${KAGIROI_SCHEMA:-kagiroi}"
KAGIROI_PROBE_TEXT="${KAGIROI_PROBE_TEXT:-nihongo}"
KAGIROI_EXPECT_CANDIDATE="${KAGIROI_EXPECT_CANDIDATE:-日本語}"
JAPANESE_TEXT="${KAGIROI_PERF_JAPANESE_TEXT:-watashihanihongonogakuseidesu}"
PINYIN_TEXT="${KAGIROI_PERF_PINYIN_TEXT:-nihaonihaonihaonihaonihaotian}"
PINYIN_SCHEMA="${KAGIROI_PERF_PINYIN_SCHEMA:-songyan_quanpin}"
PINYIN_PACKAGE="${KAGIROI_PERF_PINYIN_PACKAGE:-${PROJECT_ROOT}/Resources/BuiltinPackages/Basic}"
BUILD_ROOT="${KAGIROI_PERF_BUILD_ROOT:-${PROJECT_ROOT}/.local/kagiroi-perf}"
LUA_PREFIX="${BUILD_ROOT}/prefix"
LUA_BUILD="${BUILD_ROOT}/lua-build"

[[ -f "${MAC_PREFIX}/lib/librime.a" ]] || die \
  "missing ${MAC_PREFIX}/lib/librime.a; point NATIVE_ENGINE_ROOT at the pinned macOS engine prefix"
[[ -d "${PINYIN_PACKAGE}" ]] || die "pinyin package not found: ${PINYIN_PACKAGE}"

CMAKE="${NATIVE_ENGINE_ROOT}/tools/cmake/CMake.app/Contents/bin/cmake"
if [[ ! -x "${CMAKE}" ]]; then
  CMAKE="$(command -v cmake || true)"
fi
[[ -n "${CMAKE}" && -x "${CMAKE}" ]] || die \
  "no CMake under ${NATIVE_ENGINE_ROOT}/tools or PATH (run Tools/BuildRime first)"

# ---- pinned Lua + librime-lua (same env files the shipped XCFramework uses) --
LUA_VERSIONS="${IOS_TOOLS_DIR}/LUA-VERSIONS.env"
LUA_VERSION="$(sed -n 's/^LUA_VERSION=//p' "${LUA_VERSIONS}")"
RIME_LUA_COMMIT="$(sed -n 's/^RIME_LUA_COMMIT=//p' "${LUA_VERSIONS}")"
[[ -n "${LUA_VERSION}" && -n "${RIME_LUA_COMMIT}" ]] || die "cannot read ${LUA_VERSIONS}"
[[ -d "${MAC_PREFIX}/include" ]] || die "missing ${MAC_PREFIX}/include (pinned dependency headers)"

resolve_pinned_sources() {
  local lua_source="${KAGIROI_LUA_SOURCE:-}" plugin_source="${KAGIROI_PLUGIN_SOURCE:-}"
  local candidate
  if [[ -z "${lua_source}" ]]; then
    for candidate in "${NATIVE_ENGINE_ROOT}/plugin-sources/src" \
                     "${NATIVE_ENGINE_ROOT}/../ios-engine/plugin-sources/src"; do
      if [[ -d "${candidate}/lua-${LUA_VERSION}" && -d "${candidate}/librime-lua" ]]; then
        lua_source="${candidate}/lua-${LUA_VERSION}"
        plugin_source="${candidate}/librime-lua"
        break
      fi
    done
  fi
  [[ -n "${lua_source}" && -n "${plugin_source}" ]] || die \
    "pinned Lua/librime-lua sources not found; set KAGIROI_LUA_SOURCE and KAGIROI_PLUGIN_SOURCE"
  LUA_SOURCE="${lua_source}"
  PLUGIN_SOURCE="${plugin_source}"
}

resolve_pinned_sources
[[ -d "${LUA_SOURCE}" ]] || die "Lua source missing: ${LUA_SOURCE}"
[[ -d "${PLUGIN_SOURCE}/src" ]] || die "librime-lua source missing: ${PLUGIN_SOURCE}"
if [[ -d "${PLUGIN_SOURCE}/.git" ]]; then
  actual_commit="$(git -C "${PLUGIN_SOURCE}" rev-parse HEAD)"
  [[ "${actual_commit}" == "${RIME_LUA_COMMIT}" ]] || die \
    "librime-lua source is at ${actual_commit}, pinned ${RIME_LUA_COMMIT}"
fi

build_lua_plugin() {
  local arch
  arch="$(uname -m)"
  say "build pinned Lua ${LUA_VERSION} + librime-lua into ${LUA_PREFIX} (-O2, ${JOBS} jobs)"
  mkdir -p "${LUA_PREFIX}"
  if [[ ! -d "${LUA_PREFIX}/include" ]]; then
    # Headers only; the pinned prefix itself is never written.
    cp -R "${MAC_PREFIX}/include" "${LUA_PREFIX}/include"
  fi
  "${CMAKE}" -S "${IOS_TOOLS_DIR}/lua" -B "${LUA_BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG" \
    -DCMAKE_OSX_ARCHITECTURES="${arch}" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DCMAKE_INSTALL_PREFIX="${LUA_PREFIX}" \
    -DLUA_SOURCE="${LUA_SOURCE}" -DPLUGIN_SOURCE="${PLUGIN_SOURCE}" \
    -DRIME_SOURCE="${LIBRIME_SRC}" -DBOOST_SOURCE="${BOOST_SRC}" \
    -DRIME_GENERATED_INCLUDE="${GEN_INCLUDE}" >&2
  "${CMAKE}" --build "${LUA_BUILD}" --target install -j "${JOBS}" >&2
  [[ -f "${LUA_PREFIX}/lib/librime-lua.a" && -f "${LUA_PREFIX}/lib/liblua.a" ]] || die \
    "Lua plugin build did not produce static archives in ${LUA_PREFIX}/lib"
}

GEN_INCLUDE="$(rime_generated_include)"
if [[ ! -f "${LUA_PREFIX}/lib/librime-lua.a" || ! -f "${LUA_PREFIX}/lib/liblua.a" ||
      -n "${KAGIROI_PERF_REBUILD:-}" ]]; then
  build_lua_plugin
else
  say "reuse compiled Lua plugin prefix ${LUA_PREFIX}"
fi

# ---- harness binary ---------------------------------------------------------
RUN_DIR="$(new_harness_dir kagiroi-perf)"
prepare_native_bridge
compile_bridge_c -DRB_WITH_LUA=1
for shim in rime_spelling rime_lua_link; do
  compile_bridge_cpp "${shim}"
done
MAIN_FLAGS=()
for flag in "${MAC_CXX_FLAGS[@]}"; do
  [[ "${flag}" == "-c" ]] || MAIN_FLAGS+=("${flag}")
done
say "macOS SDK: ${MACOS_SDK} ($(uname -m)); pinned engine prefix: ${MAC_PREFIX}"
say "compile kagiroi-perf harness (-O2)"
"${MAC_CXX}" "${MAIN_FLAGS[@]}" \
  "${IOS_TOOLS_DIR}/harness-mac/kagiroi-perf-main.cc" \
  "${RUN_DIR}/rime_bridge.o" "${RUN_DIR}/rime_spelling.o" "${RUN_DIR}/rime_lua_link.o" \
  -Xlinker "${LUA_PREFIX}/lib/librime-lua.a" -Xlinker "${LUA_PREFIX}/lib/liblua.a" \
  "${MAC_LINK_FLAGS[@]}" \
  -o "${RUN_DIR}/kagiroi-perf"

# ---- fixtures ---------------------------------------------------------------
mkdir -p "${RUN_DIR}/user-japanese" "${RUN_DIR}/user-pinyin"
PINYIN_SHARED="${KAGIROI_PERF_PINYIN_SHARED:-}"
if [[ -z "${PINYIN_SHARED}" ]]; then
  PINYIN_SHARED="${RUN_DIR}/pinyin-shared"
  cp -R "${PINYIN_PACKAGE}" "${PINYIN_SHARED}"
fi

# ---- measure ----------------------------------------------------------------
JAPANESE_JSON="${RUN_DIR}/japanese.json"
PINYIN_JSON="${RUN_DIR}/pinyin.json"
OUT_JSON="${KAGIROI_PERF_OUT:-${RUN_DIR}/result.json}"

say "measure Japanese: ${KAGIROI_SCHEMA}, ${#JAPANESE_TEXT} keys, ${WARMUP} warmup + ${ROUNDS} rounds"
"${RUN_DIR}/kagiroi-perf" \
  --mode prebuilt --shared "${KAGIROI_SHARED}" --compiled "${KAGIROI_COMPILED}" \
  --user "${RUN_DIR}/user-japanese" --schema "${KAGIROI_SCHEMA}" --text "${JAPANESE_TEXT}" \
  --label japanese --rounds "${ROUNDS}" --warmup "${WARMUP}" \
  --probe-text "${KAGIROI_PROBE_TEXT}" --expect-candidate "${KAGIROI_EXPECT_CANDIDATE}" \
  > "${JAPANESE_JSON}"

say "measure pinyin baseline: ${PINYIN_SCHEMA}, ${#PINYIN_TEXT} keys, ${WARMUP} warmup + ${ROUNDS} rounds"
"${RUN_DIR}/kagiroi-perf" \
  --mode source --shared "${PINYIN_SHARED}" \
  --user "${RUN_DIR}/user-pinyin" --schema "${PINYIN_SCHEMA}" --text "${PINYIN_TEXT}" \
  --label pinyin --rounds "${ROUNDS}" --warmup "${WARMUP}" \
  > "${PINYIN_JSON}"

python3 - "${JAPANESE_JSON}" "${PINYIN_JSON}" "${OUT_JSON}" <<'PY'
import json
import sys

japanese_path, pinyin_path, output_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(japanese_path, encoding="utf-8") as stream:
    japanese = json.load(stream)
with open(pinyin_path, encoding="utf-8") as stream:
    pinyin = json.load(stream)

if japanese["keys"] != pinyin["keys"]:
    sys.stderr.write(
        "[FAIL] key counts differ: Japanese %d, pinyin %d\n"
        % (japanese["keys"], pinyin["keys"])
    )
    sys.exit(3)

japanese_p50 = japanese["pooled_p50_ms"]
japanese_p95 = japanese["pooled_p95_ms"]
pinyin_p50 = pinyin["pooled_p50_ms"]
pinyin_p95 = pinyin["pooled_p95_ms"]
comparison = {
    "keys_equal": True,
    "keys": japanese["keys"],
    "rounds": japanese["rounds"],
    "warmup_rounds": japanese["warmup_rounds"],
    "p50_ratio_japanese_over_pinyin": round(japanese_p50 / pinyin_p50, 2) if pinyin_p50 else None,
    "p95_ratio_japanese_over_pinyin": round(japanese_p95 / pinyin_p95, 2) if pinyin_p95 else None,
    "japanese_p95_within_3x_pinyin": japanese_p95 <= 3.0 * pinyin_p95,
    "japanese_p95_at_most_50ms": japanese_p95 <= 50.0,
}
document = {"japanese": japanese, "pinyin": pinyin, "comparison": comparison}
with open(output_path, "w", encoding="utf-8") as stream:
    json.dump(document, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
print(json.dumps(document, ensure_ascii=False, indent=2))
PY

say "combined JSON written to ${OUT_JSON}"