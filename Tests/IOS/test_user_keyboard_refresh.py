"""The 我的键盘 page reads the published list again when the app comes back to the front, so a keyboard
switched from the keyboard's own menu is the one marked 正在使用."""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory, section


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class UserKeyboardRefreshTests(unittest.TestCase):
    def test_page_refreshes_on_return_unless_the_user_has_a_draft(self):
        center = (ROOT / "Apps/HostApp/UserKeyboardCenter.swift").read_text(encoding="utf-8")
        view = (ROOT / "Apps/HostApp/UserKeyboardManagementView.swift").read_text(encoding="utf-8")
        policy = section(center, "    static func refreshesOnReturn(", "    /// One structured refresh")
        observer = section(view, ".onChange(of: scenePhase)", ".refreshable")
        self.assertIn("phase == .active", observer)
        self.assertIn("UserKeyboardCenter.refreshesOnReturn(", observer)
        self.assertIn("center.refresh()", observer)
        source = (
            "enum UserKeyboardCenter {\n" + policy + "}\n"
            "func check(_ value: Bool, _ label: String) { if !value { fatalError(label) } }\n"
            "check(UserKeyboardCenter.refreshesOnReturn(hasChanges: false, isSaving: false, isBusy: false), \"idle\")\n"
            "check(!UserKeyboardCenter.refreshesOnReturn(hasChanges: true, isSaving: false, isBusy: false), \"draft\")\n"
            "check(!UserKeyboardCenter.refreshesOnReturn(hasChanges: false, isSaving: true, isBusy: false), \"saving\")\n"
            "check(!UserKeyboardCenter.refreshesOnReturn(hasChanges: false, isSaving: false, isBusy: true), \"busy\")\n"
            "print(\"refresh policy passed\")\n"
        )
        with scratch_directory("user-keyboard-refresh") as directory:
            main = directory / "main.swift"
            main.write_text(source, encoding="utf-8")
            print(run([str(compile_swift(directory, [main]))]), end="")


if __name__ == "__main__":
    unittest.main()
