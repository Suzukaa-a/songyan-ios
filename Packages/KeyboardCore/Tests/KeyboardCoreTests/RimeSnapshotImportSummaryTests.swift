import XCTest

@testable import KeyboardCore

final class RimeSnapshotImportSummaryTests: XCTestCase {
    private func collected() throws -> CollectedSnapshots {
        let data = RimeUserDbTextTests.snapshot()
        let files = [
            PickedFile(name: "a.userdb.txt") { _ in data },
            PickedFile(name: "b.userdb.txt") { _ in data },
            PickedFile(name: "c.userdb.txt") { _ in Data("x".utf8) },
        ]
        return try RimeSnapshotCollector.collect(files: files, byContent: true)
    }

    func testArchiveKeepsEverySnapshotEvenForOneDictionaryAndSurvivesTheWire() throws {
        let archive = try RimeSnapshotImportSummary.archive(
            from: collected(), sourceID: "src", resourceRevision: "rev", sourceName: "拼音")
        XCTAssertTrue(archive.isImport)
        XCTAssertEqual(archive.dictionaries.map(\.name), ["luna_pinyin", "luna_pinyin"])
        XCTAssertEqual(try LearningBackupArchive.decode(archive.encoded()), archive)
        XCTAssertNoThrow(try archive.validateIdentity(sourceID: "src", resourceRevision: "rev"))
    }

    func testOnlyImportArchivesMayRepeatADictionaryAndOtherProducersStayRefused() throws {
        let snapshot = try LearningBackupArchive.DictionarySnapshot(name: "x", data: Data("a".utf8))
        func make(_ producer: String) throws -> LearningBackupArchive {
            try LearningBackupArchive(
                producer: producer, sourceID: "s", resourceRevision: "r", sourceName: "n",
                engineVersion: "e", createdAt: Date(), dictionaries: [snapshot, snapshot])
        }
        XCTAssertNoThrow(try make(LearningBackupArchive.importProducer))
        XCTAssertThrowsError(try make(LearningBackupArchive.expectedProducer)) {
            XCTAssertEqual($0 as? LearningBackupArchiveError, .duplicateDictionaryName)
        }
        XCTAssertThrowsError(try make("someone-else")) {
            XCTAssertEqual($0 as? LearningBackupArchiveError, .unexpectedProducer)
        }
    }

    func testConfirmationNamesDictionariesEntriesSchemeAndSkippedFiles() throws {
        let text = RimeSnapshotImportSummary.confirmation(for: try collected(), sourceName: "拼音")
        XCTAssertTrue(text.contains("2 份词库，共 4 条，会并入「拼音」"))
        XCTAssertTrue(text.contains("· luna_pinyin：4 条"))
        XCTAssertTrue(text.contains("· c.userdb.txt：不是 Rime 词库文件，或者已经损坏"))
    }

    func testNothingToImportTextDependsOnWhetherAnythingWasSkipped() throws {
        let none = CollectedSnapshots(snapshots: [], skipped: [])
        XCTAssertEqual(RimeSnapshotImportSummary.nothingToImport(none), "所选的位置里没有 Rime 词库文件。")
        let skipped = CollectedSnapshots(snapshots: [], skipped: [SkippedSnapshot(fileName: "a", reason: .empty)])
        XCTAssertEqual(RimeSnapshotImportSummary.nothingToImport(skipped), "所选文件里没有能并入的词库，没有做任何修改。")
    }

    func testStoreKeepsTheImportResultLineOnSuccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-store-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LearningTransferStore(directory: directory)
        let archive = try RimeSnapshotImportSummary.archive(
            from: collected(), sourceID: "src", resourceRevision: "rev", sourceName: "拼音")
        let pending = try store.submitRestore(archive)
        let lease = try XCTUnwrap(try store.acquireWorkerLease())
        _ = try store.claim(requestID: pending.id, sourceID: "src", resourceRevision: "rev", lease: lease)
        _ = try store.readRestoreInput(requestID: pending.id, lease: lease)
        _ = try store.saveSafetyBackup(
            requestID: pending.id, lease: lease,
            archive: try LearningBackupArchive(
                sourceID: "src", resourceRevision: "rev", sourceName: "拼音", engineVersion: "1",
                createdAt: Date(),
                dictionaries: [try .init(name: "luna_pinyin", data: Data("a".utf8))]))
        let done = try store.completeRestore(
            requestID: pending.id, lease: lease, message: "已并入 2 份词库，共 4 条。")
        XCTAssertEqual(done.status, .succeeded)
        XCTAssertEqual(try store.read()?.message, "已并入 2 份词库，共 4 条。")
    }
}
