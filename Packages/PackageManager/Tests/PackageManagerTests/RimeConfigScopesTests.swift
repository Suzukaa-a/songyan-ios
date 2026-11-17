import XCTest

@testable import PackageManager

/// Every input scheme package keeps its own folder of the user's Rime files.
final class RimeConfigScopesTests: XCTestCase {
    private func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, _ path: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    private func scheme(_ id: String) throws -> URL {
        let root = try temporaryDirectory("rime-scope-scheme")
        try Data("schema:\n  schema_id: \(id)\n  name: \(id)\n".utf8)
            .write(to: root.appendingPathComponent("\(id).schema.yaml"))
        try Data("schema_list:\n  - schema: \(id)\n".utf8).write(to: root.appendingPathComponent("default.yaml"))
        return root
    }

    private static func deploy(_ id: String) -> RecipePackageManager.Deploy {
        { deployment in
            let build = deployment.userDataURL.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try Data("schema_list:\n  - schema: \(id)\n".utf8).write(to: build.appendingPathComponent("default.yaml"))
            try Data("schema: {schema_id: \(id)}\n".utf8).write(to: build.appendingPathComponent("\(id).schema.yaml"))
            return .init(availableComponents: [], validatedSchemaID: id, validatedEnabledSchemaIDs: [id])
        }
    }

