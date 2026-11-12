#!/usr/bin/env bash
# S0 verification driver for the keyboard extension (Debug builds only).
#
# Records the five things the plan's S0 asks before a script engine can be planned:
#   * how much text the extension really receives (selectedText / documentContextBeforeInput),
#   * whether Keychain items written by the host app are readable in the extension,
#   * whether the extension can reach the network (plaintext LAN and HTTPS),
#   * how much memory the extension process may still allocate,
#   * what a QuickJS runtime costs inside the extension process.
# The measurements live in DebugProbe (Apps/SharedKeyboard/S0Probe.swift); this script only
# stages what a run needs, drives one keyboard appearance and collects the files and log lines.
# Only lengths, status codes and byte sizes are recorded. The engine is a probe input: the
# archive below is built from a recorded tag and digest by s0-quickjs-probe.py, and no product
# build links it.
#
# Usage:
#   s0-probe.sh quickjs   build the probe engine archive and stage it linked into the extension
#   s0-probe.sh device    build the device archive and a Debug IPA; embeds S0_PROBE_HTTP_URL
#   s0-probe.sh serve     start the plaintext server a device probe fetches from, print its URL
#   s0-probe.sh device-log  collect a device's unified log for the probe (needs sudo and UDID)
#   s0-probe.sh setup     write the App Group switches, start the plaintext HTTP server
#   s0-probe.sh launch    launch the host app so it writes the Keychain markers (control run)
#   s0-probe.sh drive     open "试打" and tap its field so the keyboard appears (needs axe)
#   s0-probe.sh collect   copy the recorded artifacts and log lines into .local/s0-probe/
#   s0-probe.sh fixture   setup + fixed input fixture + collect, then verify every recorded length
#   s0-probe.sh run       quickjs + setup + launch + drive + collect
#   s0-probe.sh stop      remove the switches and stop the HTTP server
#
# Env: SIM_NAME (default Songyan-S0P), UDID, PORT (default 8765), HTTPS_URL, DEVELOPER_DIR,
#      S0_PROBE_HTTP_URL / S0_PROBE_HTTPS_URL: URLs a probe build embeds (default: this Mac's LAN
#      address and HTTPS_URL); the device build needs the plaintext one to stay reachable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/xcode.sh
source "${SCRIPT_DIR}/lib/xcode.sh"
# shellcheck source=lib/sim.sh
source "${SCRIPT_DIR}/lib/sim.sh"

SIM_NAME="${SIM_NAME:-Songyan-S0P}"
# The one probe category that carries every s0Probe line; checked against the unified log's
# predicate support on this Mac (simulator log store), and used for the device archive.
DEVICE_PROBE_PREDICATE='subsystem == "app.songyan.ime" AND category == "DebugProbe"'
DEVICE_LOG_LAST="${DEVICE_LOG_LAST:-15m}"
PORT="${PORT:-8765}"
HTTPS_URL="${HTTPS_URL:-https://example.com/}"
SCRATCH="${CI_ROOT}/.scratch/s0-probe"
EVIDENCE_ROOT="${CI_ROOT}/.local/s0-probe"

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 64
}

resolve_target() {
  require_xcode >/dev/null
  UDID="$(resolve_sim_udid)"
  if [[ -z "${UDID}" ]]; then
    echo "no ${SIM_NAME} simulator; run: SIM_NAME=${SIM_NAME} make sim-stage" >&2
    exit 1
  fi
  resolve_sim_identity
}

group_dir() {
  local container
  container="$(sim_group_container "${UDID}")"
  if [[ -z "${container}" ]]; then
    echo "App Group container unavailable" >&2
    return 1
  fi
  printf '%s' "${container}"
}

# Same write path as sim-probe.sh: through the simulator's cfprefsd, then restart the
# extension so the one-shot switches are read by a fresh process.
write_shared_default() {
  local domain="$1" key="$2" kind="$3" value="$4"
  case "${kind}" in
    bool) xcrun simctl spawn "${UDID}" defaults write "${domain}" "${key}" -bool "${value}" ;;
    string) xcrun simctl spawn "${UDID}" defaults write "${domain}" "${key}" -string "${value}" ;;
    *) echo "unknown default kind: ${kind}" >&2; exit 64 ;;
  esac
}

