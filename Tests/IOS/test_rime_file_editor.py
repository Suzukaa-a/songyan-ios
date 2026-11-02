"""The production config editor keeps edits made while an earlier save is suspended."""
import sys
import unittest

from swift_probe import ROOT, run_swift, section

PROBE = r'''
import Foundation
import Combine

struct RimeEditRoute {
    let packageID = "test"
    let path = "main.custom.yaml"
    let title = "Config"
    let grammarExample = false
}
enum RimeConfigEditor {
    static func hasScripts(path: String, text: String) -> Bool { false }
}
struct OpenFile { let text: String }
enum SaveResult { case saved, invalid(line: Int?), refused(String) }

// A suspended storage boundary makes the save/edit interleaving deterministic.
actor RecipePackageManager {
    var writes: [String] = []
    private var submitted = false
    private var firstSave: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func openRimeConfigFile(_ path: String, grammarExample: Bool) throws -> OpenFile {
        OpenFile(text: "original")
    }
    func waitForFirstSave() async {
        if submitted { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishFirstSave() { firstSave?.resume(); firstSave = nil }
    func saveRimeConfigFile(_ path: String, text: String) async throws -> SaveResult {
        if !submitted {
            submitted = true
            started?.resume()
            await withCheckedContinuation { firstSave = $0 }
        }
        writes.append(text)
        return .saved
    }
}
@MainActor final class SchemeImportCenter {
    static let shared = SchemeImportCenter()
    let storage = RecipePackageManager()
    func manager(_ id: String) -> RecipePackageManager { storage }
}

@main struct Main {
    @MainActor static func main() async {
        let storage = SchemeImportCenter.shared.storage
        let editor = RimeFileEditorModel(route: RimeEditRoute())
        await editor.load()
        editor.text = "first"
        let saving = Task { await editor.save() }
        await storage.waitForFirstSave()
        editor.text = "later"
        editor.edited()
        await editor.save()
        await storage.finishFirstSave()
        await saving.value
        let firstWrites = await storage.writes
        precondition(firstWrites == ["first"])
        precondition(editor.baseline == "first" && editor.text == "later")
        precondition(editor.dirty && !editor.saved && !editor.saving)
        await editor.save()
        let allWrites = await storage.writes
        precondition(allWrites == ["first", "later"])
        precondition(!editor.dirty && editor.saved && editor.baseline == "later")
        print("PASS: a suspended save commits its snapshot; later edits stay dirty until saved")
    }
}
'''


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class RimeFileEditorTests(unittest.TestCase):
    def test_edits_during_save_remain_unsaved(self):
        source = (ROOT / "Apps/HostApp/RimeConfigView.swift").read_text(encoding="utf-8")
        model = section(source, "@MainActor\nfinal class RimeFileEditorModel", "\n/// The in-app editor")
        print(run_swift("import Foundation\nimport Combine\n" + model, PROBE,
                        prefix="rime-file-editor", library=True), end="")


if __name__ == "__main__":
    unittest.main()
