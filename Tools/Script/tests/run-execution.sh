#!/usr/bin/env bash
# Behaviour tests for script execution: every case runs the real engine through the command-line
# runner and its stdout is diffed against expected.json. A case is a directory:
#
#   script.js        the script; when absent, examples/<case name>.js is used (so the shipped
#                    minimal example is a case input, not a copy)
#   scripts.txt      one script path per line, for cases that need more than one run in one process
#   input.txt        raw input text (absent means no text)
#   settings.json    user settings and secrets passed as the settings object
#   capabilities.txt "text" or "text,audio"; default "text"
#   limits.txt       key=value overrides for the six injected limits
#   fetch.txt        fixture responses and address rules for the fake host
#   expected.json    the canonical stdout; "ok": false at the top level means exit 1 and
#                    "cliError" means exit 64 (a caller mistake, not a script error)
#
# The limits default to fixed test values; the production values come from S0 headroom and are
# injected by the hosts, so no number here is a shipped policy.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../.." && pwd)"
BIN="${1:-${ROOT}/.local/script-cli/songyan-script}"
TRASH="${HERE}/../scripts/trash.sh"
mkdir -p "${ROOT}/.scratch"
SCRATCH="$(mktemp -d "${ROOT}/.scratch/script-execution.XXXXXX")"
trap '"${TRASH}" "${SCRATCH}" >/dev/null 2>&1 || true' EXIT

passed=0
failed=0
pass() { passed=$((passed + 1)); }
fail() {
  printf 'FAIL %s\n' "$*" >&2
  failed=$((failed + 1))
}

[[ -x "${BIN}" ]] || {
  echo "missing runner binary: ${BIN} (run make)" >&2
  exit 1
}

default_source_bytes=1048576
default_heap_bytes=8388608
default_duration_ms=4000
default_compute_ms=4000
default_request_count=8
default_response_bytes=1048576
default_input_text_bytes=20000

for case_dir in "${HERE}"/execution/cases/*/; do
  name="$(basename "${case_dir}")"
  args=(run)
  if [[ -f "${case_dir}scripts.txt" ]]; then
    while IFS= read -r relative; do
      [[ -z "${relative}" ]] && continue
      args+=(--script "${case_dir}${relative}")
    done <"${case_dir}scripts.txt"
  elif [[ -f "${case_dir}script.js" ]]; then
    args+=(--script "${case_dir}script.js")
  else
    args+=(--script "${HERE}/../examples/${name}.js")
  fi
  [[ -f "${case_dir}input.txt" ]] && args+=(--text-file "${case_dir}input.txt")
  [[ -f "${case_dir}settings.json" ]] && args+=(--settings-file "${case_dir}settings.json")
  [[ -f "${case_dir}fetch.txt" ]] && args+=(--fetch "${case_dir}fetch.txt")
  [[ -f "${case_dir}logLimit.txt" ]] &&
    args+=(--log-limit "$(tr -d '[:space:]' <"${case_dir}logLimit.txt")")
  [[ -f "${case_dir}cancel.txt" ]] && args+=(--cancel-pending)
  [[ -f "${case_dir}hostWait.txt" ]] &&
    args+=(--host-wait-ms "$(tr -d '[:space:]' <"${case_dir}hostWait.txt")")
  capabilities="text"
  [[ -f "${case_dir}capabilities.txt" ]] &&
    capabilities="$(tr -d '[:space:]' <"${case_dir}capabilities.txt")"
  args+=(--capabilities "${capabilities}")

  source_bytes="${default_source_bytes}"
  heap_bytes="${default_heap_bytes}"
  duration_ms="${default_duration_ms}"
  compute_ms="${default_compute_ms}"
  request_count="${default_request_count}"
  response_bytes="${default_response_bytes}"
  input_text_bytes="${default_input_text_bytes}"
  if [[ -f "${case_dir}limits.txt" ]]; then
    while IFS='=' read -r key value; do
      [[ -z "${key}" || "${key:0:1}" == "#" ]] && continue
      case "${key}" in
      sourceBytes) source_bytes="${value}" ;;
      heapBytes) heap_bytes="${value}" ;;
      durationMs) duration_ms="${value}" ;;
      computeMs) compute_ms="${value}" ;;
      requestCount) request_count="${value}" ;;
      responseBytes) response_bytes="${value}" ;;
      inputTextBytes) input_text_bytes="${value}" ;;
      *)
        fail "${name}: unknown limit ${key}"
        continue
        ;;
      esac
    done <"${case_dir}limits.txt"
  fi
  args+=(--source-bytes "${source_bytes}" --heap-bytes "${heap_bytes}"
    --duration-ms "${duration_ms}" --compute-ms "${compute_ms}" --request-count "${request_count}"
    --response-bytes "${response_bytes}" --input-text-bytes "${input_text_bytes}")

  status=0
  set +e
  "${BIN}" "${args[@]}" >"${SCRATCH}/actual.json" 2>"${SCRATCH}/stderr"
  status=$?
  set -e
  if [[ "${UPDATE:-0}" == "1" ]]; then
    # Explicit update mode for adding a case: review the new file before committing it. The
    # default run never writes expectations.
    cp "${SCRATCH}/actual.json" "${case_dir}expected.json"
    pass
    continue
  fi

  expected_status=0
  grep -q '"cliError"' "${case_dir}expected.json" && expected_status=64
  if [[ "${expected_status}" -eq 0 ]] && grep -q '"ok": false' "${case_dir}expected.json"; then
    expected_status=1
  fi
  if [[ "${status}" -ne "${expected_status}" ]]; then
    fail "${name}: exit ${status}, expected ${expected_status}"
    sed -n '1,20p' "${SCRATCH}/stderr" >&2
    continue
  fi
  if ! diff -u "${case_dir}expected.json" "${SCRATCH}/actual.json"; then
    fail "${name}: output differs from expected.json"
    continue
  fi
  pass
done

printf 'execution tests: %d passed, %d failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]
