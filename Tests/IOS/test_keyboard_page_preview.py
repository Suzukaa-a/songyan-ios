"""Compare production letter/symbol rendering with previews on an isolated simulator.

Explicit entry: python3 Tests/IOS/test_keyboard_page_preview.py --simulator <booted UDID>
The generated project keeps all production views and only replaces the app entry and the
initial panel page. It never installs or launches on a physical device.
"""
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


def compare_keys(expected, actual, context, scale=1):
    """Compare physical keys and visible labels, allowing only subpixel rounding."""
    if not expected or len(expected) != len(actual):
        raise AssertionError(f"{context}: key count {len(actual)} != {len(expected)}")
    def ordered(keys, factor):
        return sorted(keys, key=lambda key: (round(key["y"] / factor, 1), key["x"]))

    # Row ordering, unlike an element's view-tree position, survives native/authored renderers.
    for index, (left, right) in enumerate(zip(ordered(expected, 1), ordered(actual, scale))):
        if left["text"] != right["text"]:
            raise AssertionError(f"{context}, key {index}: {right['text']} != {left['text']}")
        for field in ["x", "y", "width", "height"]:
            if abs(left[field] - right[field] / scale) > 1:
                raise AssertionError(
                    f"{context}, key {index}, {field}: {right[field] / scale:.2f} != {left[field]:.2f}")


def verify(result):
    cases = {case["name"]: case for case in result["cases"]}
    if len(cases) != 18:
        raise AssertionError(f"expected 18 rendering cases, received {len(cases)}")
    for name, case in cases.items():
        for surface in ["preview", "inset", "editing"]:
            if surface in case:
                compare_keys(case["actual"], case[surface], f"{name}/{surface}",
                             case["insetScale"] if surface == "inset" else 1)
        print(f"{name}: actual/preview/editing key geometry and labels match")
    for width in [402, 600]:
        for original, copy in [("automatic", "copied"), ("automatic-ascii", "copied-ascii"),
                               ("categories", "copied-categories"), ("categories", "automatic-phone")]:
            compare_keys(cases[f"{original}-{width}"]["actual"], cases[f"{copy}-{width}"]["actual"],
                         f"{original}/{copy}-{width}")
    print("Native copies preserve key geometry and labels; inset previews preserve proportions.")
    letters = result["letterCases"]
    assert len(letters) == 12
    for case in letters:
        for surface in ["preview", "editing"]:
            compare_keys(case["actual"], case[surface], f"{case['name']}/{surface}")
        first_y = min(key["y"] for key in case["actual"])
        first = sorted([key for key in case["actual"] if abs(key["y"]-first_y)<1], key=lambda key: key["x"])
        assert len(first) == 10, case["name"]
        gap = first[1]["x"] - first[0]["x"] - first[0]["width"]
        assert 0.18 < gap / first[0]["width"] < 0.22, (case["name"], gap, first[0]["width"])
        assert abs(first[0]["height"] - (38 if case["compact"] else 48)) < 1, case["name"]
        print(f"{case['name']}: runtime, preview and editing match; automatic cap size and gap passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    args = parser.parse_args()
    devices = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "--json"],
                             capture_output=True).stdout)
    if not any(d["udid"] == args.simulator and d["state"] == "Booted"
               for group in devices["devices"].values() for d in group):
        parser.error("a booted, isolated simulator is required")
    (ROOT / ".scratch").mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="page-preview-", dir=ROOT / ".scratch"))
    project = work / "Songyan.xcodeproj"
    shutil.copytree(ROOT / "Songyan.xcodeproj", project)
    original = ROOT / "Songyan.xcodeproj/project.pbxproj"
    data = json.loads(run(["plutil", "-convert", "json", "-o", "-", str(original)], capture_output=True).stdout)
    host = (ROOT / "Apps/HostApp/HostApp.swift").read_text().replace("\n@main\n", "\n", 1)
    host += "\n" + (ROOT / "Tests/IOS/Fixtures/KeyboardPagePreviewProbe.swift").read_text()
    (work / "HostApp.swift").write_text(host)
    panel = (ROOT / "Apps/SharedKeyboard/KeyboardPanelView.swift").read_text()
    panel += "\n@MainActor enum PagePreviewStart { static var page: KeyboardPage = .symbols }\n"
    seed = ".onAppear { syncHostPage() }"
    assert panel.count(seed) == 1
    # The panel reconciles its main definition on appearance, resetting the active page.
    # Open symbols after that lifecycle step, without replacing any rendering rules.
    (work / "KeyboardPanelView.swift").write_text(panel.replace(
        seed, seed + "\n.task { try? await Task.sleep(for: .milliseconds(100)); page = PagePreviewStart.page }"))
    for obj in data["objects"].values():
        if obj["isa"] == "PBXProject":
            group = data["objects"][obj["mainGroup"]]
            group["path"] = str(ROOT)
            group["sourceTree"] = "<absolute>"
        if obj["isa"] == "XCLocalSwiftPackageReference":
            obj["relativePath"] = str(ROOT / obj["relativePath"])
        if obj["isa"] == "PBXFileReference" and obj.get("path") in {"HostApp.swift", "KeyboardPanelView.swift"}:
            obj["path"] = str(work / obj["path"])
            obj["sourceTree"] = "<absolute>"
        if obj["isa"] == "XCBuildConfiguration":
            settings = obj["buildSettings"]
            for key in ["CODE_SIGN_ENTITLEMENTS", "INFOPLIST_FILE", "SWIFT_OBJC_BRIDGING_HEADER"]:
                if settings.get(key):
                    settings[key] = str(ROOT / settings[key])
    (project / "project.pbxproj").write_bytes(plistlib.dumps(data))
    derived = ROOT / ".local/ci/page-preview-derived"
    command = ["xcodebuild", "-project", str(project), "-scheme", "HostApp", "-configuration", "Debug",
               "-sdk", "iphonesimulator", "-destination", "generic/platform=iOS Simulator",
               "-derivedDataPath", str(derived), "-jobs", "4", "CODE_SIGN_IDENTITY=-",
               "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=NO", "DEVELOPMENT_TEAM=",
               "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", f"SRCROOT={ROOT}", "build"]
    print(f"Page preview verification: {work}", flush=True)
    with (work / "build.log").open("w") as log:
        run(command, stdout=log, stderr=subprocess.STDOUT, env={**os.environ, "CFFIXED_USER_HOME": str(work / "home")})
    app = derived / "Build/Products/Debug-iphonesimulator/HostApp.app"
    run(["xcrun", "simctl", "install", args.simulator, str(app)])
    container = Path(run(["xcrun", "simctl", "get_app_container", args.simulator, "app.songyan.ime", "data"],
                         capture_output=True).stdout.strip())
    report = container / "Documents/page-preview-report.json"
    report.unlink(missing_ok=True)
    run(["xcrun", "simctl", "launch", "--terminate-running-process", args.simulator, "app.songyan.ime"])
    deadline = time.monotonic() + 180
    while not report.exists() and time.monotonic() < deadline:
        time.sleep(0.2)
    if not report.exists():
        raise RuntimeError("the rendering probe did not publish its report")
    result = json.loads(report.read_text())
    for path in report.parent.glob("*.png"):
        shutil.copy2(path, work / path.name)
    shutil.copy2(report, work / report.name)
    if "error" in result:
        raise RuntimeError(result["error"])
    verify(result)


if __name__ == "__main__":
    main()
