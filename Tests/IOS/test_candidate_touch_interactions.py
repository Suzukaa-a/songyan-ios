"""Real UIKit/SwiftUI touch regressions against the production candidate renderer.

Explicit entry only (a dedicated, booted simulator is required):
    python3 Tests/IOS/test_candidate_touch_interactions.py --simulator <UDID>

Tests use a deterministic engine and code queue to put refreshes between finger
down/up. They cover re-ranking that removes a held cell, pending final letters,
small movement, actual native scrolling, and failed-action feedback. No physical
device is accepted. Logs and the generated Xcode project stay under .scratch.

Use --production-keyboard after staging the real app on an isolated simulator
with the Songyan keyboard enabled, onboarding complete, Simplified Chinese,
and the built-in full-pinyin scheme selected. It tests actual Rime commits into
the host app's text view rather than the deterministic probe engine.
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "Tests/IOS/Fixtures/CandidateTouchProbe"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--only-testing", action="append", default=[])
    parser.add_argument("--optimized", action="store_true", help="exercise shipping Swift optimization")
    parser.add_argument("--production-keyboard", action="store_true",
                        help="test the already staged Songyan keyboard extension")
    options = parser.parse_args()
    devices = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
    simulator = next((device for group in devices["devices"].values() for device in group
                      if device["udid"] == options.simulator), None)
    if simulator is None or simulator["state"] != "Booted":
        parser.error("--simulator must identify a booted simulator, never a physical device")
    if options.production_keyboard:
        subprocess.run(["xcrun", "simctl", "get_app_container", options.simulator,
                        "app.songyan.ime", "app"], check=True, stdout=subprocess.DEVNULL)
    scratch = ROOT / ".scratch"
    scratch.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="candidate-touch-", dir=scratch))
    shutil.copy2(FIXTURE / "Probe.swift", work / "Probe.swift")
    test_source = "ProductionKeyboardTests.swift" if options.production_keyboard else "ProbeTests.swift"
    shutil.copy2(FIXTURE / test_source, work / "ProbeTests.swift")
    subprocess.run([sys.executable, str(FIXTURE / "create_project.py"), str(work)], check=True)
    command = ["xcodebuild", "-project", str(work / "CandidateProbe.xcodeproj"),
               "-scheme", "CandidateProbe", "-sdk", "iphonesimulator",
               "-destination", f"platform=iOS Simulator,id={options.simulator}",
               "-derivedDataPath", str(ROOT / ".local/ci/candidate-race-derived"),
               "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "-parallel-testing-enabled", "NO"]
    command += [f"-only-testing:{test}" for test in options.only_testing]
    if options.optimized:
        command += ["SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule"]
    command.append("test")
    print(f"Touch regression log: {work / 'test.log'}", flush=True)
    with (work / "test.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    print(f"Touch regression exit: {result.returncode}")
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
