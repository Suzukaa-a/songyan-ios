"""The Host's pairing default for a newly added keyboard: the input language's own board (note the
saved pairing is kept), resolved through the one shared policy rather than a second family table.
The same resolved board also names the row, so a 41-key keyboard is never read as the 26-key shape."""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory, section

COMPOSITION = ROOT / "Apps/HostApp/KeyboardCompositionView.swift"
CATALOG = ROOT / "Resources/Localizable.xcstrings"
START = "extension KeyboardLayoutKind {"
END = "/// Names the keyboards a layout or page is paired with."
LANGUAGES = ("zh-Hans", "zh-Hant", "ja")


def production_source():
    text = COMPOSITION.read_text(encoding="utf-8")
    return "import Foundation\nimport KeyboardCore\nimport LayoutKit\n\n" + section(text, START, END)


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class HostLayoutPairingTests(unittest.TestCase):
    def test_a_new_traditional_keyboard_defaults_to_its_own_board(self):
        self.assertTrue(CATALOG.exists(), "the shared string catalog must exist")
        checks = (ROOT / "Tests/IOS/Fixtures/host-pairing-main.swift").read_text(encoding="utf-8")
        with scratch_directory("host-pairing") as directory:
            compiled = directory / "catalog"
            compiled.mkdir()
            run([
                "xcrun", "xcstringstool", "compile", str(CATALOG), "-o", str(compiled),
                *[item for language in LANGUAGES for item in ("-l", language)],
            ])
            source = directory / "Production.swift"
            source.write_text(production_source(), encoding="utf-8")
            probe = directory / "main.swift"
            probe.write_text(checks, encoding="utf-8")
            binary = compile_swift(
                directory, [source, probe], dependencies=("KeyboardCore", "LayoutKit"))
            output = run([str(binary), str(compiled)])
            print(output, end="")


if __name__ == "__main__":
    unittest.main()
