"""The running keyboard's title: a board this build ships with its own name (the real physical
layout) names itself first, followed by the input method; every other keyboard keeps the published
name, then the shape name, then the author's name. The shipped names resolve from the shared string
catalog in all three languages. The title-shape assertions live in the Swift probe."""
import json
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory

RULES = ROOT / "Apps/SharedKeyboard/KeyboardPanelRules.swift"
CATALOG = ROOT / "Resources/Localizable.xcstrings"
START = "// MARK: - Keyboard title"
KEYS = {
    "zhuyin41": "layout.name.zhuyin41",
    "cangjie26": "layout.name.cangjie26",
}
LANGUAGES = ("zh-Hans", "zh-Hant", "ja")


def production_source():
    text = RULES.read_text(encoding="utf-8")
    return "import Foundation\nimport KeyboardCore\n\n" + text[text.index(START):]


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class KeyboardTitleTests(unittest.TestCase):
    def test_the_bundled_traditional_boards_are_named_in_three_languages(self):
        self.assertTrue(CATALOG.exists(), "the shared string catalog must exist")
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
        self.assertTrue(
            set(KEYS.values()).issubset(catalog["strings"]),
            "the shared catalog contains both bundled layout names")
        for key in KEYS.values():
            self.assertEqual(sorted(catalog["strings"][key]["localizations"]), sorted(LANGUAGES), key)
        with scratch_directory("keyboard-title") as directory:
            compiled = directory / "catalog"
            compiled.mkdir()
            run([
                "xcrun", "xcstringstool", "compile", str(CATALOG), "-o", str(compiled),
                *[item for language in LANGUAGES for item in ("-l", language)],
            ])
            source = directory / "Production.swift"
            source.write_text(production_source(), encoding="utf-8")
            probe = directory / "main.swift"
            probe.write_text(
                (ROOT / "Tests/IOS/Fixtures/keyboard-title-main.swift").read_text(encoding="utf-8"),
                encoding="utf-8")
            binary = compile_swift(directory, [source, probe], dependencies=("KeyboardCore",))
            for language in LANGUAGES:
                output = run([str(binary), str(compiled), "-AppleLanguages", f"({language})"])
                resolved = {}
                for line in output.splitlines():
                    if line.startswith("NAME "):
                        _, name, value = line.split(" ", 2)
                        resolved[name] = value
                print(output, end="")
                self.assertEqual(set(resolved), set(KEYS), language)
                for name, key in KEYS.items():
                    expected = catalog["strings"][key]["localizations"][language]["stringUnit"]["value"]
                    self.assertEqual(resolved[name], expected, f"{language} {name}")


if __name__ == "__main__":
    unittest.main()