delete_shared_default() {
  local domain="$1" key="$2"
  xcrun simctl spawn "${UDID}" defaults delete "${domain}" "${key}" 2>/dev/null || true
}

restart_extension() {
  xcrun simctl spawn "${UDID}" killall -u "$(id -u)" cfprefsd 2>/dev/null || true
  pkill -9 -f "CoreSimulator/Devices/${UDID}/.*KeyboardExtension.appex" 2>/dev/null || true
}

# The URLs a probe build embeds. Nothing on a device can write the App Group defaults the
# extension reads, so the operator names the LAN address here and the host app seeds it there.
probe_http_url() {
  if [[ -n "${S0_PROBE_HTTP_URL:-}" ]]; then
    printf '%s' "${S0_PROBE_HTTP_URL}"
    return
  fi
  printf 'http://%s:%s/plain.txt' "$(lan_address)" "${PORT}"
}

probe_https_url() {
  printf '%s' "${S0_PROBE_HTTPS_URL:-${HTTPS_URL}}"
}

lan_address() {
  local address
  for interface in en0 en1 en2; do
    address="$(ipconfig getifaddr "${interface}" 2>/dev/null || true)"
    if [[ -n "${address}" ]]; then printf '%s' "${address}"; return; fi
  done
  printf '127.0.0.1'
}

start_http_server() {
  if [[ -f "${SCRATCH}/http.pid" ]] && kill -0 "$(cat "${SCRATCH}/http.pid")" 2>/dev/null; then
    return
  fi
  mkdir -p "${SCRATCH}/http"
  # Fixed answer body: the probe records only the status code and byte count.
  printf 'songyan s0 probe\n' > "${SCRATCH}/http/plain.txt"
  ( cd "${SCRATCH}/http" && exec python3 -m http.server "${PORT}" --bind 0.0.0.0 >"${SCRATCH}/http.log" 2>&1 ) &
  echo $! > "${SCRATCH}/http.pid"
  sleep 1
}

stop_http_server() {
  if [[ -f "${SCRATCH}/http.pid" ]]; then
    kill "$(cat "${SCRATCH}/http.pid")" 2>/dev/null || true
    rm -f "${SCRATCH}/http.pid"
  fi
}

# Builds the probe engine archive for one platform and prints its path. The archive is a probe
# input (tag and digest recorded in s0-quickjs-probe.py); a normal build links nothing.
engine_archive() {
  local platform="$1" archive
  archive="${CI_ROOT}/.scratch/s0-quickjs/libS0QuickJS-${platform}.a"
  if ! python3 "${CI_ROOT}/Tools/CI/scripts/s0-quickjs-probe.py" \
    --platform "${platform}" --library-out "${archive}" >/dev/null; then
    echo "[s0] could not build the ${platform} engine archive" >&2
    return 1
  fi
  [[ -f "${archive}" ]] || {
    echo "[s0] no ${platform} engine archive at ${archive}" >&2
    return 1
  }
  printf '%s' "${archive}"
}

# Stages a simulator build whose extension links the engine, so the engine runs in the
# extension's own process instead of a spawned one.
stage_quickjs() {
  resolve_target
  local archive
  archive="$(engine_archive simulator)"
  SIM_NAME="${SIM_NAME}" S0_PROBE_ARCHIVE="${archive}" \
    S0_PROBE_HTTP_URL="$(probe_http_url)" S0_PROBE_HTTPS_URL="$(probe_https_url)" \
    "${CI_ROOT}/Tools/CI/scripts/sim-stage.sh" --no-launch
  echo "[s0] probe build installed with $(basename "${archive}")"
  echo "[s0] embedded URLs: $(probe_http_url) $(probe_https_url)"
}

