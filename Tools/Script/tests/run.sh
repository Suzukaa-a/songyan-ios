#!/usr/bin/env bash
# Behaviour tests for the shared script contract: golden JSON per case, plus the command-line
# behaviour that keeps unset limits out of the contract. The cases and expectations are the shared
# artefacts both platforms run; a case without script.js is fed from examples/<name>.js, which is
# how the shipped minimal example is tested as the real input.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../../.." && pwd)"
BIN="${1:-${ROOT}/.local/script-cli/songyan-script}"
FAULTS="${2:-}"
TRASH="${HERE}/../scripts/trash.sh"
# Temporary files follow the repository rule and live under .scratch/. Each run gets its own
# directory created by mktemp, and clean-up moves only that directory to the Trash, so a parallel
# run or an older leftover is never touched.
mkdir -p "${ROOT}/.scratch"
SCRATCH="$(mktemp -d "${ROOT}/.scratch/script-contract.XXXXXX")"
trap '"${TRASH}" "${SCRATCH}" >/dev/null 2>&1 || true' EXIT

passed=0
failed=0
pass() { passed=$((passed + 1)); }
fail() {
  printf 'FAIL %s\n' "$*" >&2
  failed=$((failed + 1))
}

[[ -x "${BIN}" ]] || {
  echo "missing checker binary: ${BIN} (run make)" >&2
  exit 1
}

run_case() {
  local description="$1" script="$2" capabilities="$3" expected="$4"
  local expected_status=0
  grep -q '"ok": false' "${expected}" && expected_status=1
  local status=0
  set +e
  "${BIN}" header --script "${script}" --capabilities "${capabilities}" >"${SCRATCH}/actual.json"
  status=$?
  set -e
  if [[ "${status}" -ne "${expected_status}" ]]; then
    fail "${description}: exit ${status}, expected ${expected_status}"
    return
  fi
  if ! diff -u "${expected}" "${SCRATCH}/actual.json"; then
    fail "${description}: output differs from ${expected}"
    return
  fi
  pass
}

