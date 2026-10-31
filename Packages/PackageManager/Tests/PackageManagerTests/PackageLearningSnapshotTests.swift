import KeyboardCore
import XCTest
import ZIPFoundation

@testable import PackageManager

/// A scheme package may ship the learned words of its dictionaries as `*.userdb.txt`. They are not
/// source files: the package keeps its identity and tree, and the words wait for the user's answer.
final class PackageLearningSnapshotTests: XCTestCase {
    private var scratch: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent(".scratch/package-learning-\(UUID().uuidString)")
    }

    private func workspace() throws -> URL {
        let root = scratch
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private let package: [String: Data] = [
        "default.yaml": Data("schema_list:\n  - schema: main\n".utf8),
        "main.schema.yaml": Data("schema: {schema_id: main, name: Main}\ntranslator: {dictionary: main}\n".utf8),
        "main.dict.yaml": Data("---\nname: main\nversion: '1'\n...\n你\tni\t100\n".utf8),
    ]

    private func snapshot(_ name: String = "main", rows: Int = 2) -> Data {
        var lines = ["# Rime user dictionary", "#@/db_name\t\(name)", "#@/db_type\tuserdb"]
        lines += (0..<rows).map { "ni\($0) \t你\($0)\tc=1 d=1 t=1" }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func zip(_ files: [String: Data], at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, bytes) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(bytes.count),
                provider: { position, count in bytes.subdata(in: Int(position)..<(Int(position) + count)) })
        }
    }

    private func directory(_ files: [String: Data], at root: URL) throws {
        for (path, bytes) in files {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
    }

    private func manager(_ root: URL) -> RecipePackageManager {
        RecipePackageManager(rootURL: root.appendingPathComponent("store"))
    }

    func testArchiveSnapshotsAreStagedAndLeftOutOfTheSourceTree() throws {
        let root = try workspace()
        let archive = root.appendingPathComponent("with.zip")
        var files = package
        files["sync/phone/main.userdb.txt"] = snapshot("main", rows: 3)
        files["sync/phone/extra.userdb.txt"] = snapshot("extra", rows: 1)
        files["sync/.hidden.userdb.txt"] = snapshot("hidden")
        files["__MACOSX/sync/main.userdb.txt"] = snapshot("macos")
        try zip(files, at: archive)
        let prepared = try manager(root).prepareSchemeArchive(archive)
        XCTAssertEqual(prepared.learningSnapshots.snapshots.map(\.dictionary).sorted(), ["extra", "main"])
        XCTAssertEqual(prepared.learningSnapshots.snapshots.map(\.entryCount).reduce(0, +), 4)
        XCTAssertEqual(prepared.learningDictionaryCount, 2)
        XCTAssertFalse(prepared.sourceFiles.keys.contains { $0.contains("userdb") })
        XCTAssertFalse(prepared.manifest.files.contains { $0.path.contains("userdb") })
    }

    func testSnapshotsDoNotChangeThePackageIdentity() throws {
        let root = try workspace()
        let plain = root.appendingPathComponent("plain.zip")
        let with = root.appendingPathComponent("with.zip")
        try zip(package, at: plain)
        var files = package
        files["main.userdb.txt"] = snapshot()
        try zip(files, at: with)
        let a = try manager(root).prepareSchemeArchive(plain)
        let b = try manager(root).prepareSchemeArchive(with)
        XCTAssertEqual(a.declaration.id, b.declaration.id)
        XCTAssertEqual(a.manifest.revision, b.manifest.revision)
        XCTAssertEqual(a.manifest.files.map(\.path), b.manifest.files.map(\.path))
        XCTAssertEqual(a.learningDictionaryCount, 0)
        XCTAssertEqual(b.learningDictionaryCount, 1)
    }

    func testFolderAndPickedFilesStageSnapshotsToo() throws {
        let root = try workspace()
        let folder = root.appendingPathComponent("folder")
        var files = package
        files["main.userdb.txt"] = snapshot("main", rows: 2)
        try directory(files, at: folder)
        let fromFolder = try manager(root).prepareSchemeImport(directory: folder)
        XCTAssertEqual(fromFolder.learningSnapshots.snapshots.map(\.dictionary), ["main"])
        XCTAssertNil(fromFolder.sourceFiles["main.userdb.txt"])

        let picked = root.appendingPathComponent("picked")
        try directory(files, at: picked)
        let fromFiles = try manager(root).prepareSchemeImport(
            files: files.keys.sorted().map {
                DictionaryImportFile(path: $0, location: picked.appendingPathComponent($0))
            })
        XCTAssertEqual(fromFiles.learningSnapshots.snapshots.map(\.dictionary), ["main"])
        XCTAssertEqual(fromFiles.declaration.id, fromFolder.declaration.id)
        XCTAssertEqual(fromFiles.manifest.revision, fromFolder.manifest.revision)
    }

    func testOtherUserDataStaysRefused() throws {
        let root = try workspace()
        let cases: [String: Data] = [
            "luna.userdb/CURRENT": Data("x".utf8),
            "luna.userdb/main.userdb.txt": snapshot(),
            "main.userdb.bak": Data("x".utf8),
            "main.userdb": Data("x".utf8),
        ]
        for (path, bytes) in cases {
            let archive = root.appendingPathComponent(UUID().uuidString + ".zip")
            var files = package
            files[path] = bytes
            try zip(files, at: archive)
            XCTAssertThrowsError(try manager(root).prepareSchemeArchive(archive), path)
            let folder = root.appendingPathComponent(UUID().uuidString)
            try directory(files, at: folder)
            XCTAssertThrowsError(try manager(root).prepareSchemeImport(directory: folder), path)
        }
    }

    func testSnapshotOverTheBoundIsLeftOutAndNeverFailsTheImport() throws {
        let root = try workspace()
        let archive = root.appendingPathComponent("big.zip")
        var files = package
        files["main.userdb.txt"] = snapshot(rows: 2)
        var big = snapshot("big", rows: 1)
        big.append(Data(repeating: 0x20, count: RimeSnapshotCollector.maximumFileBytes + 1))
        files["big.userdb.txt"] = big
        try zip(files, at: archive)
        let prepared = try manager(root).prepareSchemeArchive(archive)
        XCTAssertEqual(prepared.learningSnapshots.snapshots.map(\.dictionary), ["main"])
        XCTAssertEqual(prepared.schemaIDs, ["main"])
    }

    func testDamagedSnapshotBringsNoLearningAndNoFailure() throws {
        let root = try workspace()
        let archive = root.appendingPathComponent("damaged.zip")
        var files = package
        files["main.userdb.txt"] = Data("not a snapshot".utf8)
        try zip(files, at: archive)
        let prepared = try manager(root).prepareSchemeArchive(archive)
        XCTAssertTrue(prepared.learningSnapshots.snapshots.isEmpty)
        XCTAssertEqual(prepared.learningDictionaryCount, 0)
    }

    func testSnapshotsSurviveUpdatingTheInstallation() throws {
        let root = try workspace()
        let archive = root.appendingPathComponent("with.zip")
        var files = package
        files["main.userdb.txt"] = snapshot()
        try zip(files, at: archive)
        let prepared = try manager(root).prepareSchemeArchive(archive)
        let updated = try prepared.updatingInstallation(id: prepared.declaration.id, name: "新名字")
        XCTAssertEqual(updated.learningDictionaryCount, 1)
    }
}

