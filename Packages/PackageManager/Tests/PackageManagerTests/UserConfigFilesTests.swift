import XCTest

@testable import PackageManager

/// The user's folder: which names it holds, and what a file must be to be laid over a generation.
final class UserConfigFilesTests: XCTestCase {
    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func put(_ text: String, _ path: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func problem(_ name: String, _ text: String) -> UserConfigError? {
        UserConfigFiles.check(name, Data(text.utf8))
    }

    func testOnlyTextConfigurationNamesAreFiles() {
        for name in ["main.custom.yaml", "custom_phrase.txt", "rime_ice.dict.yaml", "a.b-c+d.yaml", "rime.lua"] {
            XCTAssertTrue(UserConfigFiles.isAllowedName(name), name)
        }
        for name in [
            "", ".yaml", "notes.md", ".hidden.yaml", "a..b.yaml", "a b.yaml", "我的.txt", "a/b.yaml", "-x.yaml",
            String(repeating: "n", count: 130) + ".yaml",
        ] {
            XCTAssertFalse(UserConfigFiles.isAllowedName(name), name)
        }
        XCTAssertFalse(UserConfigFiles.isCreatableName("x.lua"))
        XCTAssertTrue(UserConfigFiles.isCreatableName("x.txt"))
    }

    func testPathsMirrorAPackageButNeverReachTheBuildFolderOrEscape() {
        for path in ["main.custom.yaml", "cn_dicts/base.dict.yaml", "a/b/c/d/e.yaml", "lua/date.lua", "rime.lua", "lua/x/y.lua"] {
            XCTAssertTrue(UserConfigFiles.isAllowedPath(path), path)
        }
        for path in [
            "build/default.yaml", "a/build/x.yaml", "../x.yaml", "a/../x.yaml", "/abs.yaml", "a//b.yaml", "a/b/c/d/e/f.yaml",
            "x.lua", "cn_dicts/x.lua", "a\\b.yaml", ".git/config.yaml",
        ] {
            XCTAssertFalse(UserConfigFiles.isAllowedPath(path), path)
        }
        XCTAssertTrue(UserConfigFiles.isScriptPath("lua/a.lua"))
        XCTAssertFalse(UserConfigFiles.isScriptPath("lua/a.yaml"))
    }

    func testTheFolderListsItsFilesWithTheirPathsAndSkipsLinksAndOtherFolders() throws {
        let folder = try temporaryDirectory("config")
        try put("patch: {}\n", "main.custom.yaml", in: folder)
        try put("a\tb\n", "cn_dicts/words.txt", in: folder)
        try put("return {}\n", "lua/date.lua", in: folder)
        try put("x", "notes.md", in: folder)
        try put("patch: {}\n", "build/default.yaml", in: folder)
        try put("patch: {}\n", "outside.yaml", in: try temporaryDirectory("elsewhere"))
        let elsewhere = try temporaryDirectory("target")
        try put("patch: {}\n", "x.yaml", in: elsewhere)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("linked.yaml"), withDestinationURL: elsewhere.appendingPathComponent("x.yaml"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("linked"), withDestinationURL: elsewhere)

        XCTAssertEqual(
            UserConfigFiles.files(in: folder).map(\.path), ["cn_dicts/words.txt", "lua/date.lua", "main.custom.yaml"])
        XCTAssertEqual(
            UserConfigFiles.listed(in: folder), ["cn_dicts/words.txt", "lua/date.lua", "main.custom.yaml"])
    }

    func testBrokenYamlIsRefusedWithItsFileNameAndLine() {
        let error = problem("main.custom.yaml", "patch:\n  a: 1\n  b: [1\n")
        XCTAssertEqual(error?.problem, .invalidYAML)
        XCTAssertEqual(error?.file, "main.custom.yaml")
        XCTAssertNotNil(error?.line)
        XCTAssertTrue(error?.errorDescription?.contains("main.custom.yaml") == true)
        XCTAssertNil(problem("main.custom.yaml", "patch:\n  a: 1\n"))
    }

    func testAByteOrderMarkIsFineButBinaryIsNotText() {
        XCTAssertNil(UserConfigFiles.check("a.yaml", Data([0xEF, 0xBB, 0xBF]) + Data("patch: {}\n".utf8)))
        XCTAssertEqual(UserConfigFiles.check("a.txt", Data([0xFF, 0xFE, 0x00]))?.problem, .notText)
        XCTAssertEqual(UserConfigFiles.check("a.txt", Data("a\u{0}b".utf8))?.problem, .notText)
    }

    func testTheSizeLimitHolds() {
        let big = Data(repeating: 0x61, count: UserConfigFiles.maximumFileBytes + 1)
        XCTAssertEqual(UserConfigFiles.check("a.txt", big)?.problem, .tooLarge)
        XCTAssertNil(UserConfigFiles.check("a.txt", big.dropLast()))
    }

    func testAFileThatNamesAFileOutsideTheFoldersIsRefusedByName() {
        let error = problem("x.custom.yaml", "patch:\n  translator/user_dict: /var/mobile/leak\n")
        XCTAssertEqual(error?.problem, .unsafeReference)
        XCTAssertEqual(error?.file, "x.custom.yaml")
        XCTAssertEqual(problem("x.custom.yaml", "patch:\n  translator/dictionary: !!null ../../x\n")?.problem, .unsafeReference)
        XCTAssertEqual(problem("x.custom.yaml", "patch:\n  menu/title/+: abc\n")?.problem, .unsafeReference)
        // The same value in a dictionary's header counts, its rows do not.
        XCTAssertEqual(
            problem("w.dict.yaml", "---\nname: w\nimport_tables: [../x]\n...\n你好\tni hao\n")?.problem, .unsafeReference)
        XCTAssertNil(problem("w.dict.yaml", "---\nname: w\n...\nimport_tables: ../x\t1\n"))
    }

    func testDeepNestingAndAliasBombsAreRefusedNotParsed() {
        XCTAssertEqual(
            problem("a.yaml", "a: " + String(repeating: "[", count: 100) + "\n")?.problem, .invalidYAML)
        var lines = ["l0: &l0 [x, x, x, x, x, x, x, x, x, x]"]
        for level in 1...9 {
            lines.append(
                "l\(level): &l\(level) [" + Array(repeating: "*l\(level - 1)", count: 10).joined(separator: ", ") + "]")
        }
        XCTAssertEqual(problem("a.yaml", lines.joined(separator: "\n") + "\n")?.problem, .invalidYAML)
    }

    func testARepeatedKeyIsReadNotRefusedAndItsHiddenPairIsChecked() {
        XCTAssertNil(problem("a.custom.yaml", "patch:\n  menu/page_size: 5\npatch:\n  menu/page_size: 7\n"))
        XCTAssertEqual(
            problem("a.custom.yaml", "__patch:\n  translator/user_dict: /abs/leak\n__patch: {}\n")?.problem,
            .unsafeReference)
    }

    // MARK: - What an install takes from the folder

    private func plan(_ folder: URL, strict: Bool, package: PackageFiles = .none) throws -> RimeConfigFolder.Plan {
        try RimeConfigFolder.plan(folder, package: package, state: UserConfigState(directory: nil), strict: strict)
    }

    func testAStrictPlanStopsAtTheFirstBadFileAndALenientOneLeavesItOut() throws {
        let folder = try temporaryDirectory("config")
        try put("patch: {}\n", "good.custom.yaml", in: folder)
        try put("patch: [unclosed\n", "bad.custom.yaml", in: folder)
        try put("patch:\n  translator/dictionary: ../../x\n", "evil.custom.yaml", in: folder)

        XCTAssertEqual(try plan(folder, strict: false).files.map(\.path), ["good.custom.yaml"])
        XCTAssertThrowsError(try plan(folder, strict: true)) {
            XCTAssertEqual(($0 as? UserConfigError)?.file, "bad.custom.yaml")
            XCTAssertEqual(($0 as? UserConfigError)?.problem, .invalidYAML)
        }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("bad.custom.yaml"))
        XCTAssertThrowsError(try plan(folder, strict: true)) {
            XCTAssertEqual(($0 as? UserConfigError)?.file, "evil.custom.yaml")
            XCTAssertEqual(($0 as? UserConfigError)?.problem, .unsafeReference)
            XCTAssertNotNil(($0 as? UserConfigError)?.errorDescription)
        }
    }