# Builds the device slice and a Debug device app that links it, then packages that app the way
# the repository already ships device builds: an ad-hoc signed IPA for an installer to re-sign.
# Compiling, linking and packaging are verifiable without a certificate; running it needs a
# re-signed install on a device, which this checkout cannot do.
stage_device() {
  local archive ipa
  archive="$(engine_archive device)"
  S0_PROBE_ARCHIVE="${archive}" \
    S0_PROBE_HTTP_URL="$(probe_http_url)" S0_PROBE_HTTPS_URL="$(probe_https_url)" \
    "${CI_ROOT}/Tools/CI/scripts/build-app.sh" Debug device
  ipa="${EVIDENCE_ROOT}/s0-probe-debug-$(date -u +%Y%m%dT%H%M%SZ).ipa"
  "${CI_ROOT}/Tools/CI/scripts/package-ipa.sh" --configuration Debug "${ipa}"
  # The device fetches the plaintext URL from this machine, so serve it and say how the report
  # comes back without any device-side tool.
  start_http_server
  echo "[s0] device probe IPA: ${ipa}"
  echo "[s0] URLs embedded: $(probe_http_url) $(probe_https_url)"
  echo "[s0] this Mac must stay reachable at that LAN address while the device runs the probe"
  echo "[s0] on the device: install the IPA, turn on 允许完全访问 for 松烟, open 松烟 once"
  echo "[s0]   (it seeds the URLs), use the keyboard, open 松烟 again, then export with"
  echo "[s0]   Files → 松烟 → S0Probe; stop the server with: s0-probe.sh stop"
}

# A device probe run needs the plaintext server on its own, without a simulator.
stage_serve() {
  start_http_server
  echo "[s0] plaintext server: $(probe_http_url)"
}

# Collects the device's unified log for this probe. With 允许完全访问 off the extension cannot
# write the shared container, so no artifact JSON exists and the notice-level s0Probe lines are
# the only evidence. Device log collection needs root, so this step asks for sudo.
stage_device_log() {
  if [[ -z "${UDID:-}" ]]; then
    echo "[s0] set UDID to the device UDID; xcrun devicectl list devices lists them" >&2
    return 1
  fi
  local archive destination
  archive="${SCRATCH}/device.logarchive"
  destination="${EVIDENCE_ROOT}/$(date -u +%Y%m%dT%H%M%SZ).$$-device"
  mkdir -p "${destination}" "${SCRATCH}"
  rm -rf "${archive}"
  if ! sudo /usr/bin/log collect --device-udid "${UDID}" --last "${DEVICE_LOG_LAST}" --output "${archive}"; then
    echo "[s0] device log collection failed; run it yourself and keep the archive:" >&2
    echo "      sudo /usr/bin/log collect --device-udid ${UDID} --last ${DEVICE_LOG_LAST} --output ${archive}" >&2
    return 1
  fi
  /usr/bin/log show --archive "${archive}" --predicate "${DEVICE_PROBE_PREDICATE}" \
    --info --debug --style compact | grep 's0Probe' > "${destination}/probe-device.log" || true
  printf 'udid=%s\narchive=%s\nlast=%s\n' "${UDID}" "${archive}" "${DEVICE_LOG_LAST}" \
    > "${destination}/environment.txt"
  echo "[s0] device log lines: ${destination}/probe-device.log ($(wc -l < "${destination}/probe-device.log" | tr -d ' ') lines)"
  if [[ ! -s "${destination}/probe-device.log" ]]; then
    echo "[s0] no s0Probe lines in that window; widen DEVICE_LOG_LAST if the probe ran earlier" >&2
    return 1
  fi
}

stage_setup() {
  resolve_target
  local container domain address lan_url
  container="$(group_dir)"
  domain="${container}/Library/Preferences/${GROUP_ID}"
  mkdir -p "$(dirname "${domain}")"
  start_http_server
  # Evidence is collected from this moment on, so an earlier build's lines (paths, stale
  # results) cannot end up in this run's log files.
  # Local time: log show windows are interpreted in the host's timezone, not UTC.
  date '+%Y-%m-%d %H:%M:%S' > "${SCRATCH}/started-at"
  address="$(lan_address)"
  lan_url="http://${address}:${PORT}/plain.txt"
  write_shared_default "${domain}" debug.s0Probe bool YES
  write_shared_default "${domain}" debug.s0ProbeHTTPURL string "${lan_url}"
  write_shared_default "${domain}" debug.s0ProbeHTTPSURL string "${HTTPS_URL}"
  restart_extension
  echo "[s0] switches written: debug.s0Probe=YES lan=${lan_url} https=${HTTPS_URL}"
  echo "[s0] plaintext server pid $(cat "${SCRATCH}/http.pid") on ${address}:${PORT}"
}

