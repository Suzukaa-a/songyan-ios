"""Keyboard tools settings page: every list action goes through the store and leaves it consistent."""
import sys
import unittest

from swift_probe import ROOT, run_swift

CENTER = ROOT / "Apps/HostApp/KeyboardToolsCenter.swift"
DRAFT = ROOT / "Apps/HostApp/KeyboardToolsDraft.swift"
QUICK_CONTENT = ROOT / "Packages/QuickContentKit/Sources/QuickContentKit"
# Only the tool-format files this page uses, so unrelated package work cannot break this probe.
TOOL_SOURCES = ("ToolDefinition.swift", "ToolDefinitionError.swift", "BuiltinToolDefinitions.swift", "ToolStore.swift")

# The page resolves the shared container through RimePaths; the probe injects a scratch directory
# instead, so this seam only has to compile.
RIME_PATHS_SEAM = r'''
enum RimePaths {
    static func probedStoreDirectory(
        sharedName: String, localName: String, label: String
    ) -> (url: URL, isShared: Bool) {
        (URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(sharedName), false)
    }
}
'''

# SwiftPM synthesises Bundle.module for the package; the probe supplies it.
BUNDLE_SEAM = ""

PROBE = r'''
import Foundation

@MainActor
func settle(_ center: KeyboardToolsCenter) async {
    for _ in 0..<600 {
        if !center.isLoading { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    precondition(false, "the settings page never finished reading the store")
}

@MainActor
func scratchCenter(_ base: URL, _ name: String) -> KeyboardToolsCenter {
    let directory = base.appendingPathComponent(name)
    let center = KeyboardToolsCenter(resolveLocation: { .shared(directory) })
    center.reload()
    return center
}

@main struct Main {
    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])

        // First use: the three examples, enabled, unpinned, in their documented order.
        let center = scratchCenter(base, "tools")
        await settle(center)
        let expectedBuiltins = BuiltinToolDefinitions.all().map(\.id)
        precondition(center.canEdit)
        precondition(center.entries.map(\.id) == expectedBuiltins)
        precondition(center.entries.allSatisfy { $0.isBuiltin && $0.isEnabled && !$0.isPinned })
        precondition(center.undoableDeletion == nil)
        print("PASS: a fresh store lists the built-in examples enabled and unpinned")

        // Enable state is written and survives a reread.
        let disabled = await center.setEnabled(false, toolID: BuiltinToolDefinitions.halfwidthID)
        precondition(disabled)
        precondition(center.entries.first { $0.id == BuiltinToolDefinitions.halfwidthID }?.isEnabled == false)
        let reread = scratchCenter(base, "tools")
        await settle(reread)
        precondition(reread.entries.first { $0.id == BuiltinToolDefinitions.halfwidthID }?.isEnabled == false)
        print("PASS: enable state survives a reload")

        // The toolbar holds at most two tools; a third attempt is refused with a message.
        let firstPin = await center.setPinned(true, toolID: BuiltinToolDefinitions.simplificationID)
        let secondPin = await center.setPinned(true, toolID: BuiltinToolDefinitions.uppercaseID)
        precondition(firstPin && secondPin)
        precondition(center.entries.filter(\.isPinned).count == 2)
        let beforeThirdPin = center.entries
        let thirdPin = await center.setPinned(true, toolID: BuiltinToolDefinitions.halfwidthID)
        precondition(!thirdPin)
        precondition(center.entries == beforeThirdPin, "a refused pin must not change the list")
        precondition(center.lastError?.isEmpty == false)
        let unpinned = await center.setPinned(false, toolID: BuiltinToolDefinitions.uppercaseID)
        let replacementPin = await center.setPinned(true, toolID: BuiltinToolDefinitions.halfwidthID)
        precondition(unpinned && replacementPin)
        precondition(center.entries.filter(\.isPinned).count == 2)
        print("PASS: a third pinned tool is refused, explained, and leaves the list unchanged")

        // Ordering: moving the last entry to the front is persisted.
        let lastID = center.entries.last?.id ?? ""
        let moved = await center.moveTool(id: lastID, toIndex: 0)
        precondition(moved && center.entries.first?.id == lastID)
        let orderReread = scratchCenter(base, "tools")
        await settle(orderReread)
        precondition(orderReread.entries.first?.id == lastID)
        print("PASS: list order moves and survives a reload")

        // A built-in example can be disabled and pinned, never deleted.
        let builtinDelete = await center.deleteTool(id: BuiltinToolDefinitions.simplificationID)
        precondition(!builtinDelete)
        precondition(center.lastError?.isEmpty == false)
        precondition(center.entries.contains { $0.id == BuiltinToolDefinitions.simplificationID })
        print("PASS: a built-in example refuses deletion")

        // Import: a new file is inserted, the same file again updates it, a broken file changes nothing.
        let userTool = ToolDefinition(
            id: "my-tool", name: ["zh-Hans": "我的工具"], steps: [.width(mode: .toHalf)])
        let userBytes = try userTool.encoded()
        let imported = await center.importTool(data: userBytes)
        precondition(imported)
        precondition(center.entries.first { $0.id == "my-tool" }?.definition == userTool)
        let reimported = await center.importTool(data: userBytes)
        precondition(reimported)
        precondition(center.entries.filter { $0.id == "my-tool" }.count == 1)
        let beforeBrokenImport = center.entries
        let brokenImport = await center.importTool(data: Data("{ not a tool".utf8))
        precondition(!brokenImport)
        precondition(center.entries == beforeBrokenImport)
        precondition(center.lastError?.isEmpty == false)
        print("PASS: import inserts and updates, and a broken file is refused without changes")

        // Create by example: the copy keeps the example's names and steps until the user edits them.
        let copy = await center.duplicateTool(id: BuiltinToolDefinitions.simplificationID)
        precondition(copy != nil)
        guard let copy else { return }
        var draft = KeyboardToolDraft(definition: copy)
        precondition(draft.name.count == 4, "a copy starts with the example's names")
        draft.editableName = "我的繁简"
        draft.steps.removeAll()
        draft.addStep(.replace)
        draft.steps[0].pattern = "软件"
        draft.steps[0].replacement = "軟體"
        draft.addStep(.opencc)
        let savedDraft = await center.saveDraft(draft)
        precondition(savedDraft)
        guard let savedEntry = center.entries.first(where: { $0.id == copy.id }) else { return }
        precondition(savedEntry.definition.name == ["zh-Hans": "我的繁简"])
        precondition(savedEntry.definition.steps.count == 2)
        precondition(savedEntry.definition.steps.first == .replace(pattern: "软件", replacement: "軟體"))
        print("PASS: a copy is edited into a user tool and an edited name replaces the example's names")

        // A draft the file format would reject is refused with a reason and writes nothing.
        let beforeRefusals = center.entries
        var anonymous = KeyboardToolDraft(definition: savedEntry.definition)
        anonymous.editableName = ""
        let emptyName = await center.saveDraft(anonymous)
        precondition(!emptyName && center.lastError?.isEmpty == false)
        precondition(center.entries == beforeRefusals)

        var badMap = KeyboardToolDraft(definition: savedEntry.definition)
        badMap.steps = [KeyboardToolStepDraft(type: .map)]
        badMap.steps[0].mapLines = "没有等号"
        let refusedMap = await center.saveDraft(badMap)
        precondition(!refusedMap && center.lastError?.isEmpty == false)
        precondition(center.entries == beforeRefusals)

        var badRegex = KeyboardToolDraft(definition: savedEntry.definition)
        badRegex.steps = [KeyboardToolStepDraft(type: .replace)]
        badRegex.steps[0].pattern = "("
        let refusedRegex = await center.saveDraft(badRegex)
        precondition(!refusedRegex && center.lastError?.isEmpty == false)
        precondition(center.entries == beforeRefusals)
        print("PASS: a draft without a name, a malformed map line or a broken pattern is refused")

        // Delete offers one undo that restores the position and the tool's own settings.
        let userID = copy.id
        let disabledUser = await center.setEnabled(false, toolID: userID)
        precondition(disabledUser)
        let orderBeforeDelete = center.entries.map(\.id)
        let deleted = await center.deleteTool(id: userID)
        precondition(deleted)
        precondition(!center.entries.contains { $0.id == userID })
        precondition(center.undoableDeletion?.definition.id == userID)
        let undone = await center.undoDelete()
        precondition(undone)
        precondition(center.entries.map(\.id) == orderBeforeDelete)
        precondition(center.entries.first { $0.id == userID }?.isEnabled == false, "undo keeps the tool's settings")
        print("PASS: deleting a user tool offers one undo, which restores order and settings")

        // Export writes the same file that imports back unchanged.
        let exported = await center.exportData(id: userID)
        precondition(exported != nil)
        guard let exported else { return }
        let decoded = try ToolDefinition.decode(exported)
        precondition(decoded == center.entries.first { $0.id == userID }?.definition)
        let secondCenter = scratchCenter(base, "second")
        await settle(secondCenter)
        let roundTrip = await secondCenter.importTool(data: exported)
        precondition(roundTrip)
        precondition(secondCenter.entries.first { $0.id == userID }?.definition == decoded)
        print("PASS: export writes the same tool file that imports back unchanged")

        // An unreadable settings file is reported, never replaced, and writes are refused.
        let damagedBase = base.appendingPathComponent("damaged")
        try FileManager.default.createDirectory(at: damagedBase, withIntermediateDirectories: true)
        let stateFile = damagedBase.appendingPathComponent("state.json")
        try Data("not a store".utf8).write(to: stateFile)
        let damaged = scratchCenter(base, "damaged")
        await settle(damaged)
        precondition(!damaged.canEdit)
        precondition(damaged.loadFailed)
        precondition(damaged.lastError?.isEmpty == false)
        let refusedWrite = await damaged.setEnabled(false, toolID: BuiltinToolDefinitions.halfwidthID)
        precondition(!refusedWrite)
        let preservedState = try Data(contentsOf: stateFile)
        precondition(preservedState == Data("not a store".utf8), "a refused file must not be overwritten")
        print("PASS: an unreadable settings file is reported, refused, and left untouched")
    }
}
'''


def production_source():
    # The probe compiles the package's own sources into the same module, so the package import is
    # dropped; every other import resolves on macOS as well.
    center = CENTER.read_text(encoding="utf-8").replace("import QuickContentKit\n", "")
    draft = DRAFT.read_text(encoding="utf-8").replace("import QuickContentKit\n", "")
    pieces = [
        "import Combine\nimport Foundation\nimport SwiftUI\n",
        RIME_PATHS_SEAM,
        BUNDLE_SEAM,
        center,
        draft,
        "\n".join((QUICK_CONTENT / name).read_text(encoding="utf-8") for name in TOOL_SOURCES),
    ]
    return "\n".join(pieces)


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class KeyboardToolsSettingsTests(unittest.TestCase):
    def test_list_actions_keep_the_store_consistent(self):
        print(
            run_swift(production_source(), PROBE, prefix="keyboard-tools-settings", library=True),
            end="",
        )


if __name__ == "__main__":
    unittest.main()