    func testTheCountAndTotalSizeCapsHold() throws {
        let folder = try temporaryDirectory("config")
        for index in 0...UserConfigFiles.maximumFiles { try put("a\n", "f\(index).txt", in: folder) }
        XCTAssertEqual(try plan(folder, strict: false).files.count, UserConfigFiles.maximumFiles)
        XCTAssertThrowsError(try plan(folder, strict: true)) {
            XCTAssertEqual(($0 as? UserConfigError)?.problem, .tooMany)
        }

        let heavy = try temporaryDirectory("heavy")
        let chunk = String(repeating: "a", count: UserConfigFiles.maximumFileBytes)
        try put(chunk, "a.txt", in: heavy)
        try put(chunk, "b.txt", in: heavy)
        try put(chunk, "c.txt", in: heavy)
        XCTAssertEqual(try plan(heavy, strict: false).files.map(\.path), ["a.txt", "b.txt"])
        XCTAssertThrowsError(try plan(heavy, strict: true)) {
            XCTAssertEqual(($0 as? UserConfigError)?.file, "c.txt")
            XCTAssertEqual(($0 as? UserConfigError)?.problem, .tooLarge)
        }
    }

    func testNamesThatDifferOnlyInCaseAreRefused() throws {
        let folder = try temporaryDirectory("config")
        try put("patch: {}\n", "Main.custom.yaml", in: folder)
        try put("patch: {}\n", "main.custom.yaml", in: folder)
        // On a case-sensitive volume both exist: the second is left out, and an explicit apply refuses.
        if UserConfigFiles.files(in: folder).count == 2 {
            XCTAssertEqual(try plan(folder, strict: false).files.count, 1)
            XCTAssertThrowsError(try plan(folder, strict: true)) {
                XCTAssertEqual(($0 as? UserConfigError)?.problem, .name)
            }
        }
    }
}
