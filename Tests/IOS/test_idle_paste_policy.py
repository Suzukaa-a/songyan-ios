"""Strict idle paste policy, production controller wiring, and ABA lease races."""
import sys
import unittest

from swift_probe import ROOT, controller_sources, production_modules, run, scratch_directory, section, type_source_text

PASTE = ROOT / "Apps/SharedKeyboard/QuickPasteView.swift"
SHARED = ROOT / "Apps/SharedKeyboard"
MEMO = SHARED / "KeyboardPanelView+LayoutDefinitions.swift"
FIXTURE = ROOT / "Tests/IOS/Fixtures/IdlePastePolicy.swift"


def panel_fragments(source, memo):
    return {
        "/* PRODUCTION_NATIVE_SHELL_HEIGHT */": section(
            (SHARED / "KeyboardPanelHost.swift").read_text(encoding="utf-8"),
            "    private var layoutShellHeight:", "    private var layoutFit:"),
        "/* PRODUCTION_TOOLBAR_PREFERENCES */": section(
            (SHARED / "KeyboardAppearance.swift").read_text(encoding="utf-8"),
            "public enum KeyboardIdleToolbarPreferences {", "public enum KeyboardHeightPreferences {"),
        # The memo closes its file.
        "/* PRODUCTION_DEFINITION_MEMO */": memo[memo.index("final class DefinitionResolutionMemo {"):],
        "/* PRODUCTION_DEFINITION_CHROME */": section(source, "    var usesConfiguredLayout:",
                                                      "    var usesBundledMergedPad:"),
        "/* PRODUCTION_IDLE_GETTER */": section(source, "    private var quickPasteIdleInput:",
                                                "    private func panelSurface("),
        "/* PRODUCTION_SYMBOL_ERROR_GETTER */": section(source, "    var t9QuickSymbolsError:",
                                                        "    // MARK: Key feedback"),
    }


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class IdlePasteProductionTests(unittest.TestCase):
    def test_complete_production_policy_lease_controller_and_symbol_model(self):
        with scratch_directory("idle-paste-policy") as directory:
            modules = production_modules()
            existing = (ROOT / "Tests/IOS/Fixtures/ControllerInputRegressions.swift").read_text(encoding="utf-8")
            platform = directory / "PlatformSeam.swift"
            platform.write_text(existing.split("@main struct ControllerInputChecks", 1)[0], encoding="utf-8")
            controller = controller_sources(directory)
            queue = directory / "EngineOpQueue.swift"
            queue.write_text((ROOT / "Apps/SharedKeyboard/EngineOpQueue.swift").read_text(encoding="utf-8"), encoding="utf-8")
            generated = FIXTURE.read_text(encoding="utf-8")
            fragments = panel_fragments(type_source_text(SHARED, "KeyboardPanelView"), MEMO.read_text(encoding="utf-8"))
            for marker, fragment in fragments.items():
                self.assertEqual(generated.count(marker), 1, marker)
                generated = generated.replace(marker, fragment)
            fixture = directory / "IdlePastePolicy.swift"
            fixture.write_text(generated, encoding="utf-8")
            binary = directory / "probe"
            run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                 "-I", str(modules), "-L", str(modules),
                 "-module-cache-path", str(directory / "module-cache"),
                 "-lKeyboardCore", "-lLayoutKit", "-lCandidateKit",
                 "-Xlinker", "-rpath", "-Xlinker", str(modules),
                 str(PASTE), str(ROOT / "Apps/SharedKeyboard/T9QuickSymbolModel.swift"),
                 *map(str, controller), str(queue), str(platform), str(fixture), "-o", str(binary)])
            runtime = directory / "runtime"
            runtime.mkdir()
            print(run([str(binary), str(runtime)]), end="")


if __name__ == "__main__":
    unittest.main()
