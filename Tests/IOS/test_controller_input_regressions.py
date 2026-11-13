"""Run the complete production controller on macOS with platform/backend seams only."""
import sys
import unittest

from swift_probe import ROOT, controller_sources, production_modules, run, scratch_directory


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class ControllerInputRegressions(unittest.TestCase):
    def test_controller_input_and_async_candidates(self):
        with scratch_directory("controller-input") as directory:
            modules = production_modules()
            # UIKit enum values/time are the only UI seam. No controller method is
            # extracted, rewritten, or duplicated, so handle/probe/refresh stay wired.
            production = controller_sources(directory)
            queue = directory / "EngineOpQueue.swift"
            queue.write_text((ROOT / "Apps/SharedKeyboard/EngineOpQueue.swift").read_text())
            # The shipping candidate-action bridge is compiled unchanged, so the checks below retain
            # and call the real `.live` sink instead of a copy of its forwarding switch.
            candidate_actions = directory / "KeyboardCandidateActions.swift"
            candidate_actions.write_text(
                (ROOT / "Apps/SharedKeyboard/KeyboardCandidateActions.swift").read_text(encoding="utf-8"),
                encoding="utf-8")
            # Compile the production rollover coordinator verbatim, without the
            # UIKit CharacterButton that follows it in the same source file.
            key_source = (ROOT / "Apps/SharedKeyboard/AlternateCharacterKey.swift").read_text()
            rollover = directory / "KeyRollover.swift"
            rollover.write_text(key_source[key_source.index("/// A key that acts on release."):
                                           key_source.index("/// Ordered alternate KeyCaps")])
            fixture = ROOT / "Tests/IOS/Fixtures/ControllerInputRegressions.swift"
            binary = directory / "probe"
            run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                 "-I", str(modules), "-L", str(modules),
                 "-module-cache-path", str(directory / "module-cache"),
                 "-lKeyboardCore", "-lLayoutKit", "-lCandidateKit",
                 "-Xlinker", "-rpath", "-Xlinker", str(modules),
                 *map(str, production), str(queue), str(candidate_actions), str(rollover), str(fixture),
                 "-o", str(binary)])
            print(run([str(binary)]), end="")


if __name__ == "__main__":
    unittest.main()
