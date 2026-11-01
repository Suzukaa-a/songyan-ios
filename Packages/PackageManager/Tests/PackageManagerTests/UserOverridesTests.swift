import XCTest

@testable import PackageManager

/// A user's file with a package file's path replaces it; the package itself is never touched.
final class UserOverridesTests: XCTestCase {
    private var folder: URL!
    private var state: URL!

    override func setUpWithError() throws {
        folder = try directory("config")
        state = try directory("state")
    }

    private func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var overrides: UserOverrides { UserOverrides(folder: folder, state: UserConfigState(directory: state)) }

    private func package(_ files: [String: String]) -> PackageFiles {
        let data = files.mapValues { Data($0.utf8) }
        return PackageFiles(hashes: data.mapValues(sha256Hex), read: { data[$0] })
    }

    private func refusal(_ block: () throws -> Void) -> UserConfigError? {
        do {
            try block()
            return nil
        } catch { return error as? UserConfigError }
    }

    func testACopyStartsFromThePackagesBytesAndLeavesThePackageAlone() throws {
        let source = package([
            "main.schema.yaml": "schema: {schema_id: main}\n", "cn_dicts/base.dict.yaml": "---\nname: base\n...\n",
        ])
        let copy = try overrides.copyOf("cn_dicts/base.dict.yaml", package: source)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "---\nname: base\n...\n")
        XCTAssertEqual(copy.path, folder.appendingPathComponent("cn_dicts/base.dict.yaml").path)
        XCTAssertEqual(source.read("cn_dicts/base.dict.yaml"), Data("---\nname: base\n...\n".utf8))
    }

    func testAnExistingCopyIsReusedNotOverwritten() throws {
        let source = package(["main.schema.yaml": "a: 1\n"])
        let copy = try overrides.copyOf("main.schema.yaml", package: source)
        try Data("a: 2\n".utf8).write(to: copy)
        _ = try overrides.copyOf("main.schema.yaml", package: source)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "a: 2\n")
    }

    func testPathsThatEscapeOrCannotBeOverridesAreRefused() {
        let source = package(["main.schema.yaml": "a: 1\n", "notes.md": "x", "build/x.yaml": "a: 1\n"])
        for path in ["../x.yaml", "/abs.yaml", "a/../main.schema.yaml", "notes.md", "build/x.yaml", "absent.yaml", ""] {
            XCTAssertEqual(refusal { _ = try overrides.copyOf(path, package: source) }?.problem, .name, path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("absent.yaml").path))
    }

    func testAFileOverTheLimitOrOneTooManyIsRefused() throws {
        let big = String(repeating: "a", count: UserConfigFiles.maximumFileBytes + 1)
        XCTAssertEqual(
            refusal { _ = try overrides.copyOf("big.txt", package: package(["big.txt": big])) }?.problem, .tooLarge)

        for index in 0..<UserConfigFiles.maximumFiles {
            try Data("a".utf8).write(to: folder.appendingPathComponent("f\(index).txt"))
        }
        XCTAssertEqual(
            refusal { _ = try overrides.copyOf("main.schema.yaml", package: package(["main.schema.yaml": "a: 1\n"])) }?
                .problem,
            .tooMany)
    }

    func testOnlyFilesThatShadowAPackageFileAreOverrides() throws {
        let source = package(["main.schema.yaml": "a: 1\n"])
        _ = try overrides.copyOf("main.schema.yaml", package: source)
        try Data("patch: {}\n".utf8).write(to: folder.appendingPathComponent("main.custom.yaml"))
        XCTAssertEqual(overrides.entries(source).map(\.path), ["main.schema.yaml"])
    }

    func testEachOverrideIsToldOnceAndAFileMadeAgainIsToldAgain() throws {
        let source = package(["main.schema.yaml": "a: 1\n", "default.yaml": "b: 1\n"])
        _ = try overrides.copyOf("main.schema.yaml", package: source)
        _ = try overrides.copyOf("default.yaml", package: source)
        XCTAssertEqual(overrides.unacknowledged(source), ["default.yaml", "main.schema.yaml"])
        overrides.acknowledge(["main.schema.yaml"])
        XCTAssertEqual(overrides.unacknowledged(source), ["default.yaml"])
        XCTAssertTrue(overrides.restore("main.schema.yaml"))
        _ = try overrides.copyOf("main.schema.yaml", package: source)
        XCTAssertEqual(overrides.unacknowledged(source), ["default.yaml", "main.schema.yaml"])
    }

    func testANewerPackageFileIsNoticedAndRestoringBringsTheNewOneBack() throws {
        let old = package(["main.schema.yaml": "a: 1\n"])
        let copy = try overrides.copyOf("main.schema.yaml", package: old)
        try Data("a: 2\n".utf8).write(to: copy)
        XCTAssertEqual(overrides.entries(old), [.init(path: "main.schema.yaml", updated: false)])

        let updated = package(["main.schema.yaml": "a: 3\n"])
        XCTAssertEqual(overrides.entries(updated), [.init(path: "main.schema.yaml", updated: true)])
        // Editing again does not take the notice away: the base stays the first one.
        overrides.recordBase("main.schema.yaml", package: updated)
        XCTAssertEqual(overrides.entries(updated), [.init(path: "main.schema.yaml", updated: true)])

        XCTAssertTrue(overrides.restore("main.schema.yaml"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(overrides.entries(updated).isEmpty)
    }

    func testAFileTheUserMadeHasNoBaseSoItIsNeverCalledUpdated() throws {
        try Data("a: 2\n".utf8).write(to: folder.appendingPathComponent("main.schema.yaml"))
        XCTAssertEqual(
            overrides.entries(package(["main.schema.yaml": "a: 3\n"])),
            [.init(path: "main.schema.yaml", updated: false)])
    }

    func testANameThatDiffersOnlyInCaseIsRefusedWhenBothCanExist() throws {
        try Data("a: 1\n".utf8).write(to: folder.appendingPathComponent("Main.schema.yaml"))
        // A case-insensitive volume maps both names to one file, so the copy is the existing file.
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("main.schema.yaml").path) else {
            return
        }
        XCTAssertEqual(
            refusal { _ = try overrides.copyOf("main.schema.yaml", package: package(["main.schema.yaml": "a: 1\n"])) }?
                .problem,
            .name)
    }

    func testALinkInTheFolderIsNotFollowed() throws {
        let elsewhere = try directory("elsewhere")
        try Data("secret: 1\n".utf8).write(to: elsewhere.appendingPathComponent("main.schema.yaml"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("cn_dicts"), withDestinationURL: elsewhere)
        XCTAssertNil(overrides.overrideFile("cn_dicts/main.schema.yaml"))
        XCTAssertNil(UserOverrides.inside(folder, "cn_dicts/main.schema.yaml"))
        XCTAssertEqual(
            refusal {
                _ = try overrides.copyOf(
                    "cn_dicts/main.schema.yaml", package: package(["cn_dicts/main.schema.yaml": "a: 1\n"]))
            }?.problem,
            .name)
        XCTAssertEqual(
            try String(contentsOf: elsewhere.appendingPathComponent("main.schema.yaml"), encoding: .utf8), "secret: 1\n"
        )
    }

    func testRestoringRemovesTheFoldersItEmptiedAndOnlyThose() throws {
        let source = package(["cn_dicts/base.dict.yaml": "---\nname: base\n...\n"])
        _ = try overrides.copyOf("cn_dicts/base.dict.yaml", package: source)
        try Data("x".utf8).write(to: folder.appendingPathComponent("keep.txt"))
        XCTAssertTrue(overrides.restore("cn_dicts/base.dict.yaml"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cn_dicts").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("keep.txt").path))
    }
}
