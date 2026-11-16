#!/usr/bin/env python3
"""Contract for the entitlements package-ipa.sh expands before ad-hoc signing.

codesign does not expand Xcode build settings, so $(SONGYAN_APP_GROUP) must be filled by the
packaging script. The public IPA is signed for no team, so without a Team ID the team-prefixed
keychain-access-groups entry is left out; with one it is expanded. An unknown setting must fail
instead of shipping literal text.
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

    def test_an_absent_team_is_none_and_an_invalid_one_is_refused(self):
        module = load_module()
        for value in (None, "", "   "):
            with self.subTest(value=value):
                self.assertIsNone(module.resolve_team_id(value))
        for value in ("short", "abcde12345", "ABCDE123"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.resolve_team_id(value)
        self.assertEqual(module.resolve_team_id("ABCDE12345"), "ABCDE12345")

    def test_unknown_build_setting_is_refused(self):
        module = load_module()
        expanded = module.expand_value(
            {"com.apple.security.application-groups": ["$(UNKNOWN_SETTING)"]}, {})
        with self.assertRaises(ValueError):
            module.require_expanded(expanded, "fixture")

    def test_cli_leaves_the_team_group_out_without_a_team_and_expands_it_with_one(self):
        # Regression: the public release has no team, and packaging refused to run without one.
        for team, groups in ((None, None), ("ABCDE12345", ["ABCDE12345.group.app.songyan.shared"])):
            with tempfile.TemporaryDirectory() as temporary:
                environment = dict(os.environ)
                environment.pop("TEAMID", None)
                if team:
                    environment["TEAMID"] = team
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), "--root", str(ROOT), "--output-dir", temporary],
                    capture_output=True, text=True, env=environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                for target in ("HostApp", "KeyboardExtension"):
                    with (Path(temporary) / f"{target}.entitlements").open("rb") as handle:
                        entitlements = plistlib.load(handle)
                    self.assertEqual(entitlements.get("keychain-access-groups"), groups)
                    self.assertEqual(
                        entitlements["com.apple.security.application-groups"], ["group.app.songyan.shared"])
                    self.assertNotIn("$(", plistlib.dumps(entitlements).decode("utf-8"))

    def test_cli_refuses_a_malformed_team(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(os.environ, TEAMID="not-a-team")
            refused = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(ROOT), "--output-dir", temporary],
                capture_output=True, text=True, env=environment)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("TEAMID", refused.stderr)

if __name__ == "__main__":
    unittest.main()
