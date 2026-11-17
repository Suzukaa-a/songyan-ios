"""Production shared store: compile once, run each scenario in a fresh process/root."""
import sys
import unittest

from swift_probe import ROOT, compile_swift, recipe_store_source, run, scratch_directory


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class KeyboardRecipeStoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.context = scratch_directory("recipe-store")
        cls.directory = cls.context.__enter__()
        cls.addClassCleanup(cls.context.__exit__, None, None, None)
        source = cls.directory / "Production.swift"
        source.write_text(recipe_store_source(), encoding="utf-8")
        main = cls.directory / "main.swift"
        main.write_text('''import Foundation
let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
switch CommandLine.arguments[2] {
case "selection": try selectionChecks(base)
case "publication": try publicationChecks(base)
case "prune": try pruneChecks(base)
case "builtin": try builtinPublicationChecks(base)
case "kept": try keptPackagesChecks(base)
case "private": try privateSelectionChecks(base)
case "privateSwitch": try privatePackageSwitchChecks(base)
case "layoutKeyboards": try layoutKeyboardsChecks(base)
default: fatalError("unknown store scenario")
}
''', encoding="utf-8")
        fixtures = sorted((ROOT / "Tests/IOS/Fixtures").glob("*-checks.swift"))
        cls.binary = compile_swift(cls.directory, [source, *fixtures, main])

    def scenario(self, name):
        directory = self.directory / name
        directory.mkdir()
        print(run([str(self.binary), str(directory), name]), end="")

    def test_selection_publication_and_resource_fallback(self):
        self.scenario("selection")

    def test_a_pick_kept_without_full_access_applies_until_the_host_chooses(self):
        self.scenario("private")

    def test_a_package_switch_kept_without_full_access_is_promoted_with_it(self):
        self.scenario("privateSwitch")

    def test_keyboards_that_name_their_layout_and_the_records_saved_before(self):
        self.scenario("layoutKeyboards")

    def test_publication_rosters_and_provenance(self):
        self.scenario("publication")

    def test_empty_prune(self):
        self.scenario("prune")

    def test_builtin_scheme_publication(self):
        self.scenario("builtin")

    def test_kept_package_generations_and_entries(self):
        self.scenario("kept")


if __name__ == "__main__":
    unittest.main()
