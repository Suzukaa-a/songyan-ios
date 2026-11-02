"""Production schema options: native choice groups and installed OpenCC dependencies."""
import sys
import unittest

from swift_probe import CORE, ROOT, run_swift


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class SchemaOptionCapabilitiesTests(unittest.TestCase):
    def test_groups_opencc_dependencies_and_atomic_choice(self):
        source = (ROOT / "Apps/SharedKeyboard/OptionStore.swift").read_text()
        start = source.index("    /// Read the selected schema")
        end = source.index("    static func read(", start)
        source = source[:start] + source[end:]
        source = source.replace("import KeyboardCore\n", "").replace("import RimeKit\n", "")
        source += (CORE / "Engine/EngineOptionDescriptor.swift").read_text()
        checks = (ROOT / "Tests/IOS/Fixtures/schema-options-main.swift").read_text()
        print(run_swift(source, checks, prefix="schema-options", library=True), end="")


if __name__ == "__main__":
    unittest.main()
