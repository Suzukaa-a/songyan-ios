#!/usr/bin/env python3
"""Compile actual Hans package catalogs for flat native harnesses.

Usage: build-harness-resources.py OUTPUT_DIRECTORY
"""
import json
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[3]
out = pathlib.Path(sys.argv[1]).resolve()
bundle = out / "HarnessResources.bundle"
bundle.mkdir(parents=True, exist_ok=True)
(bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleDevelopmentRegion": "zh-Hans"}))
strings = {}
for catalog in sorted((root / "Packages").glob("*/Sources/*/Resources/*.xcstrings")):
    for key, entry in json.loads(catalog.read_text())["strings"].items():
        source = entry.get("localizations", {}).get("zh-Hans")
        if source:
            strings[key] = {"localizations": {"zh-Hans": source}}
catalog = out / "HarnessResources.xcstrings"
catalog.write_text(json.dumps({"sourceLanguage": "zh-Hans", "strings": strings, "version": "1.0"}))
subprocess.run(["xcrun", "xcstringstool", "compile", str(catalog), "--output-directory", str(bundle)], check=True)
(out / "HarnessResources.swift").write_text(
    "import Foundation\nextension Bundle { static let module = Bundle(path: "
    + json.dumps(str(bundle)) + ")! }\n")
