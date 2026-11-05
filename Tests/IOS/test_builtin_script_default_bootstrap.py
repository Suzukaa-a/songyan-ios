"""Production-backed first-install script default: the real rule plus the real OptionStore."""
import sys
import unittest

from swift_probe import ROOT, compile_swift, run, scratch_directory, section, without_imports

CORE = ROOT / "Packages/KeyboardCore/Sources/KeyboardCore"


def bootstrap_source():
    store = (ROOT / "Apps/SharedKeyboard/OptionStore.swift").read_text()
    # Only the file-backed preference store, not the process-wide IO queue or the RimeKit reader.
    store_only = section(store, "public struct OptionStore", "/// Process-wide FIFO")
    return "import Foundation\nimport os\n" + "".join(
        without_imports(text) for text in (
            (CORE / "Engine/EngineOptionDescriptor.swift").read_text(),
            (CORE / "Support/TraditionalDefault.swift").read_text(),
            store_only,
            (ROOT / "Tests/IOS/Fixtures/BuiltinScriptDefaultChecks.swift").read_text(),
        )
    )


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class BuiltinScriptDefaultBootstrapTests(unittest.TestCase):
    """A first install persists the locale's exclusive script state; an existing install is kept."""

    def test_first_install_seeds_the_locale_state_and_an_existing_install_is_kept(self):
        with scratch_directory("builtin-script-default") as directory:
            source = directory / "Bootstrap.swift"
            source.write_text(bootstrap_source(), encoding="utf-8")
            binary = compile_swift(directory, [source], library=True)
            print(run([str(binary), str(directory)]), end="")


if __name__ == "__main__":
    unittest.main()