/// The answer flow: nothing is merged before the user agrees, a package that is not in use is used
/// first, and every refusal leaves the installed package alone.
final class PackageLearningMergeTests: XCTestCase {
    private let sourceKey = "user-scheme:pkg"

    private func collected() throws -> CollectedSnapshots {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("learning-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.userdb.txt")
        let text = "# Rime user dictionary\n#@/db_name\tmain\n#@/db_type\tuserdb\nni \t你\tc=1 d=1 t=1\n"
        try Data(text.utf8).write(to: file)
        return try RimeSnapshotCollector.collect(
            files: [try XCTUnwrap(DiskPickedNode(url: file)).file()], byContent: false)
    }

    private final class Log: @unchecked Sendable {
        var calls: [String] = []
        var inUse: Bool
        var source: PackageLearningSource?
        var submitted: [LearningBackupArchive] = []
        init(inUse: Bool, source: PackageLearningSource?) {
            self.inUse = inUse
            self.source = source
        }
    }

    private func merge(_ log: Log, failUse: Bool = false, snapshots: CollectedSnapshots) -> PackageLearningMerge {
        PackageLearningMerge(
            snapshots: snapshots, packageSourceID: sourceKey,
            installedRevision: { "rev-2" },
            isInUse: { log.inUse },
            putInUse: {
                log.calls.append("use")
                if failUse { throw PackageLearningError.notInUse }
                log.inUse = true
            },
            currentSource: { log.source },
            submit: { archive in
                log.calls.append("submit")
                log.submitted.append(archive)
            })
    }

    private let current = PackageLearningSource(
        sourceID: "user-scheme:pkg", resourceRevision: "rev-2", sourceName: "我的方案")

    func testPackageInUseMergesWithoutSwitching() async throws {
        let log = Log(inUse: true, source: current)
        try await merge(log, snapshots: try collected()).accept()
        XCTAssertEqual(log.calls, ["submit"])
        let archive = try XCTUnwrap(log.submitted.first)
        XCTAssertEqual(archive.sourceID, sourceKey)
        XCTAssertEqual(archive.resourceRevision, "rev-2")
        XCTAssertTrue(archive.isImport)
        XCTAssertEqual(archive.dictionaries.map(\.name), ["main"])
    }

    func testPackageNotInUseIsUsedFirst() async throws {
        let log = Log(inUse: false, source: current)
        try await merge(log, snapshots: try collected()).accept()
        XCTAssertEqual(log.calls, ["use", "submit"])
    }

    func testFailedUseSubmitsNothing() async throws {
        let log = Log(inUse: false, source: current)
        do {
            try await merge(log, failUse: true, snapshots: try collected()).accept()
            XCTFail("a package that could not be used must not merge")
        } catch {
            XCTAssertEqual(error as? PackageLearningError, .notInUse)
        }
        XCTAssertEqual(log.calls, ["use"])
    }

    func testAnotherSchemeOrRevisionInUseSubmitsNothing() async throws {
        for source in [
            PackageLearningSource(sourceID: "user-scheme:other", resourceRevision: "rev-2", sourceName: "别的"),
            PackageLearningSource(sourceID: sourceKey, resourceRevision: "rev-1", sourceName: "旧版"),
            nil,
        ] {
            let log = Log(inUse: true, source: source)
            do {
                try await merge(log, snapshots: try collected()).accept()
                XCTFail("the keyboard's source does not match the package")
            } catch {
                XCTAssertEqual(error as? PackageLearningError, .notInUse)
            }
            XCTAssertTrue(log.submitted.isEmpty)
        }
    }

    func testNothingToMergeDoesNotEvenUseThePackage() async throws {
        let log = Log(inUse: false, source: current)
        do {
            try await merge(log, snapshots: .empty).accept()
            XCTFail("an empty offer has nothing to merge")
        } catch {
            XCTAssertEqual(error as? PackageLearningError, .nothingToMerge)
        }
        XCTAssertTrue(log.calls.isEmpty)
    }
}
