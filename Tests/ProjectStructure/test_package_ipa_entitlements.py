#!/usr/bin/env python3
"""Contract for the entitlements package-ipa.sh expands before ad-hoc signing.

codesign does not expand Xcode build settings, so $(SONGYAN_APP_GROUP) and
$(AppIdentifierPrefix) (used by keychain-access-groups) must be filled by the packaging script.
A missing Team ID or an unknown setting must fail instead of shipping literal text.
"""

import importlib.util
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools/CI/scripts/expand-device-entitlements.py"


def load_module():
    spec = importlib.util.spec_from_file_location("expand_device_entitlements", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class EntitlementsExpansionTests(unittest.TestCase):
    def test_keychain_group_prefix_is_expanded(self):
        module = load_module()
        settings = module.identity_settings(ROOT)
        settings["AppIdentifierPrefix"] = "ABCDE12345."
        for target in ("HostApp", "KeyboardExtension"):
            with self.subTest(target=target):
                expanded = module.expanded_entitlements(
                    ROOT / f"Apps/{target}/{target}.entitlements", settings, target)
                self.assertEqual(
                    expanded["keychain-access-groups"],
                    ["ABCDE12345.group.app.songyan.shared"])
                self.assertEqual(
                    expanded["com.apple.security.application-groups"],
                    ["group.app.songyan.shared"])
                module.require_expanded(expanded, target)

    def test_missing_or_invalid_team_id_is_refused(self):
        module = load_module()
        for value in (None, "", "   ", "short", "abcde12345", "ABCDE123"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.resolve_team_id(value)
        self.assertEqual(module.resolve_team_id("ABCDE12345"), "ABCDE12345")

    def test_unknown_build_setting_is_refused(self):
        module = load_module()
        expanded = module.expand_value(
            {"com.apple.security.application-groups": ["$(UNKNOWN_SETTING)"]}, {})
        with self.assertRaises(ValueError):
            module.require_expanded(expanded, "fixture")

    def test_cli_fails_without_team_and_writes_expanded_files_with_one(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(os.environ)
            environment.pop("TEAMID", None)
            refused = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(ROOT),
                 "--output-dir", temporary],
                capture_output=True, text=True, env=environment)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("TEAMID", refused.stderr)
            self.assertEqual(list(Path(temporary).glob("*.entitlements")), [])

            environment["TEAMID"] = "ABCDE12345"
            accepted = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(ROOT),
                 "--output-dir", temporary],
                capture_output=True, text=True, env=environment)
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            for target in ("HostApp", "KeyboardExtension"):
                with (Path(temporary) / f"{target}.entitlements").open("rb") as handle:
                    entitlements = plistlib.load(handle)
                self.assertEqual(
                    entitlements["keychain-access-groups"],
                    ["ABCDE12345.group.app.songyan.shared"])
                self.assertNotIn("$(", plistlib.dumps(entitlements).decode("utf-8"))


if __name__ == "__main__":
    unittest.main()
