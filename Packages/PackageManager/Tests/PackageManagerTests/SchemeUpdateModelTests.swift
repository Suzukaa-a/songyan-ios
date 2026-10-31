import XCTest

@testable import PackageManager

/// Updating an installed scheme from newer files keeps the grammar models the user gave it: the new
/// version does not ship them, while the user's own configuration still points at them.
final class SchemeUpdateModelTests: XCTestCase {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scheme-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func source(in root: URL, marker: String, grammarLanguage: String? = nil) throws -> URL {
        let directory = root.appendingPathComponent("source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let grammar = grammarLanguage.map { "grammar: {language: \($0)}\n" } ?? ""
        try Data(("schema: {schema_id: main, name: 主方案}\n" + grammar).utf8)
            .write(to: directory.appendingPathComponent("main.schema.yaml"))
        try Data("schema_list:\n  - schema: main\n".utf8).write(to: directory.appendingPathComponent("default.yaml"))
        try Data(marker.utf8).write(to: directory.appendingPathComponent("marker.txt"))
        try JSONEncoder().encode(SchemePackageDeclaration(id: "pkg", name: "我的方案", bindings: []))
            .write(to: directory.appendingPathComponent("keyboard-package.json"))
        return directory
    }

    private func active(_ manager: RecipePackageManager) async throws -> ActiveRecipe {
        let installed = try await manager.activeInstallation()
        return try XCTUnwrap(installed)
    }

    private static let deploy: RecipePackageManager.Deploy = { deployment in
        let build = deployment.userDataURL.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("schema_list:\n  - schema: main\n".utf8).write(to: build.appendingPathComponent("default.yaml"))
        try Data("schema: {schema_id: main}\n".utf8).write(to: build.appendingPathComponent("main.schema.yaml"))
        return .init(availableComponents: [], validatedSchemaID: "main", validatedEnabledSchemaIDs: ["main"])
    }

    /// Installs a package, then binds a model the user supplied through the grammar model flow.
    private func installWithUserModel(
        _ manager: RecipePackageManager, root: URL
    ) async throws -> (generation: String, model: RecipeFileResource) {
        let first = try manager.prepareSchemeImport(directory: try source(in: root, marker: "first"))
        let installed = try await manager.installSchemeImport(first, deploy: Self.deploy)
        let modelFile = root.appendingPathComponent("user.gram")
        try Data("a grammar model the user added".utf8).write(to: modelFile)
        let model = try RecipeFileResource.snapshot(from: modelFile, directory: root.appendingPathComponent("held"))
        let active = try await active(manager)
        let workspace = try RecipePackageManager.readRecipeWorkspaceSnapshot(
            resources: active.resourceURL, userConfiguration: active.userDataURL)
        let recipe = try GrammarModelRecipe.make(modelPath: "user.gram", bindingSchemaIDs: ["main"])
        var files = first.sourceFiles
        files[recipe.path] = recipe.source
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "pkg", selectedRecipe: recipe.declaredName!, arguments: [],
            packageFiles: files, existingFiles: workspace.files, expectedGeneration: installed.generation,
            packageFileResources: ["user.gram": model], existingFileResources: workspace.fileResources,
            providedDownloadFiles: ["user.gram": model], userCustomBaseline: workspace.userCustomFiles,
            managedGrammar: true)
        let bound = try await manager.installRecipePlan(plan, packageID: "pkg", schemaID: "main", deploy: Self.deploy)
        return (bound.generation, model)
    }

    private func installedModel(_ manager: RecipePackageManager) async throws -> Data? {
        let active = try await active(manager)
        return try? Data(contentsOf: active.resourceURL.appendingPathComponent("user.gram"))
    }

    func testUpdateKeepsAGrammarModelTheNewFilesLack() async throws {
        let root = try workspace()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let (generation, _) = try await installWithUserModel(manager, root: root)
        let boundModel = try await installedModel(manager)
        XCTAssertNotNil(boundModel, "the model is installed before the update")

        let imported = try manager.prepareSchemeImport(directory: try source(in: root, marker: "second"))
            .updatingInstallation(id: "pkg", name: "我的方案")
        XCTAssertNil(imported.fileResources["user.gram"])
        let record = try RecipePackageManager.readInstalledRecipeSources(
            resources: try await active(manager).resourceURL)
        let update = try imported.carryingModels(from: record)
        XCTAssertNotNil(update.fileResources["user.gram"])
        XCTAssertTrue(update.manifest.files.contains { $0.path == "user.gram" })
        XCTAssertNotEqual(update.manifest.revision, imported.manifest.revision)
        _ = try await manager.installSchemeImport(update, expectedGeneration: generation, deploy: Self.deploy)

        let active = try await active(manager)
        let keptModel = try await installedModel(manager)
        XCTAssertEqual(keptModel, boundModel)
        let after = try RecipePackageManager.readInstalledRecipeSources(resources: active.resourceURL)
        XCTAssertNotNil(after.fileResources["user.gram"], "the model stays in the installed record for the next update")
        let marker = try String(contentsOf: active.resourceURL.appendingPathComponent("marker.txt"), encoding: .utf8)
        XCTAssertEqual(marker, "second")
        let custom = try String(
            contentsOf: active.userDataURL.appendingPathComponent("main.custom.yaml"), encoding: .utf8)
        XCTAssertTrue(custom.contains("grammar/language"), "the user's binding is kept by the update")
    }

    func testUpdateWithoutCarryingDropsTheModel() async throws {
        let root = try workspace()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let (generation, _) = try await installWithUserModel(manager, root: root)
        let imported = try manager.prepareSchemeImport(directory: try source(in: root, marker: "second"))
            .updatingInstallation(id: "pkg", name: "我的方案")
        _ = try await manager.installSchemeImport(imported, expectedGeneration: generation, deploy: Self.deploy)
        let model = try await installedModel(manager)
        XCTAssertNil(model, "documents why the update must carry the model over")
    }

    func testPackageShippedModelWinsAndSameFilesGiveTheSameRevision() async throws {
        let root = try workspace()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        _ = try await installWithUserModel(manager, root: root)
        let record = try RecipePackageManager.readInstalledRecipeSources(
            resources: try await active(manager).resourceURL)
        let directory = try source(in: root, marker: "second")
        let first = try manager.prepareSchemeImport(directory: directory).carryingModels(from: record)
        let again = try manager.prepareSchemeImport(directory: directory).carryingModels(from: record)
        XCTAssertEqual(first.manifest.revision, again.manifest.revision)
        // A model the new files bring themselves is not replaced.
        let own = try source(in: root, marker: "third")
        let shipped = own.appendingPathComponent("user.gram")
        try Data("shipped by the package".utf8).write(to: shipped)
        let prepared = try manager.prepareSchemeImport(directory: own).carryingModels(from: record)
        XCTAssertEqual(prepared.fileResources["user.gram"]?.size, 22)
    }

    func testNothingToCarryChangesNothing() async throws {
        let root = try workspace()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let installed = try await manager.installSchemeImport(
            try manager.prepareSchemeImport(directory: try source(in: root, marker: "first")), deploy: Self.deploy)
        _ = installed
        let record = try RecipePackageManager.readInstalledRecipeSources(
            resources: try await active(manager).resourceURL)
        let prepared = try manager.prepareSchemeImport(directory: try source(in: root, marker: "second"))
        let carried = try prepared.carryingModels(from: record)
        XCTAssertEqual(carried.manifest.revision, prepared.manifest.revision)
    }
}
