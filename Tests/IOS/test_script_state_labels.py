"""The bundled scheme's four script states: recognized only for its own declaration, worded by
the real compiled string catalog, and persisted through the production option store."""
import json
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory

CATALOG = ROOT / "Resources/Localizable.xcstrings"
KEYS = {
    "simplification": "script.state.simplified",
    "zht": "script.state.traditional",
    "zh_tw": "script.state.taiwan",
    "zh_hk": "script.state.hongKong",
}
LANGUAGES = ("zh-Hans", "zh-Hant", "ja")


def production_source():
    store = (ROOT / "Apps/SharedKeyboard/OptionStore.swift").read_text()
    # The seeding adapter is storage the parser does not use; its own probe covers it.
    seed_start = store.index("// MARK: - Built-in script default seeding")
    seed_end = store.index("/// Process-wide FIFO", seed_start)
    source = store[:seed_start] + store[seed_end:]
    # The schema reader needs librime; the parser above it does not.
    read_start = source.index("    /// Read the selected schema")
    read_end = source.index("    static func read(", read_start)
    source = source[:read_start] + source[read_end:]
    return source.replace("import RimeKit\n", "")


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class ScriptStateLabelTests(unittest.TestCase):
    def test_the_builtin_scheme_offers_four_localized_script_states(self):
        self.assertTrue(CATALOG.exists(), "the shared string catalog must exist")
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
        self.assertTrue(
            set(KEYS.values()).issubset(catalog["strings"]),
            "the shared catalog contains all four script state labels")
        for key in KEYS.values():
            self.assertEqual(
                sorted(catalog["strings"][key]["localizations"]), sorted(LANGUAGES), key)
        with scratch_directory("script-state-labels") as directory:
            compiled = directory / "catalog"
            compiled.mkdir()
            run(["xcrun", "xcstringstool", "compile", str(CATALOG), "-o", str(compiled),
                 *[item for language in LANGUAGES for item in ("-l", language)]])
            source = directory / "Production.swift"
            source.write_text(production_source(), encoding="utf-8")
            probe = directory / "Probe.swift"
            probe.write_text(
                (ROOT / "Tests/IOS/Fixtures/script-state-labels-main.swift").read_text(), encoding="utf-8")
            binary = compile_swift(directory, [source, probe], library=True, dependencies=("KeyboardCore",))
            for language in LANGUAGES:
                output = run([str(binary), str(compiled), "-AppleLanguages", f"({language})"])
                resolved = {}
                for line in output.splitlines():
                    if line.startswith("LABEL "):
                        _, name, value = line.split(" ", 2)
                        resolved[name] = value
                print(output, end="")
                self.assertEqual(set(resolved), set(KEYS), language)
                for name, key in KEYS.items():
                    expected = catalog["strings"][key]["localizations"][language]["stringUnit"]["value"]
                    self.assertEqual(resolved[name], expected, f"{language} {name}")


if __name__ == "__main__":
    unittest.main()
