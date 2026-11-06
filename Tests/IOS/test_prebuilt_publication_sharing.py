"""Prebuilt publication sharing: the App Group publication must not copy compiled bins twice.

The host installs a package whose compiled bins already live under the read-only installation
`resources/build`; deployment still writes its own build under the writable `user/build`. These
scenarios drive the production `KeyboardRecipeStore.publish` twice, then check inode identity,
committed bytes and the 1.3x footprint budget on the real publication root.

They are expected to fail until publication links identical bytes from read-only trees (the
installed source or the previous published generation) instead of copying every generation.
"""
import sys
import unittest

from swift_probe import ROOT, compile_swift, recipe_store_source, run, scratch_directory


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class PrebuiltPublicationSharingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.context = scratch_directory("prebuilt-publication-sharing")
        cls.directory = cls.context.__enter__()
        cls.addClassCleanup(cls.context.__exit__, None, None, None)
        source = cls.directory / "Production.swift"
        source.write_text(recipe_store_source(), encoding="utf-8")
        main = cls.directory / "main.swift"
        main.write_text(
            "import Foundation\n"
            "let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)\n"
            "try prebuiltPublicationSharingChecks(base, scenario: CommandLine.arguments[2])\n",
            encoding="utf-8",
        )
        fixture = ROOT / "Tests/IOS/Fixtures/prebuilt-publication-sharing-checks.swift"
        cls.binary = compile_swift(cls.directory, [source, fixture, main])

    def scenario(self, name):
        directory = self.directory / name
        directory.mkdir()
        print(run([str(self.binary), str(directory), name]), end="")

    def test_two_generations_link_the_installed_source_bins(self):
        self.scenario("shared-source-bins")

    def test_same_length_different_content_keeps_the_work_bytes(self):
        self.scenario("divergent-same-length")

    def test_committed_generation_is_immune_to_later_work_writes(self):
        self.scenario("work-write-after-publish")

    def test_yaml_and_learning_databases_are_never_shared(self):
        self.scenario("not-shared-yaml-userdb")

    def test_second_generation_links_the_previous_publication(self):
        self.scenario("previous-generation-bins")

    def test_unique_bytes_stay_within_the_footprint_budget(self):
        self.scenario("ratio")


if __name__ == "__main__":
    unittest.main()