for case_dir in "${HERE}"/cases/*/; do
  name="$(basename "${case_dir}")"
  capabilities="text"
  [[ -f "${case_dir}capabilities.txt" ]] &&
    capabilities="$(tr -d '[:space:]' <"${case_dir}capabilities.txt")"
  script="${case_dir}script.js"
  [[ -f "${script}" ]] || script="${HERE}/../examples/${name}.js"
  run_case "case ${name}" "${script}" "${capabilities}" "${case_dir}expected.json"
done

expect_exit() {
  local expected="$1" description="$2"
  shift 2
  local status=0
  set +e
  "$@" >"${SCRATCH}/stdout" 2>"${SCRATCH}/stderr"
  status=$?
  set -e
  if [[ "${status}" -ne "${expected}" ]]; then
    fail "${description}: exit ${status}, expected ${expected}"
    return
  fi
  pass
}

# Usage and limit problems stay on the command line, not in the contract error codes.
MINIMAL="${HERE}/../examples/minimal.js"
expect_exit 64 "no arguments" "${BIN}"
expect_exit 64 "header without --script" "${BIN}" header
expect_exit 64 "header with an unknown flag" "${BIN}" header --script "${MINIMAL}" --wat
expect_exit 64 "unknown capability" "${BIN}" header --script "${MINIMAL}" --capabilities text,eyes
expect_exit 64 "missing script file" "${BIN}" header --script "${SCRATCH}/absent.js"
expect_exit 64 "unknown command" "${BIN}" deploy

# Limits have no defaults: a host that injects nothing is refused and told what is missing.
expect_exit 64 "limits without any value" "${BIN}" limits
grep -q '"limitsNotInjected"' "${SCRATCH}/stdout" || fail "limits refusal is not reported as JSON"
grep -q '"heapBytes"' "${SCRATCH}/stdout" || fail "limits refusal does not name the missing fields"

expect_exit 64 "limits with a zero field" "${BIN}" limits \
  --source-bytes 1048576 --heap-bytes 0 --duration-ms 4000 --compute-ms 4000 \
  --request-count 4 --response-bytes 1048576 --input-text-bytes 20000

expect_exit 0 "limits fully injected" "${BIN}" limits \
  --source-bytes 1048576 --heap-bytes 8388608 --duration-ms 4000 --compute-ms 4000 \
  --request-count 4 --response-bytes 1048576 --input-text-bytes 20000
grep -q '"sourceBytes": 1048576' "${SCRATCH}/stdout" || fail "limits echo lost sourceBytes"
grep -q '"durationMs": 4000' "${SCRATCH}/stdout" || fail "limits echo lost durationMs"
grep -q '"computeMs": 4000' "${SCRATCH}/stdout" || fail "limits echo lost computeMs"

expect_exit 64 "limits with a uint32 overflow" "${BIN}" limits \
  --source-bytes 1048576 --heap-bytes 1048576 --duration-ms 4294967296 --compute-ms 4000 \
  --request-count 4 --response-bytes 1048576 --input-text-bytes 20000
expect_exit 64 "limits with a size overflow" "${BIN}" limits \
  --source-bytes 18446744073709551616 --heap-bytes 1048576 --duration-ms 4000 --compute-ms 4000 \
  --request-count 4 --response-bytes 1048576 --input-text-bytes 20000

# The address rule table is shared with every platform implementation.
while IFS= read -r line; do
  [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue
  expected="${line%% *}"
  rest="${line#* }"
  url="$(sed 's/^ *//; s/ *|.*$//' <<<"${rest}")"
  connects="$(cut -d'|' -f2 <<<"${rest}")"
  settings="$(cut -d'|' -f3 <<<"${rest}")"
  args=(address --url "${url}")
  for host in ${connects}; do args+=(--connect "${host}"); done
  if [[ -n "${settings// /}" ]]; then
    settings="$(sed 's/^ *//; s/ *$//' <<<"${settings}")"
    for value in ${settings}; do args+=(--setting-url "${value}"); done
  fi
  actual="$("${BIN}" "${args[@]}")"
  if [[ "${actual}" == "${expected}" ]]; then pass; else fail "address ${url}: ${actual}, expected ${expected}"; fi
done <"${HERE}/address-cases.txt"

# The public parser is also exercised with forced allocation failures and byte-level boundaries.
[[ -x "${FAULTS}" ]] && expect_exit 0 "allocation failure cleanup" "${FAULTS}"

expect_exit 0 "header help" "${BIN}" --help

# Every example in a platform's final AI guide must import on that platform: iOS ships
# ai-guide.txt alone and offers text only; Android appends ai-guide-audio.txt and offers audio too.
# An example starts at a "// @api" line and runs to the next blank line.
check_guide() {
  local platform="$1" capabilities="$2"
  shift 2
  local guide="${SCRATCH}/guide-${platform}.txt"
  cat "$@" >"${guide}"
  awk -v prefix="${SCRATCH}/${platform}-example-" '
    /^\/\/ @api / && out == "" { count++; out = prefix count ".js" }
    out != "" && /^$/ { close(out); out = ""; next }
    out != "" { print > out }
  ' "${guide}"
  local examples=("${SCRATCH}/${platform}-example-"*.js)
  [[ -f "${examples[0]}" ]] || { fail "${platform} guide has no examples"; return; }
  local example status
  for example in "${examples[@]}"; do
    set +e
    "${BIN}" header --script "${example}" --capabilities "${capabilities}" >"${SCRATCH}/guide.json"
    status=$?
    set -e
    if [[ "${status}" -ne 0 ]]; then
      fail "${platform} guide $(basename "${example}"): header refused"
    elif ! tr -d ' \n' <"${SCRATCH}/guide.json" | grep -q '"missing":\[\]'; then
      fail "${platform} guide $(basename "${example}"): needs a capability ${platform} lacks"
    else
      pass
    fi
  done
}
RESOURCES="${HERE}/../resources"
check_guide ios text "${RESOURCES}/ai-guide.txt"
check_guide android text,audio "${RESOURCES}/ai-guide.txt" "${RESOURCES}/ai-guide-audio.txt"

printf 'contract tests: %d passed, %d failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]
