"""The author bar's own footer shortcuts: a declared control entry is never duplicated (including
an authored .languageSwitch key), and the bundled traditional boards that declare their whole
5-key footer get no extra 123 / symbol / globe / 中英 key."""
import sys
import unittest

from swift_probe import ROOT, run_swift, section

RULES = ROOT / "Apps/SharedKeyboard/KeyboardPanelRules.swift"
START = "// MARK: - Authored control-row shortcuts"
END = "// MARK: - Keyboard title"


def production_source():
    text = RULES.read_text(encoding="utf-8")
    return "import Foundation\nimport LayoutKit\n\n" + section(text, START, END)


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class KeyboardFooterShortcutTests(unittest.TestCase):
    def test_declared_entries_are_never_duplicated_and_authored_footers_keep_their_keys(self):
        checks = (ROOT / "Tests/IOS/Fixtures/footer-shortcuts-main.swift").read_text(encoding="utf-8")
        output = run_swift(
            production_source(), checks, prefix="footer-shortcuts",
            dependencies=("LayoutKit",))
        print(output, end="")


if __name__ == "__main__":
    unittest.main()
