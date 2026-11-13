"""Full configuration restore and UI smoke test; requires an isolated booted simulator."""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    args = parser.parse_args()
    devices = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "--json"], capture_output=True).stdout)
    if not any(d["udid"] == args.simulator and d["state"] == "Booted" for group in devices["devices"].values() for d in group):
        parser.error("a booted, isolated simulator is required")
    work = Path(tempfile.mkdtemp(prefix="configuration-backup-", dir=ROOT / ".scratch"))
    project = work / "Songyan.xcodeproj"
    shutil.copytree(ROOT / "Songyan.xcodeproj", project)
    data = json.loads(run(["plutil", "-convert", "json", "-o", "-", str(project / "project.pbxproj")], capture_output=True).stdout)
    source = (ROOT / "Apps/HostApp/HostApp.swift").read_text().replace("\n@main\n", "\n", 1)
    source += "\n" + (ROOT / "Tests/IOS/Fixtures/ConfigurationBackupProbe.swift").read_text()
    (work / "HostApp.swift").write_text(source)
    for obj in data["objects"].values():
        if obj["isa"] == "PBXProject":
            group = data["objects"][obj["mainGroup"]]
            group.update(path=str(ROOT), sourceTree="<absolute>")
        if obj["isa"] == "XCLocalSwiftPackageReference":
            obj["relativePath"] = str(ROOT / obj["relativePath"])
        if obj["isa"] == "PBXFileReference" and obj.get("path") == "HostApp.swift":
            obj.update(path=str(work / "HostApp.swift"), sourceTree="<absolute>")
        if obj["isa"] == "XCBuildConfiguration":
            for key in ["CODE_SIGN_ENTITLEMENTS", "INFOPLIST_FILE", "SWIFT_OBJC_BRIDGING_HEADER"]:
                if obj["buildSettings"].get(key):
                    obj["buildSettings"][key] = str(ROOT / obj["buildSettings"][key])
    (project / "project.pbxproj").write_bytes(plistlib.dumps(data))
    derived = ROOT / ".local/ci/configuration-backup-derived"
    print(f"Backup verification: {work}", flush=True)
    with (work / "build.log").open("w") as log:
        run(["xcodebuild", "-project", str(project), "-scheme", "HostApp", "-configuration", "Debug",
             "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator",
             "-derivedDataPath", str(derived), "-jobs", "4", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES",
             "CODE_SIGNING_REQUIRED=NO", "DEVELOPMENT_TEAM=", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
             f"SRCROOT={ROOT}", "build"], stdout=log, stderr=subprocess.STDOUT,
            env={**os.environ, "CFFIXED_USER_HOME": str(work / "home")})
    run(["xcrun", "simctl", "install", args.simulator, str(derived / "Build/Products/Debug-iphonesimulator/HostApp.app")])
    container = Path(run(["xcrun", "simctl", "get_app_container", args.simulator, "app.songyan.ime", "data"], capture_output=True).stdout.strip())
    report = container / "Documents/configuration-backup-report.json"
    report.unlink(missing_ok=True)
    run(["xcrun", "simctl", "launch", "--terminate-running-process", args.simulator, "app.songyan.ime"])
    deadline = time.monotonic() + 120
    while not report.exists() and time.monotonic() < deadline:
        time.sleep(0.2)
    if not report.exists():
        raise RuntimeError("No verification report was produced")
    shutil.copy2(report, work / report.name)
    result = json.loads(report.read_text())
    print(json.dumps(result, ensure_ascii=False, indent=2))
    assert result["passed"], result
    run(["xcrun", "simctl", "io", args.simulator, "screenshot", str(work / "backup-page.png")])


if __name__ == "__main__":
    main()
