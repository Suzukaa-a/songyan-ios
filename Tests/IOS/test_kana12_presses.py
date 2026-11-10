"""Kana12 keys under different fingers each type on their own release, so a two-thumb
rollover never drops a key."""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory, section

VIEW = ROOT / "Apps/SharedKeyboard/Kana12KeyboardView.swift"


def production_source():
    text = VIEW.read_text(encoding="utf-8")
    return "\n".join([
        "import CoreGraphics\nimport Foundation\nimport KeyboardCore\n",
        section(text, "// MARK: - Contract", "/// The non-kana keys around the centre block."),
        section(text, "// MARK: - Press state", "// MARK: - Metrics"),
    ])


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class Kana12PressesTests(unittest.TestCase):
    def test_overlapping_presses_each_type(self):
        with scratch_directory("kana12-presses") as directory:
            source = directory / "Production.swift"
            source.write_text(production_source(), encoding="utf-8")
            probe = directory / "main.swift"
            probe.write_text(
                (ROOT / "Tests/IOS/Fixtures/kana12-presses-main.swift").read_text(encoding="utf-8"),
                encoding="utf-8")
            binary = compile_swift(directory, [source, probe], dependencies=("KeyboardCore",))
            self.assertEqual(run([str(binary)]).strip(), "OK")


if __name__ == "__main__":
    unittest.main()