stage_launch() {
  resolve_target
  # The host app writes the Keychain markers and runs the network control fetch. The launch
  # environment also enables the probe, so the host does not depend on the switch being read.
  SIMCTL_CHILD_SONGYAN_S0_PROBE=1 xcrun simctl launch --terminate-running-process "${UDID}" "${HOST_ID}" >/dev/null
  sleep 3
  echo "[s0] host app launched (Keychain markers written, control fetch done)"
}

stage_drive() {
  resolve_target
  if ! command -v axe >/dev/null; then
    echo "axe is required to drive the simulator" >&2
    exit 1
  fi
  # The 试打 row opens the typing area; the keyboard appears when its field takes focus.
  # A tap that does not resolve means the run is not measuring anything, so it is an error.
  if ! axe tap --label "试打" --udid "${UDID}" --tap-style physical >/dev/null; then
    echo "[s0] could not tap 试打; is the host app on its home screen?" >&2
    return 1
  fi
  sleep 1
  if ! axe tap --label "试打输入框" --udid "${UDID}" --tap-style physical >/dev/null; then
    echo "[s0] could not tap 试打输入框; the keyboard cannot be measured" >&2
    return 1
  fi
  sleep 3
  if ! extension_running; then
    echo "[s0] the Songyan keyboard is not running; open 试打 and pick 松烟 (long-press the globe key)" >&2
    return 1
  fi
  echo "[s0] keyboard running; text and selection callbacks only bump a counter (typed context is not sampled)"
}

# The extension process is named after its .appex bundle and runs from this simulator's
# device directory; another session's simulator must not count.
extension_running() {
  pgrep -f "CoreSimulator/Devices/${UDID}/.*KeyboardExtension.appex/KeyboardExtension" >/dev/null
}

stage_collect() {
  resolve_target
  local container destination
  container="$(group_dir)"
  destination="${EVIDENCE_ROOT}/$(date -u +%Y%m%dT%H%M%SZ).$$"
  mkdir -p "${destination}"
  local copied=0 artifact
  for artifact in "${container}"/Library/Caches/s0-probe-*.json; do
    [[ -e "${artifact}" ]] || continue
    cp "${artifact}" "${destination}/" || { echo "[s0] could not copy ${artifact}" >&2; return 1; }
    copied=$((copied + 1))
  done
  if ((copied == 0)); then
    echo "[s0] no probe artifacts in the App Group container; nothing was measured" >&2
    return 1
  fi
  # Debug-level lines (the keyboard's own hasFullAccess report) need --debug, and they live in
  # the in-memory store only, so they are usually absent from a persisted "log show" window.
  # The probe's notice lines carry the same fact and are always collected. The window starts at
  # the run's own setup time when it is known, so earlier runs cannot mix into these files.
  local window=(--last 15m)
  if [[ -s "${SCRATCH}/started-at" ]]; then
    window=(--start "$(cat "${SCRATCH}/started-at")")
  fi
  xcrun simctl spawn "${UDID}" log show "${window[@]}" --info --debug --style compact \
    --predicate 'category == "DebugProbe"' | grep 's0Probe' > "${destination}/probe.log" || true
  {
    # The keyboard's own debug line: reported verbatim, with its own wording.
    xcrun simctl spawn "${UDID}" log show "${window[@]}" --info --debug --style compact \
      --predicate 'category == "KeyboardExtension"' | grep 'hasFullAccess'
    # Probe lines keep their source event (context or network) and role; nothing is relabelled.
    sed -nE 's/.*s0Probe ([a-z]+) role=([A-Za-z]+).*fullAccess=([01]).*/s0Probe \1 role=\2 fullAccess=\3/p' \
      "${destination}/probe.log" | sort | uniq -c
  } > "${destination}/full-access.log" || true
  printf 'udid=%s\nsimulator=%s\ndate=%s\n' "${UDID}" "${SIM_NAME}" "$(date -u)" > "${destination}/environment.txt"
  COLLECTED_DIR="${destination}"
  echo "[s0] artifacts in ${destination} (${copied} file(s))"
  ls -la "${destination}"
  if [[ -s "${destination}/probe.log" ]]; then
    echo "[s0] probe lines by kind:"
    grep -oE 's0Probe [A-Za-z]+' "${destination}/probe.log" | sort | uniq -c || true
  else
    echo "[s0] WARNING: no s0Probe log lines in the collected window" >&2
  fi
  if [[ ! -s "${destination}/full-access.log" ]]; then
    echo "[s0] WARNING: no Full Access record in the collected window" >&2
  else
    echo "[s0] full-access.log:"
    cat "${destination}/full-access.log"
  fi
}

