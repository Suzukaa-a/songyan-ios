import Foundation
import XCTest
import ZIPFoundation

@testable import PackageManager

final class ConfigurationBackupTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("configuration-backup-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func write(_ path: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func create() throws -> (URL, ConfigurationBackupManifest) {
        try write("source/layouts/layouts.json", #"{"pages":["主布局副本","abc副本"],"selected":"主布局副本"}"#)
        try write(
            "source/recipes/active.json",
            #"{"selectedSchemaID":"wanxiang","selectedBoard":"副本","keptGenerations":{"a":"b"}}"#)
        try write("source/recipes/versions/b/resources/large.bin", String(repeating: "词库\n", count: 20000))
        try write("source/learning/archives/a.json", "学习快照")
        let sources: [ConfigurationBackupDomain: URL] = [
            .layouts: root.appendingPathComponent("source/layouts"),
            .recipes: root.appendingPathComponent("source/recipes"),
            .learning: root.appendingPathComponent("source/learning"),
        ]
        let url = root.appendingPathComponent("backup.zip")
        return (url, try ConfigurationBackupArchive.create(sources: sources, destination: url, appVersion: "test"))
    }

    func testRoundTripPreservesPagesSelectionResourcesAndLearning() throws {
        let (url, original) = try create()
        let out = root.appendingPathComponent("restored")
        let decoded = try ConfigurationBackupArchive.extract(url, to: out)
        XCTAssertEqual(decoded, original)
        for file in original.files {
            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent("source/\(file.domain.rawValue)/\(file.path)")),
                try Data(contentsOf: out.appendingPathComponent("\(file.domain.rawValue)/\(file.path)")))
        }
    }

    func testCaptureExcludesLiveDatabasesAndLockFiles() throws {
        try write("source/resources/schema.yaml", "schema")
        try write("source/user/live.userdb/data", "must not copy")
        try write("source/install.lock", "lock")
        let (_, manifest) = (
            root.appendingPathComponent("backup.zip"),
            try ConfigurationBackupArchive.create(
                sources: [.schemes: root.appendingPathComponent("source")],
                destination: root.appendingPathComponent("backup.zip"), appVersion: "test",
                include: { _, path in !path.contains(".userdb") && !path.hasSuffix(".lock") })
        )
        XCTAssertEqual(manifest.files.map(\.path), ["resources/schema.yaml"])
    }

    func testSymbolicLinksRefused() throws {
        let outside = try write("outside", "private")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("source"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("source/link"), withDestinationURL: outside)
        XCTAssertThrowsError(
            try ConfigurationBackupArchive.create(
                sources: [.layouts: root.appendingPathComponent("source")],
                destination: root.appendingPathComponent("backup.zip"), appVersion: "test"))
    }

    func testModificationDuringCaptureIsRejected() throws {
        try write("source/a", "old")
        var calls = 0
        XCTAssertThrowsError(
            try ConfigurationBackupArchive.create(
                sources: [.layouts: root.appendingPathComponent("source")],
                destination: root.appendingPathComponent("backup.zip"), appVersion: "test",
                include: { _, _ in
                    calls += 1
                    if calls == 2 {
                        try! Data("a replacement of different size".utf8).write(
                            to: self.root.appendingPathComponent("source/a"), options: .atomic)
                    }
                    return true
                }))
    }

    private func alteredArchive(_ mutate: (inout [String: Any]) -> Void, payload: String? = nil, extra: String? = nil)
        throws -> URL
    {
        let (url, _) = try create()
        let zip = try Archive(url: url, accessMode: .read)
        let directory = root.appendingPathComponent("edited")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in zip {
            let target = directory.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try zip.extract(entry, to: target)
        }
        let header = directory.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: header)) as? [String: Any])
        mutate(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: header)
        if let payload {
            let files = try XCTUnwrap(object["files"] as? [[String: Any]])
            let digest = try XCTUnwrap(
                files.first(where: { $0["domain"] as? String == "layouts" })?["sha256"] as? String)
            try Data(payload.utf8).write(to: directory.appendingPathComponent("blobs/\(digest)"))
        }
        let modified = root.appendingPathComponent("modified.zip")
        let output = try Archive(url: modified, accessMode: .create)
        for entry in zip { try output.addEntry(with: entry.path, relativeTo: directory, compressionMethod: .deflate) }
        if let extra {
            let file = try write("extra", "unlisted")
            try output.addEntry(with: extra, fileURL: file)
        }
        return modified
    }

    func testDamagedPayloadNeverProducesUsableStaging() throws {
        let url = try alteredArchive({ _ in }, payload: "tampered")
        let out = root.appendingPathComponent("restored")
        XCTAssertThrowsError(try ConfigurationBackupArchive.extract(url, to: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testFutureFormatRefused() throws {
        let url = try alteredArchive { $0["version"] = 999 }
        XCTAssertThrowsError(try ConfigurationBackupArchive.extract(url, to: root.appendingPathComponent("restored")))
    }

    func testVersionTwoDependencyArchiveRoundTripsWithoutInstallations() throws {
        try write(
            "source/dependencies/dependencies.json",
            #"{"schemes":[{"id":"wanxiang","url":"https://example.com/scheme.zip"}]}"#)
        let file = root.appendingPathComponent("portable.zip")
        let manifest = try ConfigurationBackupArchive.create(
            sources: [.dependencies: root.appendingPathComponent("source/dependencies")],
            destination: file, appVersion: "test", version: 2)
        XCTAssertEqual(manifest.version, 2)
        XCTAssertEqual(manifest.presentDomains, [.dependencies])
        XCTAssertEqual(
            try ConfigurationBackupArchive.extract(file, to: root.appendingPathComponent("restored")), manifest)
    }

    func testSharedResourcesAreStoredOnceAndRestoredToBothDomains() throws {
        try write("source/schemes/model", "same large model")
        try write("source/recipes/model", "same large model")
        let url = root.appendingPathComponent("deduplicated.zip")
        let manifest = try ConfigurationBackupArchive.create(
            sources: [
                .schemes: root.appendingPathComponent("source/schemes"),
                .recipes: root.appendingPathComponent("source/recipes"),
            ], destination: url, appVersion: "test")
        XCTAssertEqual(manifest.files.count, 2)
        let zip = try Archive(url: url, accessMode: .read)
        XCTAssertEqual(Array(zip).count, 2)  // One manifest and one shared blob.
        let destination = root.appendingPathComponent("restored")
        _ = try ConfigurationBackupArchive.extract(url, to: destination)
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("schemes/model")),
            try Data(contentsOf: destination.appendingPathComponent("recipes/model")))
    }

    func testUnlistedZipEntriesRefused() throws {
        let url = try alteredArchive({ _ in }, extra: "payload/layouts/unlisted")
        XCTAssertThrowsError(try ConfigurationBackupArchive.extract(url, to: root.appendingPathComponent("restored")))
    }

    func testTraversalRefused() throws {
        let url = try alteredArchive({ _ in }, extra: "../escaped")
        XCTAssertThrowsError(try ConfigurationBackupArchive.extract(url, to: root.appendingPathComponent("restored")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped").path))
    }

    func testNeverExtractOverExistingData() throws {
        let (url, _) = try create()
        let file = try write("restored/precious", "unchanged")
        XCTAssertThrowsError(try ConfigurationBackupArchive.extract(url, to: root.appendingPathComponent("restored")))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unchanged")
    }

    func testTransactionReplacesAndRemovesOnlySpecifiedRoots() throws {
        let first = try write("live/layouts/value", "old").deletingLastPathComponent()
        let second = try write("live/options/value", "old").deletingLastPathComponent()
        let untouched = try write("live/other/value", "precious")
        let new = try write("new/value", "new").deletingLastPathComponent()
        try ConfigurationRestoreTransaction.install(
            [
                .init(key: "layouts", source: new, destination: first),
                .init(key: "options", source: nil, destination: second),
            ], journalURL: root.appendingPathComponent("journal.json"))
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("value"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try String(contentsOf: untouched, encoding: .utf8), "precious")
    }

    func testInterruptedTransactionRestoresPreviousData() throws {
        let id = UUID()
        let target = try write("live/layouts/value", "new").deletingLastPathComponent()
        try write("live/.songyan-restore-\(id)-layouts.old/value", "old")
        let journal = try write(
            "journal.json",
            "{\"id\":\"\(id)\",\"entries\":[{\"key\":\"layouts\",\"hadOriginal\":true}],\"committed\":false}")
        try ConfigurationRestoreTransaction.recover(journalURL: journal, destinations: ["layouts": target])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("value"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
}
