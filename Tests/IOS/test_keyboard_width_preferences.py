"""Exercise the production split-width and side-margin preferences without installing either iOS app."""
import sys
import unittest

from swift_probe import ROOT, run_swift, section


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class KeyboardWidthPreferencesTests(unittest.TestCase):
    def test_defaults_clamping_and_the_shared_store(self):
        appearance = (ROOT / "Apps/SharedKeyboard/KeyboardAppearance.swift").read_text()
        preference = section(appearance, "public enum KeyboardWidthPreferences {", "\n}\n") + "\n}"
        policy = (ROOT / "Packages/CandidateKit/Sources/CandidateKit/KeyboardWideContentPolicy.swift").read_text()
        settings = "\n".join(line for line in policy.splitlines() if not line.startswith("import "))
        paths = (ROOT / "Apps/SharedKeyboard/RimePaths.swift").read_text()
        overlay = "public enum SharedPreferences {" + paths.split("public enum SharedPreferences {", 1)[1].split("\n}\n", 1)[0] + "\n}"
        # The preferences store LayoutKit's split mode (its case list, not how it applies to a
        # layout) and middle gap, so the probe carries both.
        split_mode = (ROOT / "Packages/LayoutKit/Sources/LayoutKit/KeyboardSplitMode.swift").read_text()
        middle_gap = (ROOT / "Packages/LayoutKit/Sources/LayoutKit/WideMiddleGap.swift").read_text()
        layout = (
            section(split_mode, "public enum KeyboardSplitMode", "    /// The split that applies")
            + "}\n"
            + "\n".join(line for line in middle_gap.splitlines() if not line.startswith("import "))
        )
        program = r'''
import Foundation
import os
enum KeyboardSurfaceWidth { static let phoneMaximum = 600.0 }
enum KeyboardRecipeStore {
    static let groupID = "app.songyan.width-test." + UUID().uuidString
    static func sharedDefaults() -> UserDefaults? { UserDefaults(suiteName: groupID) }
    nonisolated(unsafe) static var canWriteSharedContainer = true
}
extension Notification.Name { static let keyboardWidthChanged = Notification.Name("test.width") }
''' + layout + "\n" + overlay + "\n" + settings + "\n" + preference + r'''
let domain = KeyboardRecipeStore.groupID
let store = UserDefaults(suiteName: domain)!
defer { store.removePersistentDomain(forName: domain) }
// Nothing stored: a large screen starts at the phone limit with a 5 % margin.
precondition(KeyboardWidthPreferences.read(from: store) == KeyboardWidthSettings(splitWidth: 600))
precondition(!KeyboardWidthPreferences.read(from: store).sideMarginIsChosen)
precondition(KeyboardWidthPreferences.current == KeyboardWidthSettings.standard)
precondition(KeyboardWidthSettings.standard.sideMarginPercent == 5)
// A stored choice is read by the other process and snaps into the offered steps; with no margin
// width of its own, the margin starts where the split does.
KeyboardWidthPreferences.set(splitWidth: 819)
KeyboardWidthPreferences.set(sideMarginPercent: 3.8)
precondition(KeyboardWidthPreferences.current == KeyboardWidthSettings(splitWidth: 800, marginWidth: 800, sideMarginPercent: 4))
precondition(KeyboardWidthPreferences.read(from: UserDefaults(suiteName: domain)!) == KeyboardWidthSettings(splitWidth: 800, marginWidth: 800, sideMarginPercent: 4))
KeyboardWidthPreferences.set(sideMarginPercent: 0)
precondition(KeyboardWidthPreferences.current.sideMarginPercent == 0)
precondition(KeyboardWidthPreferences.current.sideMarginIsChosen)
// Resetting forgets the choice, so the default can give way to a system inset again.
KeyboardWidthPreferences.resetSideMargin()
precondition(!KeyboardWidthPreferences.current.sideMarginIsChosen)
precondition(KeyboardWidthPreferences.current.effectiveSideMarginPercent(systemInsetsSides: true) == 0)
precondition(KeyboardWidthPreferences.current.effectiveSideMarginPercent(systemInsetsSides: false) == 5)
// A stored value outside the range snaps to the nearest choice; a non-numeric one is the default.
store.set(5000, forKey: KeyboardWidthPreferences.splitWidthKey)
store.set(40, forKey: KeyboardWidthPreferences.sideMarginPercentKey)
precondition(KeyboardWidthPreferences.read(from: store) == KeyboardWidthSettings(splitWidth: 1200, marginWidth: 1200, sideMarginPercent: 10))
store.set(-3, forKey: KeyboardWidthPreferences.sideMarginPercentKey)
precondition(KeyboardWidthPreferences.read(from: store).sideMarginPercent == 0)
store.set("wide", forKey: KeyboardWidthPreferences.sideMarginPercentKey)
precondition(KeyboardWidthPreferences.read(from: store).sideMarginPercent == 5)
// The retired point-based key is ignored.
store.removeObject(forKey: KeyboardWidthPreferences.sideMarginPercentKey)
store.set(48, forKey: "keyboard.sideMargin.v1")
precondition(KeyboardWidthPreferences.read(from: store).sideMarginPercent == 5)
print("width preference checks passed")
'''
        print(run_swift("", program, prefix="width-preferences"), end="")


if __name__ == "__main__":
    unittest.main()
