#!/usr/bin/env bash
# Run native keyboard performance tests or AXe cold-start diagnostics (see DEBUG.md).
# Usage: sim-perf.sh typing [label] | cold [runs]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-typing}"
if [[ "${MODE}" == typing ]]; then
  exec "${SCRIPT_DIR}/sim-benchmark.sh" "${2:-run}"
fi
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/xcode.sh"
source "${SCRIPT_DIR}/lib/sim.sh"
require_xcode >/dev/null
UDID="$(resolve_sim_udid)"
[[ -n "${UDID}" ]] || { echo "no simulator named ${SIM_NAME:-Songyan-Dev}; run make sim-stage first" >&2; exit 1; }
command -v axe >/dev/null || { echo "axe is required (see DEBUG.md, Setup)" >&2; exit 1; }
resolve_sim_identity
OUT="$(new_run_dir "perf-${MODE}")"

ext_pid() { pgrep -f "${UDID}.*KeyboardExtension.appex/KeyboardExtension" | head -1 || true; }

case "${MODE}" in
  cold)
    RUNS="${2:-3}"
    # Release builds only emit lifecycle lines with the shared diagnostics switch on.
    GROUP="$(sim_group_container "${UDID}")"
    [[ -n "${GROUP}" ]] && xcrun simctl spawn "${UDID}" defaults write \
      "${GROUP}/Library/Preferences/${GROUP_ID}" keyboard.lifecycleDiagnosticsEnabled -bool YES
    for ((run = 1; run <= RUNS; run++)); do
      xcrun simctl terminate "${UDID}" "${HOST_ID}" >/dev/null 2>&1 || true
      pid="$(ext_pid)"; [[ -n "${pid}" ]] && kill "${pid}" 2>/dev/null || true
      sleep 1.5
      xcrun simctl launch "${UDID}" "${HOST_ID}" >/dev/null; sleep 3
      axe tap --udid "${UDID}" --label 试打 --tap-style physical >/dev/null; sleep 2
      axe tap --udid "${UDID}" -x 201 -y 400 --tap-style physical >/dev/null; sleep 4
      pid="$(ext_pid)"
      echo "run ${run} pid ${pid:-none}" | tee -a "${OUT}/cold.txt"
      [[ -n "${pid}" ]] || continue
      xcrun simctl spawn "${UDID}" log show --last 15s --style compact --info --predicate "processID == ${pid}" \
        2>/dev/null | grep -E "Hello, I'm launching|Prepare received|event=(viewWillAppear|viewDidAppear|engineReady)|slowEngineOp" \
        | sed -E 's/^[0-9-]+ //; s/KeyboardExtension\[[^]]*\] //' | cut -c1-220 | tee -a "${OUT}/cold.txt"
    done
    ;;
  *) echo "usage: sim-perf.sh typing [label] | cold [runs]" >&2; exit 64 ;;
esac
echo "[perf] artifacts: ${OUT}"
