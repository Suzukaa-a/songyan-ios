#!/usr/bin/env python3
"""A built app must ship the SwiftPM resource bundles that `Bundle.module` resolves at runtime.

A statically linked package finds its resources in `<Package>_<Target>.bundle` next to the
executable; a missing bundle traps on first use. The check inspects the newest unsigned Debug or
Release build under `.local/ci/app-builds` and is skipped when no build exists (fast CI has none).
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILDS = ROOT / ".local/ci/app-builds"
# The keyboard extension links these packages; PackageManager is host-app only.
EXTENSION_PACKAGES = ["AppearanceKit", "CandidateKit", "KeyboardCore", "LayoutKit", "QuickContentKit", "RimeBridge", "SkinKit"]
HOST_PACKAGES = [*EXTENSION_PACKAGES, "PackageManager"]


def newest_app():
    apps = [path for path in BUILDS.glob("*/DerivedData/Build/Products/*/HostApp.app") if path.is_dir()]
    return max(apps, key=lambda path: path.stat().st_mtime, default=None)


def declares_resources(package):
    manifest = (ROOT / "Packages" / package / "Package.swift").read_text(encoding="utf-8")
    return re.search(r"\.(process|copy)\(", manifest) is not None


class BuiltResourceBundleTests(unittest.TestCase):
    def test_declared_packages_have_resources(self):
        for package in HOST_PACKAGES:
            self.assertTrue(declares_resources(package), package)

    def test_built_app_and_extension_ship_every_resource_bundle(self):
        app = newest_app()
        if app is None:
            self.skipTest("no unsigned app build under .local/ci/app-builds (run make build-simulator)")
        extension = app / "PlugIns/KeyboardExtension.appex"
        self.assertTrue(extension.is_dir(), "the keyboard extension is embedded in the app")
        for container, packages in ((app, HOST_PACKAGES), (extension, EXTENSION_PACKAGES)):
            for package in packages:
                bundle = container / f"{package}_{package}.bundle"
                self.assertTrue(bundle.is_dir(), f"{bundle.relative_to(app)} is missing from the build")
                languages = {path.stem for path in bundle.glob("*.lproj")}
                self.assertTrue({"zh-Hans", "zh-Hant", "ja"} <= languages, f"{bundle.name}: {sorted(languages)}")


if __name__ == "__main__":
    unittest.main()
