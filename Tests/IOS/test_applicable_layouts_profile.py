"""The layouts 我的键盘 offers by what the scheme's speller needs: which shapes a scheme may fold to,
the generated code board and stroke pad, and what each offered layout lacks."""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory, section

COMPOSITION = ROOT / "Apps/HostApp/KeyboardCompositionView.swift"
START = "extension KeyboardLayoutKind {"
END = "/// Names the keyboards a layout or page is paired with."


def production_source():
    text = COMPOSITION.read_text(encoding="utf-8")
    return "import Foundation\nimport KeyboardCore\nimport LayoutKit\n\n" + section(text, START, END)


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class ApplicableLayoutsProfileTests(unittest.TestCase):
    def test_layouts_are_offered_by_the_key_profile(self):
        checks = (ROOT / "Tests/IOS/Fixtures/applicable-layouts-profile-main.swift").read_text(encoding="utf-8")
        with scratch_directory("applicable-layouts-profile") as directory:
            source = directory / "Production.swift"
            source.write_text(production_source(), encoding="utf-8")
            probe = directory / "main.swift"
            probe.write_text(checks, encoding="utf-8")
            binary = compile_swift(directory, [source, probe], dependencies=("KeyboardCore", "LayoutKit"))
            output = run([str(binary)])
            print(output, end="")
            self.assertIn("applicable layout checks passed", output)


if __name__ == "__main__":
    unittest.main()
