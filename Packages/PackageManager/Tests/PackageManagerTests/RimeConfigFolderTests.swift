import XCTest

@testable import PackageManager

/// The 「Rime 配置」 folder is laid over the user directory of every new generation.
final class RimeConfigFolderTests: XCTestCase {
    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func scheme() throws -> URL {
        let root = try temporaryDirectory("rime-config-scheme")
        try Data("schema:\n  schema_id: main\n  name: 主方案\n".utf8)
            .write(to: root.appendingPathComponent("main.schema.yaml"))
        try Data("schema_list:\n  - schema: main\n".utf8).write(to: root.appendingPathComponent("default.yaml"))
        return root
    }

    /// Parses every YAML file in the user directory, as a real deploy would, so a broken file fails it.
    private static let deploy: RecipePackageManager.Deploy = { deployment in
        let user = deployment.userDataURL
        for name in try FileManager.default.contentsOfDirectory(atPath: user.path) where name.hasSuffix(".yaml") {
            _ = try BoundedYAML.load(yaml: String(contentsOf: user.appendingPathComponent(name), encoding: .utf8))
        }
        let build = user.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("schema_list:\n  - schema: main\n".utf8).write(to: build.appendingPathComponent("default.yaml"))
        try Data("schema: {schema_id: main}\n".utf8).write(to: build.appendingPathComponent("main.schema.yaml"))
        return .init(availableComponents: [], validatedSchemaID: "main", validatedEnabledSchemaIDs: ["main"])
    }

    private func installed(_ manager: RecipePackageManager) async throws -> ActiveRecipe {
        let active = try await manager.activeInstallation()
        return try XCTUnwrap(active)
    }

    private func write(_ text: String, _ name: String, in folder: URL) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    func testInstallCopiesTheFolderIntoTheNewUserDirectory() async throws {
        let folder = try temporaryDirectory("rime-config")
        try write("patch:\n  menu/page_size: 9\n", "main.custom.yaml", in: folder)
        try write("你好\tni hao\n", "words.txt", in: folder)
        let manager = RecipePackageManager(
            rootURL: try temporaryDirectory("rime-config-store"), userConfigDirectory: folder)
        _ = try await manager.installSchemeImport(
            try manager.prepareSchemeImport(directory: try scheme()), deploy: Self.deploy)

        let user = try await installed(manager).userDataURL
        XCTAssertEqual(
            try String(contentsOf: user.appendingPathComponent("main.custom.yaml"), encoding: .utf8),
            "patch:\n  menu/page_size: 9\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent("words.txt").path))
    }

    func testAFileRemovedFromTheFolderIsGoneAfterTheNextInstall() async throws {
        let folder = try temporaryDirectory("rime-config")
        try write("patch: {}\n", "main.custom.yaml", in: folder)
        try write("patch: {}\n", "other.custom.yaml", in: folder)
        let manager = RecipePackageManager(
            rootURL: try temporaryDirectory("rime-config-store"), userConfigDirectory: folder)
        _ = try await manager.installSchemeImport(
            try manager.prepareSchemeImport(directory: try scheme()), deploy: Self.deploy)
        // Something the engine wrote to the user directory must survive the reapply.
        let first = try await installed(manager)
        try Data("learned".utf8).write(to: first.userDataURL.appendingPathComponent("user.yaml"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("other.custom.yaml"))

        let reinstalled = try await manager.reinstallActivePackage(deploy: Self.deploy)
        let second = try await installed(manager)
        XCTAssertNotEqual(reinstalled?.generation, first.installation.generation)
        XCTAssertEqual(second.installation.revision, first.installation.revision)
        let user = second.userDataURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent("main.custom.yaml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.appendingPathComponent("other.custom.yaml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent("user.yaml").path))
        // Files the host wrote beside the package are carried into the new generation.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: second.resourceURL.deletingLastPathComponent().appendingPathComponent("recipe-catalog.json").path))
    }

    func testOnlyFlatYamlAndTextFilesAreCopied() async throws {
        let folder = try temporaryDirectory("rime-config")
        try write("patch: {}\n", "main.custom.yaml", in: folder)
        try write("x", "notes.md", in: folder)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try write("patch: {}\n", "nested/deep.custom.yaml", in: folder)
        let manager = RecipePackageManager(
            rootURL: try temporaryDirectory("rime-config-store"), userConfigDirectory: folder)
        _ = try await manager.installSchemeImport(
            try manager.prepareSchemeImport(directory: try scheme()), deploy: Self.deploy)

        let user = try await installed(manager).userDataURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent("main.custom.yaml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.appendingPathComponent("notes.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.appendingPathComponent("nested").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.appendingPathComponent("deep.custom.yaml").path))
    }

    func testAnOversizeFileIsRefusedByNameAndNothingIsInstalled() async throws {
        let folder = try temporaryDirectory("rime-config")
        try Data(repeating: 0x61, count: RimeConfigFolder.maximumFileBytes + 1)
            .write(to: folder.appendingPathComponent("huge.dict.yaml"))
        let manager = RecipePackageManager(
            rootURL: try temporaryDirectory("rime-config-store"), userConfigDirectory: folder)
        do {
            _ = try await manager.installSchemeImport(
                try manager.prepareSchemeImport(directory: try scheme()), deploy: Self.deploy)
            XCTFail("an oversize file must refuse the install")
        } catch let error as RimeConfigFolder.RejectedFile {
            XCTAssertEqual(error.name, "huge.dict.yaml")
        }
        let active = try await manager.activeInstallation()
        XCTAssertNil(active)
    }

    func testABrokenFileThatFailsTheDeployKeepsThePreviousGeneration() async throws {
        let folder = try temporaryDirectory("rime-config")
        try write("patch: {}\n", "main.custom.yaml", in: folder)
        let manager = RecipePackageManager(
            rootURL: try temporaryDirectory("rime-config-store"), userConfigDirectory: folder)
        _ = try await manager.installSchemeImport(
            try manager.prepareSchemeImport(directory: try scheme()), deploy: Self.deploy)
        let before = try await installed(manager)

        try write("patch: [unclosed\n", "main.custom.yaml", in: folder)
        do {
            _ = try await manager.reinstallActivePackage(deploy: Self.deploy)
            XCTFail("a broken file must fail the deploy")
        } catch {}
        let after = try await installed(manager)
        XCTAssertEqual(after.installation.generation, before.installation.generation)
        XCTAssertEqual(
            try String(contentsOf: after.userDataURL.appendingPathComponent("main.custom.yaml"), encoding: .utf8),
            "patch: {}\n")
    }

    func testWithoutAFolderTheUserSnapshotIsLeftAlone() async throws {
        let manager = RecipePackageManager(rootURL: try temporaryDirectory("rime-config-store"))
        _ = try await manager.installSchemeImport(
            try manager.prepareSchemeImport(directory: try scheme()), deploy: Self.deploy)
        let first = try await installed(manager)
        try Data("patch: {}\n".utf8).write(to: first.userDataURL.appendingPathComponent("main.custom.yaml"))

        _ = try await manager.reinstallActivePackage(deploy: Self.deploy)
        let user = try await installed(manager).userDataURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent("main.custom.yaml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.appendingPathComponent(RimeConfigFolder.listFile).path))
    }
}