    func testMigrationGivesEveryInstalledPackageItsOwnCopy() throws {
        let root = try temporaryDirectory("rime-config")
        let state = try temporaryDirectory("rime-state")
        try write("patch:\n  schema_list: [{schema: a}]\n", "default.custom.yaml", in: root)
        try write("-- mine\n", "lua/mine.lua", in: root)
        try write("{\"acknowledged\":[\"default.custom.yaml\"],\"bases\":{}}", "overrides.json", in: state)
        try write("{\"confirmed\":[],\"riskAccepted\":true}", "scripts-confirmed.json", in: state)
        let scopes = RimeConfigScopes(root: root, state: state)
        XCTAssertTrue(scopes.needsMigration())

        try scopes.migrate(recipients: [.init(id: "a", name: "雾凇拼音"), .init(id: "b", name: "万象拼音")])

        XCTAssertFalse(scopes.needsMigration())
        for (id, name) in [("a", "雾凇拼音"), ("b", "万象拼音")] {
            XCTAssertEqual(scopes.folderName(id), name)
            let folder = root.appendingPathComponent(name)
            XCTAssertEqual(try read("default.custom.yaml", in: folder), "patch:\n  schema_list: [{schema: a}]\n")
            XCTAssertEqual(try read("lua/mine.lua", in: folder), "-- mine\n")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: scopes.stateDirectory(id).appendingPathComponent("overrides.json").path))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: scopes.stateDirectory(id).appendingPathComponent("scripts-confirmed.json").path))
        }
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["雾凇拼音", "万象拼音"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("overrides.json").path))

        // Once done, the shared folder is never read again: a new file in the root belongs to nobody.
        try write("patch: {}\n", "default.custom.yaml", in: root)
        try scopes.migrate(recipients: [.init(id: "a", name: "雾凇拼音")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("default.custom.yaml").path))
        XCTAssertEqual(
            try read("default.custom.yaml", in: root.appendingPathComponent("雾凇拼音")),
            "patch:\n  schema_list: [{schema: a}]\n")
    }

    func testAnInterruptedMigrationKeepsWhatAPackageFolderAlreadyHas() throws {
        let root = try temporaryDirectory("rime-config")
        let state = try temporaryDirectory("rime-state")
        try write("patch: {old: 1}\n", "default.custom.yaml", in: root)
        try write("patch: {old: 1}\n", "a.custom.yaml", in: root)
        // A run that named the folders and copied one file before it was cut short.
        let record = RimeConfigScopes.Record(
            folders: ["a": "A"], migrating: true, legacy: ["a.custom.yaml", "default.custom.yaml"])
        try JSONEncoder().encode(record).write(to: state.appendingPathComponent(RimeConfigScopes.recordName))
        try write("patch: {new: 1}\n", "A/default.custom.yaml", in: root)
        let scopes = RimeConfigScopes(root: root, state: state)
        XCTAssertTrue(scopes.needsMigration())

        try scopes.migrate(recipients: [.init(id: "a", name: "A")])

        let folder = root.appendingPathComponent("A")
        XCTAssertEqual(try read("default.custom.yaml", in: folder), "patch: {new: 1}\n")
        XCTAssertEqual(try read("a.custom.yaml", in: folder), "patch: {old: 1}\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["A"])
    }

    func testNoPackageGetsAFolderBeforeTheSharedOneIsHandedOut() throws {
        let root = try temporaryDirectory("rime-config")
        let state = try temporaryDirectory("rime-state")
        try write("patch: {}\n", "default.custom.yaml", in: root)
        let scopes = RimeConfigScopes(root: root, state: state)

        XCTAssertNil(try scopes.folder("a") { "A" })
        XCTAssertTrue(scopes.needsMigration())
        try scopes.migrate(recipients: [.init(id: "a", name: "A")])
        XCTAssertEqual(try read("default.custom.yaml", in: root.appendingPathComponent("A")), "patch: {}\n")
    }

    func testWithNothingInstalledTheSharedFilesStay() throws {
        let root = try temporaryDirectory("rime-config")
        let state = try temporaryDirectory("rime-state")
        try write("patch: {}\n", "default.custom.yaml", in: root)
        let scopes = RimeConfigScopes(root: root, state: state)

        try scopes.migrate(recipients: [])

        XCTAssertFalse(scopes.needsMigration())
        XCTAssertEqual(try read("default.custom.yaml", in: root), "patch: {}\n")
    }

    func testFolderNamesStayUniqueAndTravelWithABackup() throws {
        let root = try temporaryDirectory("rime-config")
        let state = try temporaryDirectory("rime-state")
        try write("x\n", "notes.txt", in: root)
        let scopes = RimeConfigScopes(root: root, state: state)
        try scopes.migrate(recipients: [])

        XCTAssertNil(try scopes.folder("missing") { nil }, "a package that is not installed gets no folder")
        XCTAssertEqual(try scopes.folder("a") { "拼音/双拼" }?.lastPathComponent, "拼音-双拼")
        XCTAssertEqual(try scopes.folder("b") { "拼音/双拼" }?.lastPathComponent, "拼音-双拼 2")
        XCTAssertEqual(try scopes.folder("c") { "notes.txt" }?.lastPathComponent, "notes.txt 2")
        XCTAssertEqual(try scopes.folder("d") { "Build" }?.lastPathComponent, "Build Rime")
        XCTAssertEqual(try scopes.folder("e") { ".hidden" }?.lastPathComponent, "hidden")
        XCTAssertEqual(try scopes.folder("f") { "" }?.lastPathComponent, "f")
        // The name sticks when the package is renamed later.
        XCTAssertEqual(try scopes.folder("a") { "别的名字" }?.lastPathComponent, "拼音-双拼")
    }

    /// Two packages with their own folders: what the user writes while one is in use never reaches the other,
    /// whether a global `default.custom.yaml`, a patch for a schema id both ship, or a script.
    func testEditingOnePackageNeverChangesAnother() async throws {
        let root = try temporaryDirectory("rime-config")
        let state = try temporaryDirectory("rime-state")
        let scopes = RimeConfigScopes(root: root, state: state)
        try scopes.migrate(recipients: [])
        func manager(_ id: String) throws -> RecipePackageManager {
            RecipePackageManager(
                rootURL: try temporaryDirectory("rime-store-\(id)"),
                userConfigDirectory: try XCTUnwrap(try scopes.folder(id) { id.uppercased() }),
                userConfigStateDirectory: scopes.stateDirectory(id))
        }
        let a = try manager("a")
        let b = try manager("b")
        _ = try await a.installSchemeImport(
            try a.prepareSchemeImport(directory: try scheme("main")), deploy: Self.deploy("main"))
        _ = try await b.installSchemeImport(
            try b.prepareSchemeImport(directory: try scheme("main")), deploy: Self.deploy("main"))

        let savedGlobal = try await a.saveRimeConfigFile(
            RimeConfigEditor.globalPath, text: "patch:\n  menu/page_size: 3\n")
        let savedSchema = try await a.saveRimeConfigFile("main.custom.yaml", text: "patch:\n  menu/page_size: 4\n")
        XCTAssertEqual(savedGlobal, .saved)
        XCTAssertEqual(savedSchema, .saved)
        _ = try await a.createRimeScript(name: "mine")
        if case .needsConfirmation(_, let keys, _) = try await a.rimeConfigReadiness() {
            _ = try await a.rimeConfigReadiness(confirmed: keys)
        }
        _ = try await a.reinstallActivePackage(deploy: Self.deploy("main"))
        _ = try await b.reinstallActivePackage(deploy: Self.deploy("main"))

        let activeA = try await a.activeInstallation()
        let activeB = try await b.activeInstallation()
        let userA = try XCTUnwrap(activeA).userDataURL
        let userB = try XCTUnwrap(activeB).userDataURL
        XCTAssertEqual(try read("default.custom.yaml", in: userA), "patch:\n  menu/page_size: 3\n")
        XCTAssertEqual(try read("main.custom.yaml", in: userA), "patch:\n  menu/page_size: 4\n")
        for name in ["default.custom.yaml", "main.custom.yaml"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: userB.appendingPathComponent(name).path), name)
        }
        XCTAssertTrue(RimeConfigFolder.names(in: userA).contains("lua/mine.lua"))
        XCTAssertTrue(RimeConfigFolder.names(in: userB).isEmpty)
        let overviewB = try await b.rimeConfigOverview()
        let globalB = try await b.openRimeConfigFile(RimeConfigEditor.globalPath)
        XCTAssertEqual(overviewB.fileCount, 0)
        XCTAssertEqual(globalB.text, RimeConfigTemplates.customPatch())
    }
}