# Runs the controlled input fixture instead of driving the keyboard: an S0 probe build started
# with SONGYAN_S0_INPUT_PROBE=1 opens a fixed text field that steps through known text and
# selection states and logs one marker per step, so the extension's context samples can be read
# against expected lengths without typing into the keyboard.
stage_fixture() {
  resolve_target
  SIMCTL_CHILD_SONGYAN_S0_INPUT_PROBE=1 xcrun simctl launch --terminate-running-process \
    "${UDID}" "${HOST_ID}" >/dev/null
  echo "[s0] input fixture launched; waiting for its steps"
  # The fixture only proves anything if the extension under test actually ran; a missing
  # keyboard (another keyboard selected, hardware keyboard connected) is reported, not ignored.
  local waited=0
  while ((waited < 20)) && ! extension_running; do
    sleep 1
    waited=$((waited + 1))
  done
  if ! extension_running; then
    echo "[s0] the Songyan keyboard never started for the fixture; no sample can be trusted" >&2
    return 1
  fi
  sleep 12
  stage_collect
  # The fixture run only counts when the extension actually answered each step with the
  # expected lengths; a wrong build, a missing sample or a mismatch fails here.
  python3 "${CI_ROOT}/Tools/CI/scripts/s0-verify-fixture.py" "${COLLECTED_DIR}"
}

stage_stop() {
  stop_http_server
  require_xcode >/dev/null
  UDID="$(resolve_sim_udid)"
  # A device-only operator has no staged simulator app; the server still has to stop.
  if [[ -z "${UDID}" ]] || ! resolve_sim_identity >/dev/null 2>&1; then
    echo "[s0] server stopped; no staged app, so there were no simulator switches to remove"
    return
  fi
  local container domain
  container="$(group_dir)"
  domain="${container}/Library/Preferences/${GROUP_ID}"
  delete_shared_default "${domain}" debug.s0Probe
  delete_shared_default "${domain}" debug.s0ProbeHTTPURL
  delete_shared_default "${domain}" debug.s0ProbeHTTPSURL
  restart_extension
  echo "[s0] switches removed, server stopped"
}

main() {
  case "${1:-}" in
    quickjs) stage_quickjs ;;
    device) stage_device ;;
    serve) stage_serve ;;
    device-log) stage_device_log ;;
    setup) stage_setup ;;
    fixture)
      cleanup_run() { stage_stop >/dev/null 2>&1 || true; }
      trap cleanup_run EXIT INT TERM
      stage_setup
      stage_fixture
      ;;
    launch) stage_launch ;;
    drive) stage_drive ;;
    collect) stage_collect ;;
    stop) stage_stop ;;
    run)
      # The switches and the plaintext server must never outlive the run, including on failure.
      cleanup_run() { stage_stop >/dev/null 2>&1 || true; }
      trap cleanup_run EXIT INT TERM
      stage_quickjs
      stage_setup
      stage_launch
      stage_drive
      stage_collect
      ;;
    *) usage ;;
  esac
}

main "$@"
