"""Production schema options: native choice groups and installed OpenCC dependencies."""
import sys
import unittest

from swift_probe import CORE, ROOT, run_swift


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class SchemaOptionCapabilitiesTests(unittest.TestCase):
    def test_groups_opencc_dependencies_and_atomic_choice(self):
        source = (ROOT / "Apps/SharedKeyboard/OptionStore.swift").read_text()
        # The built-in script seeding adapter needs KeyboardCore types and has its own
        # production-source probe; this probe covers the schema option reader only.
        seed_start = source.index("// MARK: - Built-in script default seeding")
        seed_end = source.index("/// Process-wide FIFO", seed_start)
        source = source[:seed_start] + source[seed_end:]
        start = source.index("    /// Read the selected schema")
        end = source.index("    static func read(", start)
        source = source[:start] + source[end:]
        source = source.replace("import KeyboardCore\n", "").replace("import RimeKit\n", "")
        source += (CORE / "Engine/EngineOptionDescriptor.swift").read_text()
        checks = (ROOT / "Tests/IOS/Fixtures/schema-options-main.swift").read_text()
        print(run_swift(source, checks, prefix="schema-options", library=True), end="")


if __name__ == "__main__":
    unittest.main()
