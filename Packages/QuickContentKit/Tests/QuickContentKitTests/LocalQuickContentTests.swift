import Foundation
import XCTest

@testable import QuickContentKit

final class LocalQuickContentTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testReadingMissingStorageCreatesNothing() throws {
        let url = directory()
        let store = LocalQuickContentStore(directory: url)
        XCTAssertEqual(try store.read(), LocalQuickContent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReadingExistingStorageDoesNotCreateLockOrRewriteFile() throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(LocalQuickContent())
        let file = url.appendingPathComponent("content.json")
        try bytes.write(to: file)
        let store = LocalQuickContentStore(directory: url)
        XCTAssertEqual(try store.read(), LocalQuickContent())
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.path), ["content.json"])
    }

    func testBundledKaomojiSearchAndRoundTrip() throws {
        let catalog = try SymbolCatalog.bundledDefault()
        XCTAssertTrue(catalog.search("tanshou").contains { $0.category == "kaomoji" })
        XCTAssertTrue(catalog.search("你好").contains { $0.category == "kaomoji" })
        XCTAssertEqual(try SymbolCatalog.decode(catalog.encoded()), catalog)
    }

    func testStoredClipboardHistoryFromOlderVersionsIsIgnoredAndDroppedOnSave() throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent("content.json")
        let legacy = #"{"version":1,"phrases":[],"clipboardEnabled":true,"clipboard":["old-secret"]}"#
        try Data(legacy.utf8).write(to: file)
        let store = LocalQuickContentStore(directory: url)
        XCTAssertEqual(try store.read(), LocalQuickContent())
        try store.savePhrase(CommonPhrase(text: "kept"))
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("old-secret"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("clipboard"))
    }

    func testPhraseTransferRoundTrips() throws {
        let url = directory(), otherURL = directory()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: otherURL)
        }
        let store = LocalQuickContentStore(directory: url)
        let phrase = CommonPhrase(text: "稍后回复你", shortcut: "sh")
        try store.savePhrase(phrase)
        let data = try store.exportPhrases()
        let other = LocalQuickContentStore(directory: otherURL)
        try other.importPhrases(data)
        XCTAssertEqual(try other.read().phrases, [phrase])
        let source = otherURL.appendingPathComponent("phrases.json")
        try data.write(to: source)
        XCTAssertEqual(try other.importPhrases(from: source).phrases, [phrase])
        try Data(repeating: 0x20, count: LocalQuickContentStore.maximumFileBytes + 1).write(to: source)
        XCTAssertThrowsError(try other.importPhrases(from: source))
        XCTAssertEqual(try other.read().phrases, [phrase])
        XCTAssertTrue(phrase.matches("ＳＨ"))
        try store.deletePhrase(phrase.id)
        XCTAssertEqual(try store.read().phrases, [])
    }

    func testLimitsAndCorruptionDoNotOverwriteAcceptedContent() throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalQuickContentStore(directory: url)
        XCTAssertThrowsError(try store.savePhrase(CommonPhrase(text: String(repeating: "a", count: 4097))))
        XCTAssertThrowsError(try store.savePhrase(CommonPhrase(text: "  ")))
        for index in 0..<100 { try store.savePhrase(CommonPhrase(text: "phrase \(index)")) }
        XCTAssertThrowsError(try store.savePhrase(CommonPhrase(text: "overflow")))
        XCTAssertEqual(try store.read().phrases.count, 100)
        let file = url.appendingPathComponent("content.json")
        let damaged = Data("broken".utf8)
        try damaged.write(to: file)
        XCTAssertThrowsError(try store.read())
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testMalformedPhraseImportIsActionableAndPreservesContent() throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalQuickContentStore(directory: url)
        try store.savePhrase(CommonPhrase(text: "kept"))
        XCTAssertThrowsError(try store.importPhrases(Data("broken".utf8))) { error in
            let expected = (try? LocalizedCatalog.renderings("quickContent.error.unreadable")) ?? []
            XCTAssertTrue(expected.contains(error.localizedDescription), error.localizedDescription)
        }
        XCTAssertEqual(try store.read().phrases.first?.text, "kept")
    }

    func testConcurrentWritersPreservePhrases() throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            let store = LocalQuickContentStore(directory: url)
            do { _ = try store.savePhrase(CommonPhrase(text: "phrase \(index)")) } catch {
                XCTFail(error.localizedDescription)
            }
        }
        XCTAssertEqual(try LocalQuickContentStore(directory: url).read().phrases.count, 20)
    }
}
