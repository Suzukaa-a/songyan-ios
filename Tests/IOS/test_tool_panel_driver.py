"""Driver behaviour for the tool panel wiring: timeout cancels, late results are
ignored, closing cancels the run.

The probe compiles the production ToolPanelDriver (in ToolDocumentGateway.swift),
ToolDocumentGateway, ToolPanelPresentation and ToolKit sources for macOS, and drives
them through a strict double of the UITextDocumentProxy surface (only the calls the
real proxy has). This is driver/gateway behaviour, not a simulator run inside the
keyboard extension.
"""
import sys
import unittest

from swift_probe import ROOT, run, scratch_directory

TOOLKIT = ROOT / "Packages/ToolKit/Sources/ToolKit"
EXTENSION = ROOT / "Apps/KeyboardExtension"
FIXTURE = ROOT / "Tests/IOS/Fixtures/ToolPanelDriverProbe.swift"


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class ToolPanelDriverTests(unittest.TestCase):
    def test_driver_timeout_late_result_and_dismiss(self):
        sources = sorted(TOOLKIT.glob("*.swift"))
        self.assertTrue(sources, "ToolKit sources missing")
        texts = [path.read_text(encoding="utf-8") for path in sources]
        for path in (
            EXTENSION / "ToolPanelPresentation.swift",
            EXTENSION / "ToolDocumentProxy.swift",
            EXTENSION / "ToolDocumentGateway.swift",
        ):
            texts.append(
                path.read_text(encoding="utf-8").replace("import ToolKit\n", ""))
        with scratch_directory("tool-panel-driver") as directory:
            production = directory / "Production.swift"
            production.write_text("\n".join(texts), encoding="utf-8")
            binary = directory / "probe"
            run([
                "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                str(production), str(FIXTURE), "-o", str(binary),
            ])
            output = run([str(binary)])
        self.assertIn("PASS all", output, output)
        self.assertNotIn("FAIL ", output, output)


if __name__ == "__main__":
    unittest.main()
