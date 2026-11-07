import Foundation
import QuickContentKit
import XCTest

final class ToolStoreTests: XCTestCase {
    // MARK: - Fixtures

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("songyan-tool-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            #if os(macOS)
                try? fm.trashItem(at: directory, resultingItemURL: nil)
            #else
                try? fm.removeItem(at: directory)
            #endif
        }
        try await body(directory)
    }

    private func nameTable(_ suffix: String = "") -> [String: String] {
        [
            "zh-Hans": "工具\(suffix)",
            "zh-Hant": "工具\(suffix)",
            "ja": "ツール\(suffix)",
            "en": "Tool\(suffix)",
        ]
    }

    private func definition(
        id: String, suffix: String = "", steps: [ToolStep] = [.width(mode: .toHalf)]
    ) -> ToolDefinition {
        ToolDefinition(id: id, name: nameTable(suffix), steps: steps)
    }

    private func toolFile(_ root: URL, id: String) -> URL {
        root.appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("\(id).songyantool.json")
    }

    private func stateFile(_ root: URL) -> URL {
        root.appendingPathComponent("state.json")
    }

    private func trashFile(_ root: URL) -> URL {
        root.appendingPathComponent("trash", isDirectory: true)
            .appendingPathComponent("last-deletion.json")
    }

    private func assertStoreError(
        _ expected: ToolStoreError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as ToolStoreError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func testFailedMetadataWriteKeepsThePreviousToolDefinition() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            _ = try await store.importTool(data: definition(id: "user-a").encoded())
            let previous = try await store.exportTool(id: "user-a")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            do {
                _ = try await store.importTool(data: definition(id: "user-a", suffix: "changed").encoded())
                XCTFail("the read-only metadata directory must refuse the update")
            } catch {}
            let retained = try await store.exportTool(id: "user-a")
            XCTAssertEqual(retained, previous)
        }
    }

    func testFailedDeleteKeepsTheToolAndPreviousUndo() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            _ = try await store.importTool(data: definition(id: "user-a").encoded())
            _ = try await store.importTool(data: definition(id: "user-b").encoded())
            _ = try await store.deleteTool(id: "user-a")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            do {
                _ = try await store.deleteTool(id: "user-b")
                XCTFail("the read-only metadata directory must refuse deletion")
            } catch {}
            let retained = try await store.load()
            XCTAssertTrue(retained.entries.contains { $0.id == "user-b" })
            XCTAssertEqual(retained.undoableDeletion?.definition.id, "user-a")
        }
    }

    func testFailedUndoKeepsTheDeletedToolUndoable() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            _ = try await store.importTool(data: definition(id: "user-a").encoded())
            _ = try await store.deleteTool(id: "user-a")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
            do {
                _ = try await store.undoLastDeletion()
                XCTFail("the read-only metadata directory must refuse undo")
            } catch {}
            let retained = try await store.load()
            XCTAssertFalse(retained.entries.contains { $0.id == "user-a" })
            XCTAssertEqual(retained.undoableDeletion?.definition.id, "user-a")
        }
    }

    // MARK: - Seeding

    func testSeedShowsThreeBuiltinsWithFourLanguageNames() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let snapshot = try await store.load()
            XCTAssertEqual(
                snapshot.entries.map(\.id),
                [
                    BuiltinToolDefinitions.simplificationID,
                    BuiltinToolDefinitions.halfwidthID,
                    BuiltinToolDefinitions.uppercaseID,
                ])
            XCTAssertTrue(snapshot.entries.allSatisfy(\.isBuiltin))
            XCTAssertTrue(snapshot.entries.allSatisfy(\.isEnabled))
            XCTAssertFalse(snapshot.entries.contains(where: \.isPinned))
            for entry in snapshot.entries {
                XCTAssertEqual(Set(entry.definition.name.keys), Set(ToolDefinition.nameLanguageTags))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile(root).path))
        }
    }

    // MARK: - Import and export

    func testImportWritesTheToolFileAndExportIsDeterministic() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let tool = definition(
                id: "user-roundtrip",
                steps: [
                    .opencc(config: .s2twp),
                    .replace(pattern: "\\s+", replacement: " "),
                    .map(table: ["A": "B"]),
                    .caseTransform(mode: .upper),
                    .width(mode: .toHalf),
                    .template(pattern: "「{text}」"),
                ])
            let data = try tool.encoded()

            let outcome = try await store.importTool(data: data)
            XCTAssertEqual(outcome, .inserted(tool))

            let persisted = try ToolDefinition.decode(contentsOf: toolFile(root, id: tool.id))
            XCTAssertEqual(persisted, tool)

            let exported = try await store.exportTool(id: tool.id)
            XCTAssertEqual(exported, data)

            let reopened = ToolStore(rootURL: root)
            let reopenedExport = try await reopened.exportTool(id: tool.id)
            XCTAssertEqual(reopenedExport, data)

            let again = try await store.importTool(data: data)
            XCTAssertEqual(again, .updated(tool))
            let snapshot = try await store.load()
            XCTAssertEqual(snapshot.entries.filter { $0.id == tool.id }.count, 1)
        }
    }

    func testImportFromAFileURLUsesTheSameBoundary() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let tool = definition(id: "user-from-url")
            let file = root.appendingPathComponent("shared.songyantool.json")
            try tool.encoded().write(to: file)

            let outcome = try await store.importTool(contentsOf: file)
            XCTAssertEqual(outcome, .inserted(tool))
            let exported = try await store.exportTool(id: tool.id)
            XCTAssertEqual(exported, try tool.encoded())
        }
    }

    func testImportIgnoresUnknownFieldsAtTheBoundary() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let json = """
                {"formatVersion":1,"id":"user-unknown","name":{"zh-Hans":"甲"},"note":"ignored",
                 "steps":[{"type":"width","mode":"toHalf","extra":true}]}
                """
            let outcome = try await store.importTool(data: Data(json.utf8))
            guard case .inserted(let imported) = outcome else {
                return XCTFail("expected an inserted definition")
            }
            XCTAssertEqual(imported.steps, [.width(mode: .toHalf)])

            let exported = try await store.exportTool(id: "user-unknown")
            let text = String(decoding: exported, as: UTF8.self)
            XCTAssertFalse(text.contains("note"))
            XCTAssertFalse(text.contains("extra"))
        }
    }

    func testFailedImportLeavesEveryFileUntouched() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let kept = definition(id: "user-kept")
            _ = try await store.importTool(data: try kept.encoded())
            _ = try await store.setPinned(true, toolID: kept.id)
            let beforeSnapshot = try await store.load()
            let stateBefore = try Data(contentsOf: stateFile(root))
            let toolBefore = try Data(contentsOf: toolFile(root, id: kept.id))

            await assertStoreError(.importInvalid(ToolDefinitionError(reason: .unreadable))) {
                _ = try await store.importTool(data: Data("not a tool".utf8))
            }

            let afterSnapshot = try await store.load()
            XCTAssertEqual(afterSnapshot, beforeSnapshot)
            XCTAssertEqual(try Data(contentsOf: stateFile(root)), stateBefore)
            XCTAssertEqual(try Data(contentsOf: toolFile(root, id: kept.id)), toolBefore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: toolFile(root, id: "broken").path))
        }
    }

    func testDuplicateIdentifierImportKeepsPinAndOrder() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let original = definition(id: "user-duplicate")
            _ = try await store.importTool(data: try original.encoded())
            _ = try await store.setPinned(true, toolID: original.id)
            let beforeSnapshot = try await store.load()
            let indexBefore = beforeSnapshot.entries.firstIndex { $0.id == original.id }
            XCTAssertNotNil(indexBefore)

            let replacement = definition(
                id: original.id, suffix: "-v2", steps: [.caseTransform(mode: .lower)])
            let outcome = try await store.importTool(data: try replacement.encoded())
            XCTAssertEqual(outcome, .updated(replacement))

            let snapshot = try await store.load()
            guard let entry = snapshot.entries.first(where: { $0.id == original.id }) else {
                return XCTFail("the updated tool is missing")
            }
            XCTAssertEqual(entry.definition, replacement)
            XCTAssertEqual(entry.definition.name, replacement.name)
            XCTAssertTrue(entry.isPinned)
            XCTAssertEqual(snapshot.entries.firstIndex { $0.id == original.id }, indexBefore)
        }
    }

    func testImportRejectsABuiltinIdentifier() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let before = try await store.load()
            let reserved = definition(id: BuiltinToolDefinitions.halfwidthID)

            await assertStoreError(
                .identifierReservedForBuiltin(id: BuiltinToolDefinitions.halfwidthID)
            ) {
                _ = try await store.importTool(data: try reserved.encoded())
            }

            let after = try await store.load()
            XCTAssertEqual(after, before)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: toolFile(root, id: BuiltinToolDefinitions.halfwidthID).path))
        }
    }

    // MARK: - Pin limit, enable and order

    func testPinningMoreThanTwoToolsIsRejected() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            _ = try await store.setPinned(true, toolID: BuiltinToolDefinitions.simplificationID)
            _ = try await store.setPinned(true, toolID: BuiltinToolDefinitions.halfwidthID)

            await assertStoreError(.pinLimit(maximum: ToolStore.maximumPinnedTools)) {
                _ = try await store.setPinned(true, toolID: BuiltinToolDefinitions.uppercaseID)
            }

            var snapshot = try await store.load()
            XCTAssertEqual(
                snapshot.pinnedEntries.map(\.id),
                [BuiltinToolDefinitions.simplificationID, BuiltinToolDefinitions.halfwidthID])

            _ = try await store.setPinned(false, toolID: BuiltinToolDefinitions.simplificationID)
            _ = try await store.setPinned(true, toolID: BuiltinToolDefinitions.uppercaseID)
            snapshot = try await store.load()
            XCTAssertEqual(
                snapshot.pinnedEntries.map(\.id),
                [BuiltinToolDefinitions.halfwidthID, BuiltinToolDefinitions.uppercaseID])
        }
    }

    func testBuiltinsCanBeDisabledReorderedAndPinned() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            _ = try await store.setPinned(true, toolID: BuiltinToolDefinitions.simplificationID)
            _ = try await store.setEnabled(false, toolID: BuiltinToolDefinitions.halfwidthID)
            _ = try await store.moveTool(id: BuiltinToolDefinitions.uppercaseID, toIndex: 0)

            let snapshot = try await store.load()
            XCTAssertEqual(
                snapshot.entries.map(\.id),
                [
                    BuiltinToolDefinitions.uppercaseID,
                    BuiltinToolDefinitions.simplificationID,
                    BuiltinToolDefinitions.halfwidthID,
                ])
            XCTAssertEqual(
                snapshot.entries.first { $0.id == BuiltinToolDefinitions.simplificationID }?.isPinned,
                true)
            XCTAssertNil(snapshot.enabledEntries.first { $0.id == BuiltinToolDefinitions.halfwidthID })

            let reopened = try await ToolStore(rootURL: root).load()
            XCTAssertEqual(reopened, snapshot)
        }
    }

    func testEnabledPinnedAndOrderSurviveReopen() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            _ = try await store.importTool(data: try definition(id: "user-one").encoded())
            _ = try await store.importTool(data: try definition(id: "user-two").encoded())
            _ = try await store.setEnabled(false, toolID: "user-one")
            _ = try await store.setPinned(true, toolID: "user-two")
            _ = try await store.moveTool(id: "user-two", toIndex: 0)
            let expected = try await store.load()

            let reopened = ToolStore(rootURL: root)
            let actual = try await reopened.load()
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(actual.entries.first?.id, "user-two")
            XCTAssertEqual(actual.pinnedEntries.map(\.id), ["user-two"])
            XCTAssertEqual(actual.entries.first { $0.id == "user-one" }?.isEnabled, false)
        }
    }

    func testMovingBeyondTheEndClampsToTheLastPosition() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            _ = try await store.importTool(data: try definition(id: "user-move").encoded())
            let snapshot = try await store.moveTool(id: "user-move", toIndex: 99)
            XCTAssertEqual(snapshot.entries.last?.id, "user-move")
            let reopened = ToolStore(rootURL: root)
            let reloaded = try await reopened.load()
            XCTAssertEqual(reloaded.entries.last?.id, "user-move")
        }
    }

    // MARK: - Editing

    func testSaveUserToolReplacesTheDefinitionAndKeepsSettings() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let original = definition(id: "user-edited")
            _ = try await store.importTool(data: try original.encoded())
            _ = try await store.setPinned(true, toolID: original.id)
            let before = try await store.load()
            let indexBefore = before.entries.firstIndex { $0.id == original.id }

            let edited = definition(
                id: original.id, suffix: "-edited", steps: [.opencc(config: .t2s)])
            let snapshot = try await store.saveUserTool(edited)
            let entry = try XCTUnwrap(snapshot.entries.first { $0.id == edited.id })
            XCTAssertEqual(entry.definition, edited)
            XCTAssertTrue(entry.isPinned)
            XCTAssertEqual(snapshot.entries.firstIndex { $0.id == edited.id }, indexBefore)
            let exported = try await store.exportTool(id: edited.id)
            XCTAssertEqual(exported, try edited.encoded())
        }
    }

    // MARK: - Delete and undo

    func testDeletingAUserToolWritesTrashAndUndoRestoresItExactly() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let tool = definition(
                id: "user-delete", suffix: "-d", steps: [.opencc(config: .s2t)])
            _ = try await store.importTool(data: try tool.encoded())
            _ = try await store.setPinned(true, toolID: tool.id)
            _ = try await store.setEnabled(false, toolID: tool.id)
            _ = try await store.moveTool(id: tool.id, toIndex: 0)
            let before = try await store.load()
            let exportedBefore = try await store.exportTool(id: tool.id)

            let afterDelete = try await store.deleteTool(id: tool.id)
            XCTAssertFalse(afterDelete.entries.contains { $0.id == tool.id })
            XCTAssertEqual(afterDelete.undoableDeletion?.definition, tool)
            XCTAssertEqual(afterDelete.undoableDeletion?.wasEnabled, false)
            XCTAssertEqual(afterDelete.undoableDeletion?.wasPinned, true)
            XCTAssertEqual(afterDelete.undoableDeletion?.orderIndex, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: toolFile(root, id: tool.id).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: trashFile(root).path))

            let restored = try await store.undoLastDeletion()
            XCTAssertEqual(restored, before)
            let exportedAfter = try await store.exportTool(id: tool.id)
            XCTAssertEqual(exportedAfter, exportedBefore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: trashFile(root).path))
            let reopened = try await ToolStore(rootURL: root).load()
            XCTAssertNil(reopened.undoableDeletion)
            XCTAssertEqual(reopened, before)
        }
    }

    func testOnlyTheMostRecentDeletionCanBeUndone() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let first = definition(id: "user-first")
            let second = definition(id: "user-second")
            _ = try await store.importTool(data: try first.encoded())
            _ = try await store.importTool(data: try second.encoded())

            _ = try await store.deleteTool(id: first.id)
            let afterSecondDelete = try await store.deleteTool(id: second.id)
            XCTAssertEqual(afterSecondDelete.undoableDeletion?.definition.id, second.id)

            let undone = try await store.undoLastDeletion()
            let ids = undone?.entries.map(\.id) ?? []
            XCTAssertTrue(ids.contains(second.id))
            XCTAssertFalse(ids.contains(first.id))
            let nothingLeftToUndo = try await store.undoLastDeletion()
            XCTAssertNil(nothingLeftToUndo)
            XCTAssertFalse(FileManager.default.fileExists(atPath: toolFile(root, id: first.id).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: toolFile(root, id: second.id).path))
        }
    }

    func testBuiltinCannotBeDeleted() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let before = try await store.load()
            await assertStoreError(
                .builtinNotDeletable(id: BuiltinToolDefinitions.uppercaseID)
            ) {
                _ = try await store.deleteTool(id: BuiltinToolDefinitions.uppercaseID)
            }
            let after = try await store.load()
            XCTAssertEqual(after, before)
            XCTAssertNil(after.undoableDeletion)
        }
    }

    func testDeletingAnUnknownToolIsReported() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            await assertStoreError(.toolNotFound(id: "user-missing")) {
                _ = try await store.deleteTool(id: "user-missing")
            }
        }
    }

    // MARK: - Copy

    func testCopyingABuiltinGetsAFreshIdentifierAndKeepsNames() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            let seeded = try await store.load()
            let selected = try XCTUnwrap(
                seeded.entries.first {
                    $0.id == BuiltinToolDefinitions.simplificationID
                })

            let copy = try await store.duplicateTool(id: selected.id)
            XCTAssertNotEqual(copy.id, selected.definition.id)
            XCTAssertEqual(copy.name, selected.definition.name)
            XCTAssertEqual(copy.steps, selected.definition.steps)
            XCTAssertNoThrow(try copy.validate())

            let snapshot = try await store.load()
            XCTAssertEqual(snapshot.entries.last?.id, copy.id)
            XCTAssertEqual(snapshot.entries.last?.isBuiltin, false)
            XCTAssertTrue(
                snapshot.entries.contains { $0.id == selected.id && $0.isBuiltin })

            let secondCopy = try await store.duplicateTool(id: selected.id)
            XCTAssertNotEqual(secondCopy.id, copy.id)
            let exported = try await store.exportTool(id: copy.id)
            XCTAssertEqual(exported, try copy.encoded())
        }
    }

    // MARK: - Metadata

    func testCorruptMetadataIsReportedAndBlocksWrites() async throws {
        try await withTemporaryDirectory { root in
            let fm = FileManager.default
            let broken = Data("{oops".utf8)
            try broken.write(to: stateFile(root))
            let store = ToolStore(rootURL: root)

            await assertStoreError(.metadataUnavailable) {
                _ = try await store.load()
            }
            let blocked = definition(id: "user-blocked")
            await assertStoreError(.metadataUnavailable) {
                _ = try await store.importTool(data: try blocked.encoded())
            }

            XCTAssertEqual(try Data(contentsOf: stateFile(root)), broken)
            XCTAssertFalse(FileManager.default.fileExists(atPath: toolFile(root, id: blocked.id).path))
        }
    }

    func testStateFileKeepsOnlyEnableOrderAndPinFlags() async throws {
        try await withTemporaryDirectory { root in
            let store = ToolStore(rootURL: root)
            _ = try await store.importTool(data: try definition(id: "user-state").encoded())
            _ = try await store.setPinned(true, toolID: "user-state")

            let text = String(decoding: try Data(contentsOf: stateFile(root)), as: UTF8.self)
            XCTAssertTrue(text.contains("\"entries\""))
            XCTAssertTrue(text.contains("\"pinned\""))
            XCTAssertTrue(text.contains("\"enabled\""))
            XCTAssertFalse(text.contains("steps"))
            XCTAssertFalse(text.contains("formatVersion\":1,\"steps"))
        }
    }
}
