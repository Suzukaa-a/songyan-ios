#!/usr/bin/env python3
"""Checks the S0 input-context fixture run against the lengths it is supposed to produce.

The fixture (SONGYAN_S0_INPUT_PROBE=1 in an S0 probe build) walks a fixed text field through
known text and selection states and logs one "s0Probe inputFixture step=..." marker per step.
The extension logs one coalesced context sample per burst. This script connects the two by log
order - the sample that follows each marker and precedes the next one belongs to that step - and
compares the recorded lengths with the expected values. It never assumes a fixed delay, so a
slow build cannot pass by timing luck, and it never reads user text: only the probe's numeric
fields are compared.

Failures are explicit and distinct:
  2  no readable probe log (the log file is missing or empty)
  3  no s0Probe lines at all in the window (no access to the log or the run produced nothing)
  4  no fixture markers (not an S0 probe build, or the fixture never started)
  5  a step has no complete sample (extension never answered, or its process was not running)
  6  expected and recorded lengths disagree (table printed)
  0  every step matched

Usage: s0-verify-fixture.py <evidence directory or log file> [--verbose]
"""

import pathlib
import re
import sys

# Kept in step with S0InputProbeView.steps in Apps/HostApp/HostApp.swift; a fixture change must
# update both. Values are lengths and paths only, never text.
EXPECTED = {
    "empty": {"hasText": 0, "selectedNil": 1, "beforeNil": 1, "afterNil": 1},
    "ascii-end": {
        "hasText": 1, "beforeChars": 6, "beforeUTF16": 6, "selectedNil": 1, "afterNil": 1,
    },
    "ascii-middle": {
        "beforeChars": 3, "beforeUTF16": 3, "afterChars": 3, "afterNil": 0,
    },
    "ascii-selection": {
        "selectedNil": 0, "selectedChars": 3, "selectedUTF16": 3,
        "beforeChars": 2, "beforeUTF16": 2, "afterChars": 1, "afterNil": 0,
    },
    "cjk-end": {"beforeChars": 5, "beforeUTF16": 5, "afterNil": 1},
}
# No sensitive-field step: iOS shows the system keyboard for secure-entry and password
# content-type fields, so the extension never runs there and a skip log cannot be observed. The
# fixture therefore covers only the states a custom keyboard actually receives.
FIELDS = (
    "selectedNil", "selectedChars", "selectedUTF16",
    "beforeNil", "beforeChars", "beforeUTF16",
    "afterNil", "afterChars", "afterUTF16", "hasText",
)
MARKER = re.compile(r"s0Probe inputFixture step=(\S+)")
SAMPLE = re.compile(r"s0Probe context role=keyboardExtension event=(\S+)")
FIELD = re.compile(r"\b(" + "|".join(FIELDS) + r")=(-?\d+)")


def fail(code, message):
    print(f"[s0-verify] FAIL: {message}", file=sys.stderr)
    raise SystemExit(code)


def read_log(target):
    path = pathlib.Path(target)
    if path.is_dir():
        path = path / "probe.log"
    if not path.is_file():
        fail(2, f"no probe log at {path}")
    text = path.read_text(encoding="utf-8", errors="replace")
    if not text.strip():
        fail(2, f"probe log at {path} is empty")
    return path, [line for line in text.splitlines() if "s0Probe" in line]


def sample_fields(line):
    return {name: int(value) for name, value in FIELD.findall(line)}


def main():
    if len(sys.argv) < 2:
        print("usage: s0-verify-fixture.py <evidence directory or log file> [--verbose]", file=sys.stderr)
        raise SystemExit(64)
    path, lines = read_log(sys.argv[1])
    if not lines:
        fail(3, f"no s0Probe lines in {path}: no access to the log, or the run produced nothing")

    markers = [(index, MARKER.search(line).group(1)) for index, line in enumerate(lines) if MARKER.search(line)]
    if not markers:
        fail(
            4,
            f"no fixture markers in {path}: this is not an S0 probe build, or the fixture did not start",
        )
    names = [name for _, name in markers]
    missing = [name for name in EXPECTED if name not in names]
    if missing:
        fail(4, f"fixture markers missing steps {missing}: the fixture did not run to its end")

    if not any(SAMPLE.search(line) for line in lines):
        fail(5, "no extension context samples: the keyboard extension never answered")

    step_results = []
    for position, (start, name) in enumerate(markers):
        end = markers[position + 1][0] if position + 1 < len(markers) else len(lines)
        window = lines[start + 1:end]
        if name not in EXPECTED:
            fail(4, f"unknown fixture step {name!r}")
        samples = [line for line in window if SAMPLE.search(line) and sample_fields(line)]
        if not samples:
            fail(5, f"step {name!r} has no complete context sample before the next step")
        actual = sample_fields(samples[0])
        mismatches = [
            (key, value, actual.get(key)) for key, value in EXPECTED[name].items()
            if actual.get(key) != value
        ]
        step_results.append((name, "matched" if not mismatches else "mismatch", mismatches))

    bad = [result for result in step_results if result[2]]
    print(f"[s0-verify] log {path}")
    for name, verdict, mismatches in step_results:
        print(f"[s0-verify] step {name:<15} {verdict}")
        for key, expected, actual in mismatches:
            print(f"[s0-verify]   {key}: expected {expected}, got {actual}")
    if bad:
        fail(6, f"{len(bad)} fixture step(s) disagree with the expected lengths")
    print("[s0-verify] PASS: every fixture step matched the expected lengths")


if __name__ == "__main__":
    main()
