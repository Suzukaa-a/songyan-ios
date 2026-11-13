"""Which pages keep the candidate band: on a wide surface every page keeps it, so the dismiss rail
never takes the key area's width when the keyboard flips to 123."""
import sys
import unittest

from swift_probe import ROOT, run_swift, section

RULES = ROOT / "Apps/SharedKeyboard/KeyboardPanelRules.swift"
START = "// MARK: - Candidate band"
END = "// MARK: - Authored control-row shortcuts"


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class KeyboardCandidateBandTests(unittest.TestCase):
    def test_wide_surfaces_keep_the_band_on_every_page(self):
        source = "import Foundation\n\n" + section(RULES.read_text(encoding="utf-8"), START, END)
        checks = (ROOT / "Tests/IOS/Fixtures/candidate-band-main.swift").read_text(encoding="utf-8")
        print(run_swift(source, checks, prefix="candidate-band"), end="")


if __name__ == "__main__":
    unittest.main()
