"""Production option persistence: full identities, FIFO, revisions, and failures."""
import sys
import unittest

from swift_probe import ROOT, run_swift


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class OptionPersistenceTests(unittest.TestCase):
    def test_cache_ordering_errors_and_atomic_store(self):
        source = (ROOT / "Apps/SharedKeyboard/OptionStore.swift").read_text()
        source = source.split("/// Conservative reader", 1)[0]
        # The built-in script seeding adapter needs KeyboardCore types and has its own
        # production-source probe; this probe stays about the store and the preference cache.
        start = source.index("// MARK: - Built-in script default seeding")
        end = source.index("/// Process-wide FIFO", start)
        source = source[:start] + source[end:]
        source = source.replace("import KeyboardCore\n", "").replace("import RimeKit\n", "")
        checks = (ROOT / "Tests/IOS/Fixtures/option-persistence-main.swift").read_text()
        print(run_swift(source, checks, prefix="option-persistence", library=True), end="")


if __name__ == "__main__":
    unittest.main()
