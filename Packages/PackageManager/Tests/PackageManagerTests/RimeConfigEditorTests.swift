import XCTest

@testable import PackageManager

/// Editing a package file, applying the user's files, scripts and the compiled backstop, end to end.
final class RimeConfigEditorTests: XCTestCase {
    private var folder: URL!
    private var state: URL!
    private var manager: RecipePackageManager!

    private func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func scheme(lua: Bool = false) throws -> URL {
        let root = try directory("scheme")
        try Data("schema:\n  schema_id: main\n  name: 主方案\nmenu:\n  page_size: 7\n".utf8)
            .write(to: root.appendingPathComponent("main.schema.yaml"))
        try Data("schema_list:\n  - schema: main\n".utf8).write(to: root.appendingPathComponent("default.yaml"))
        if lua {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("lua"), withIntermediateDirectories: true)
            try Data("return { own = true }\n".utf8).write(to: root.appendingPathComponent("lua/own.lua"))
        }
        return root
    }

    /// Parses every YAML file in the user directory like a real deploy and compiles `extraBuild` as the schema.
    private static func deploy(compiled: String = "schema: {schema_id: main}\n") -> RecipePackageManager.Deploy {
        { deployment in
            let user = deployment.userDataURL
            for name in try FileManager.default.contentsOfDirectory(atPath: user.path) where name.hasSuffix(".yaml") {
                _ = try BoundedYAML.load(yaml: String(contentsOf: user.appendingPathComponent(name), encoding: .utf8))
            }
            let build = user.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try Data("schema_list:\n  - schema: main\n".utf8).write(to: build.appendingPathComponent("default.yaml"))
            try Data(compiled.utf8).write(to: build.appendingPathComponent("main.schema.yaml"))
            return .init(availableComponents: [], validatedSchemaID: "main", validatedEnabledSchemaIDs: ["main"])
        }
    }

    override func setUp() async throws {
        folder = try directory("config")
        state = try directory("state")
        manager = RecipePackageManager(
            rootURL: try directory("store"), userConfigDirectory: folder, userConfigStateDirectory: state)
    }

    private func install(lua: Bool = false, compiled: String = "schema: {schema_id: main}\n") async throws {
        _ = try await manager.installSchemeImport(
            try manager.prepareSchemeImport(directory: try scheme(lua: lua)), deploy: Self.deploy(compiled: compiled))
    }

    private func write(_ text: String, _ path: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func active() async throws -> ActiveRecipe {
        let current = try await manager.activeInstallation()
        return try XCTUnwrap(current)
    }

    func testEditingAPackageFileMakesACopyAndLeavesThePackageAlone() async throws {
        try await install()
        let opened = try await manager.openRimeConfigFile("main.schema.yaml")
        XCTAssertEqual(opened.text, "schema:\n  schema_id: main\n  name: 主方案\nmenu:\n  page_size: 7\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("main.schema.yaml").path))

        let saved = try await manager.saveRimeConfigFile(
            "main.schema.yaml", text: "schema:\n  schema_id: main\n  name: 我的\nmenu:\n  page_size: 5\n")
        XCTAssertEqual(saved, .saved)
        // The package's own file is as installed.
        let resources = try await active().resourceURL
        XCTAssertTrue(
            try String(contentsOf: resources.appendingPathComponent("main.schema.yaml"), encoding: .utf8).contains(
                "page_size: 7"))
        let overview = try await manager.rimeConfigOverview()
        XCTAssertEqual(overview.overrides, [RimeConfigOverride(path: "main.schema.yaml", updated: false)])
        XCTAssertEqual(overview.unacknowledged, ["main.schema.yaml"])

        // Applying lays the copy over the package's file in the new generation.
        _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
        let user = try await active().userDataURL
        XCTAssertTrue(
            try String(contentsOf: user.appendingPathComponent("main.schema.yaml"), encoding: .utf8).contains(
                "page_size: 5"))
        let againResources = try await active().resourceURL
        XCTAssertTrue(
            try String(contentsOf: againResources.appendingPathComponent("main.schema.yaml"), encoding: .utf8)
                .contains("page_size: 7"))

        // Restoring brings the package's file back after the next apply.
        try await manager.restoreRimeConfigFile("main.schema.yaml")
        _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
        let restoredUser = try await active().userDataURL
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: restoredUser.appendingPathComponent("main.schema.yaml").path))
    }

    func testAnInputMethodFileStartsAsTheTemplateAndSavingChecksIt() async throws {
        try await install()
        let opened = try await manager.openRimeConfigFile("main.custom.yaml")
        XCTAssertEqual(opened.text, RimeConfigTemplates.customPatch())
        XCTAssertTrue(opened.text.hasSuffix("patch: {}\n"))

        let broken = try await manager.saveRimeConfigFile("main.custom.yaml", text: "patch:\n  a: 1\n  b: [1\n")
        guard case .invalid(let line) = broken else { return XCTFail("refused with a line: \(broken)") }
        XCTAssertNotNil(line)
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("main.custom.yaml"), encoding: .utf8),
            RimeConfigTemplates.customPatch())

        let attempt = try await manager.saveRimeConfigFile(
            "main.custom.yaml", text: "patch:\n  translator/user_dict/=: /tmp/x\n")
        guard case .refused(let message) = attempt else { return XCTFail("refused: \(attempt)") }
        XCTAssertTrue(message.contains("main.custom.yaml"))
        let saved = try await manager.saveRimeConfigFile("main.custom.yaml", text: "patch:\n  menu/page_size: 5\n")
        XCTAssertEqual(saved, .saved)
    }

    func testOnlyPathsOfThePackageOrACustomFileCanBeOpened() async throws {
        try await install()
        for path in ["../x.yaml", "absent.yaml", "x/main.custom.yaml", "build/default.yaml", "a.lua"] {
            do {
                _ = try await manager.openRimeConfigFile(path)
                XCTFail("opened \(path)")
            } catch {}
        }
    }

    func testTheGrammarExampleIsOnlyInTheEditorUntilSaved() async throws {
        try await install()
        let opened = try await manager.openRimeConfigFile("main.custom.yaml", grammarExample: true)
        XCTAssertTrue(opened.text.contains("grammar/collocation_penalty: -14"))
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("main.custom.yaml"), encoding: .utf8),
            RimeConfigTemplates.customPatch())
    }

    func testANewScriptIsMadeUnderLuaAndNeverReplacesThePackagesOwn() async throws {
        try await install(lua: true)
        let path = try await manager.createRimeScript(name: "date_filter")
        XCTAssertEqual(path, "lua/date_filter.lua")
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8),
            RimeConfigTemplates.script(name: "date_filter"))
        do {
            _ = try await manager.createRimeScript(name: "own")
            XCTFail("a name the package uses")
        } catch is RimeScriptNameTaken {}
        for name in ["", "Bad", "a-b", "a b", String(repeating: "a", count: 41)] {
            do {
                _ = try await manager.createRimeScript(name: name)
                XCTFail(name)
            } catch {}
        }
    }

    func testAScriptWaitsForTheUsersYesAndIsLeftOutUntilThen() async throws {
        try await install()
        _ = try await manager.createRimeScript(name: "mine")
        // Unconfirmed: an install leaves it out, and an explicit apply refuses.
        var readiness = try await manager.rimeConfigReadiness()
        guard case .needsConfirmation(let scripts, let keys, let firstTime) = readiness else { return XCTFail("asks") }
        XCTAssertEqual(scripts, ["lua/mine.lua"])
        XCTAssertTrue(firstTime)
        do {
            _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
            XCTFail("an unconfirmed script")
        } catch {
            XCTAssertEqual((error as? UserConfigError)?.problem, .unconfirmedScript)
        }
        let overview = try await manager.rimeConfigOverview()
        XCTAssertEqual(overview.unusedScripts, ["lua/mine.lua"])
        // A yes for something else does not cover it.
        readiness = try await manager.rimeConfigReadiness(confirmed: ["lua/other.lua@0000"])
        XCTAssertNotEqual(readiness, .ready)

        readiness = try await manager.rimeConfigReadiness(confirmed: keys)
        XCTAssertEqual(readiness, .ready)
        _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
        let resources = try await active().resourceURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("lua/mine.lua").path))
        // The sandbox entry is generated for a generation that carries a script.
        XCTAssertNotNil(LuaSandbox.unwrap(try Data(contentsOf: resources.appendingPathComponent("rime.lua"))))

        // Changed after the yes: asked again, and only the full risk text the first time.
        try write("return {}\n-- changed\n", "lua/mine.lua")
        readiness = try await manager.rimeConfigReadiness()
        guard case .needsConfirmation(_, _, let again) = readiness else { return XCTFail("asks again") }
        XCTAssertFalse(again)
    }

    func testAnImportNeverRunsAScriptTheUserHasNotAgreedTo() async throws {
        try write("return {}\n", "lua/sneaky.lua")
        try await install()
        let resources = try await active().resourceURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: resources.appendingPathComponent("lua/sneaky.lua").path))
        XCTAssertNil(try? Data(contentsOf: resources.appendingPathComponent("rime.lua")))
        let unused = try await manager.unusedRimeConfigFiles()
        XCTAssertEqual(unused, ["lua/sneaky.lua"])
    }

    func testAPackageScriptTheUserChangedKeepsThePackagesBytesForTheNextInstall() async throws {
        try await install(lua: true)
        _ = try await manager.openRimeConfigFile("lua/own.lua")
        _ = try await manager.saveRimeConfigFile("lua/own.lua", text: "return { own = false }\n")
        guard case .needsConfirmation(_, let keys, _) = try await manager.rimeConfigReadiness() else {
            return XCTFail("a changed script of the package is the user's")
        }
        _ = try await manager.rimeConfigReadiness(confirmed: keys)
        _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
        let generation = try await active().resourceURL.deletingLastPathComponent()
        XCTAssertEqual(
            try String(contentsOf: generation.appendingPathComponent("resources/lua/own.lua"), encoding: .utf8),
            "return { own = false }\n")
        XCTAssertEqual(
            try String(contentsOf: generation.appendingPathComponent("package-originals/lua/own.lua"), encoding: .utf8),
            "return { own = true }\n")
        // Applying again, and restoring, both start from the package's own bytes.
        _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
        try await manager.restoreRimeConfigFile("lua/own.lua")
        _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
        let again = try await active().resourceURL
        XCTAssertEqual(
            try String(contentsOf: again.appendingPathComponent("lua/own.lua"), encoding: .utf8),
            "return { own = true }\n")
        let originals = again.deletingLastPathComponent().appendingPathComponent("package-originals/lua/own.lua")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originals.path))
    }

    func testAScriptTheUserDeletedDoesNotComeBackFromTheOldGeneration() async throws {
        try await install()
        _ = try await manager.createRimeScript(name: "gone")
        guard case .needsConfirmation(_, let keys, _) = try await manager.rimeConfigReadiness() else {
            return XCTFail()
        }
        _ = try await manager.rimeConfigReadiness(confirmed: keys)
        _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
        try FileManager.default.removeItem(at: folder.appendingPathComponent("lua/gone.lua"))
        _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
        let resources = try await active().resourceURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: resources.appendingPathComponent("lua/gone.lua").path))
    }

    func testALuaComponentNamedInAConfigFileNeedsTheYesToo() async throws {
        try await install()
        try write("patch:\n  engine/filters/+: [lua_filter@*date]\n", "main.custom.yaml")
        guard case .needsConfirmation(let scripts, _, _) = try await manager.rimeConfigReadiness() else {
            return XCTFail("asks")
        }
        XCTAssertEqual(scripts, ["main.custom.yaml: lua_filter@*date"])
    }

    func testAnUnsafeReferenceFailsAnExplicitApplyByNameAndKeepsTheGeneration() async throws {
        try await install()
        let before = try await active().installation.generation
        try write("patch:\n  translator/user_dict/=: /tmp/x\n", "main.custom.yaml")
        do {
            _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
            XCTFail("refused")
        } catch {
            let refusal = try XCTUnwrap(error as? UserConfigError)
            XCTAssertEqual(refusal.file, "main.custom.yaml")
            XCTAssertEqual(refusal.problem, .unsafeReference)
            XCTAssertTrue(refusal.errorDescription?.contains("main.custom.yaml") == true)
        }
        let after = try await active().installation.generation
        XCTAssertEqual(after, before)
    }

    func testTheCompiledBackstopFailsAnInstallWhoseBuildNamesAFileOutside() async throws {
        try write("patch:\n  menu/page_size: 5\n", "main.custom.yaml")
        do {
            try await install(compiled: "schema: {schema_id: main}\ntranslator:\n  user_dict: ../../leak\n")
            XCTFail("a compiled file naming a file outside")
        } catch {
            XCTAssertEqual((error as? UserConfigError)?.problem, .unsafeReference)
        }
        let none = try await manager.activeInstallation()
        XCTAssertNil(none)
    }

    func testTheCompiledBackstopFailsAComponentNobodyShippedOrAgreedTo() async throws {
        try write("patch:\n  menu/page_size: 5\n", "main.custom.yaml")
        do {
            try await install(compiled: "schema: {schema_id: main}\nengine:\n  filters:\n    - lua_filter@*sneaky\n")
            XCTFail("an unknown component")
        } catch {
            XCTAssertEqual((error as? UserConfigError)?.problem, .unconfirmedScript)
        }
    }

    func testANewerPackageVersionIsNoticedWhileTheUsersCopyStaysInUse() async throws {
        try await install()
        _ = try await manager.openRimeConfigFile("main.schema.yaml")
        // A new version of the package (a different main.schema.yaml) is installed.
        let next = try scheme()
        try Data("schema:\n  schema_id: main\n  name: 新版\n".utf8).write(
            to: next.appendingPathComponent("main.schema.yaml"))
        _ = try await manager.installSchemeImport(
            try manager.prepareSchemeImport(directory: next), deploy: Self.deploy())
        let overview = try await manager.rimeConfigOverview()
        XCTAssertEqual(overview.overrides, [RimeConfigOverride(path: "main.schema.yaml", updated: true)])
        let copied = try await active().userDataURL.appendingPathComponent("main.schema.yaml")
        XCTAssertTrue(try String(contentsOf: copied, encoding: .utf8).contains("主方案"))
        // Only the edited file stops following the package; the others are the package's.
        let files = try await manager.rimeConfigPackageFiles()
        XCTAssertTrue(files.contains("default.yaml"))
    }

    // MARK: - Custom files the app also keeps blocks in

    private let block = "__patch:\n# Rx: songyan:typo {\n  - patch/+:\n      translator/enable_correction: true\n# }\n"

    func testTheUsersLinesAndTheAppsBlocksShareOneCustomFile() throws {
        let merged = try XCTUnwrap(
            RimeConfigFolder.merged(
                "patch:\n  menu/page_size: 5\n", blocks: RimeConfigFolder.managedBlocks(in: block)))
        XCTAssertTrue(merged.contains("menu/page_size: 5"))
        XCTAssertTrue(merged.contains("# Rx: songyan:typo {"))
        XCTAssertEqual(RimeConfigFolder.managedBlocks(in: merged), RimeConfigFolder.managedBlocks(in: block))
        XCTAssertEqual(
            RimeConfigFolder.withoutManagedBlocks(merged).trimmingCharacters(in: .whitespacesAndNewlines),
            "patch:\n  menu/page_size: 5")
        XCTAssertNil(RimeConfigFolder.blocksOnly(Data("patch: {}\n".utf8)))
        XCTAssertNotNil(RimeConfigFolder.blocksOnly(Data(merged.utf8)))
    }

    func testAnAppBlockSurvivesAnApplyAndAFolderFileThatLeaves() async throws {
        try await install()
        try write("patch:\n  menu/page_size: 5\n", "main.custom.yaml")
        // The app already keeps a block in the generation's file of that name.
        var user = try await active().userDataURL
        try Data(block.utf8).write(to: user.appendingPathComponent("main.custom.yaml"))
        _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
        user = try await active().userDataURL
        var text = try String(contentsOf: user.appendingPathComponent("main.custom.yaml"), encoding: .utf8)
        XCTAssertTrue(text.contains("menu/page_size: 5"))
        XCTAssertTrue(text.contains("# Rx: songyan:typo {"))

        // The user edits their lines: the block is still there once.
        try write("patch:\n  menu/page_size: 9\n", "main.custom.yaml")
        _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
        let file = try await active().userDataURL.appendingPathComponent("main.custom.yaml")
        text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("page_size: 9"))
        XCTAssertFalse(text.contains("page_size: 5"))
        XCTAssertEqual(text.components(separatedBy: "# Rx: songyan:typo {").count, 2)

        // The file leaves the folder: the app's block stays as the app's own file.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("main.custom.yaml"))
        _ = try await manager.reinstallActivePackage(deploy: Self.deploy())
        let leftFile = try await active().userDataURL.appendingPathComponent("main.custom.yaml")
        text = try String(contentsOf: leftFile, encoding: .utf8)
        XCTAssertFalse(text.contains("page_size"))
        XCTAssertTrue(text.contains("# Rx: songyan:typo {"))
    }

    // MARK: - Templates

    func testTheCustomTemplateParsesAndPatchesNothing() throws {
        let text = RimeConfigTemplates.customPatch()
        XCTAssertNil(UserConfigFiles.check("x.custom.yaml", Data(text.utf8)))
        XCTAssertEqual(text.split(separator: "\n").filter { $0.hasPrefix("#") }.count, 4)
        guard case .map(let entries)? = try BoundedYAML.loadAsText(yaml: text) else { return XCTFail() }
        XCTAssertEqual(entries.map(\.key), ["patch"])
        XCTAssertNil(UserConfigFiles.check("lua/a.lua", Data(RimeConfigTemplates.script(name: "a").utf8)))
        XCTAssertTrue(RimeConfigTemplates.script(name: "a").contains("lua_filter@*a"))
    }

    private func uncomment(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("#   ") || $0 == "# patch:" ? String($0.dropFirst(2)) : String($0) }.joined(
                separator: "\n")
    }

    func testTheGrammarExampleFitsTheFileItIsAddedTo() throws {
        let fresh = GrammarParameterExample.appended(to: "")
        XCTAssertEqual(GrammarParameterExample.heading(for: ""), .newPatch)
        XCTAssertNil(UserConfigFiles.check("x.custom.yaml", Data(fresh.utf8)))
        XCTAssertNil(UserConfigFiles.check("x.custom.yaml", Data(uncomment(fresh).utf8)))

        let existing = "patch:\n  menu/page_size: 5\n"
        XCTAssertEqual(GrammarParameterExample.heading(for: existing), .underPatch)
        XCTAssertNil(
            UserConfigFiles.check("x.custom.yaml", Data(uncomment(GrammarParameterExample.appended(to: existing)).utf8))
        )

        XCTAssertEqual(GrammarParameterExample.heading(for: RimeConfigTemplates.customPatch()), .emptyPatch)
        // Already tuned, or already carrying the example: left alone.
        let tuned = "patch:\n  grammar/collocation_penalty: -10\n"
        XCTAssertEqual(GrammarParameterExample.appended(to: tuned), tuned)
        let once = GrammarParameterExample.appended(to: existing)
        XCTAssertEqual(GrammarParameterExample.appended(to: once), once)
    }
}
