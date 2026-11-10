import Foundation
import XCTest
import ZIPFoundation

@testable import PackageManager

/// A package can ship librime's compiled build instead of text dictionaries. The compiled files are
/// the deployment product, so the import keeps them as file references rather than reading tens of
/// megabytes into memory. The dependency closure still decides what is missing: a dictionary with
/// neither text nor a compiled table is missing, and a text dictionary's own `import_tables` are
/// visited whether or not a compiled table sits beside it.
final class CompiledSchemeImportTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("compiled-scheme-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let directory = scratch!
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Compiled-only packages

    func testCompiledTablesSatisfyTheDictionariesTheSchemasNeed() throws {
        let files = Self.compiledPackage
        let package = try write(files, to: "package")
        let prepared = try manager().prepareSchemeImport(directory: package)

        XCTAssertEqual(prepared.schemaIDs, ["sample"])
        for path in files.keys.sorted() where path.hasPrefix("build/") {
            XCTAssertNil(prepared.preparedBytes(for: path), "\(path) must stay a file reference")
            XCTAssertNil(prepared.sourceFiles[path], "\(path) is not source text")
            let resource = try XCTUnwrap(prepared.fileResources[path], "\(path) is a package resource")
            XCTAssertEqual(resource.size, files[path]!.count)
            XCTAssertEqual(try Data(contentsOf: resource.url), files[path]!, "\(path) bytes are wrong")
            let record = try XCTUnwrap(prepared.manifest.files.first { $0.path == path })
            XCTAssertEqual(record.size, resource.size)
            XCTAssertEqual(record.sha256, resource.sha256)
        }
    }

    func testAMissingCompiledTableStillLeavesTheDictionaryMissing() throws {
        var files = Self.compiledPackage
        files["build/sample.table.bin"] = nil
        let package = try write(files, to: "package")

        XCTAssertThrowsError(try manager().prepareSchemeImport(directory: package)) { error in
            XCTAssertTrue(
                String(describing: error).contains("sample.dict.yaml"),
                "a dictionary without text or a compiled table cannot be installed: \(error)")
        }
    }

    func testAMissingImportIsNotSkippedBecauseTheDictionaryWasCompiled() throws {
        var files = Self.sourcePackageWithMissingImport
        let package = try write(files, to: "package")

        // The compiled table of `main` must not stand in for the text dictionary's own imports.
        XCTAssertThrowsError(try manager().prepareSchemeImport(directory: package)) { error in
            XCTAssertTrue(
                String(describing: error).contains("extra.dict.yaml"),
                "the imported dictionary is still required beside a compiled table: \(error)")
        }
        files["extra.dict.yaml"] = Self.dictionary(named: "extra")
        let complete = try write(files, to: "package")
        let prepared = try manager().prepareSchemeImport(directory: complete)
        XCTAssertNotNil(prepared.sourceFiles["main.dict.yaml"])
        XCTAssertNotNil(prepared.fileResources["build/main.table.bin"], "the compiled table still ships")
        XCTAssertNil(prepared.preparedBytes(for: "build/main.table.bin"))
    }

    func testAnArchiveOfCompiledTablesImportsWithoutTextDictionaries() throws {
        let archive = try zip(Self.compiledPackage, named: "compiled.zip")
        let prepared = try manager().prepareSchemeArchive(archive)

        XCTAssertEqual(prepared.schemaIDs, ["sample"])
        XCTAssertNil(prepared.preparedBytes(for: "build/sample.table.bin"))
        XCTAssertEqual(prepared.fileResources["build/sample.table.bin"]?.size, 4)
        XCTAssertEqual(prepared.fileResources["build/sample.prism.bin"]?.size, 2)
    }

    func testInstalledGenerationKeepsCompiledFilesAsResources() async throws {
        let package = try write(Self.compiledPackage, to: "install-package")
        let manager = RecipePackageManager(rootURL: scratch.appendingPathComponent("install-store"))
        let prepared = try manager.prepareSchemeImport(directory: package)
        let installed = try await manager.installSchemeImport(prepared) { deployment in
            let build = deployment.userDataURL.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try Data("schema_list:\n  - schema: sample\n".utf8)
                .write(to: build.appendingPathComponent("default.yaml"))
            try Data("schema: {schema_id: sample}\n".utf8)
                .write(to: build.appendingPathComponent("sample.schema.yaml"))
            return .init(availableComponents: [], validatedSchemaID: "sample", validatedEnabledSchemaIDs: ["sample"])
        }
        XCTAssertEqual(installed.schemaID, "sample")
        let active = try await manager.activeInstallation()
        let resources = try XCTUnwrap(active).resourceURL
        XCTAssertEqual(
            try Data(contentsOf: resources.appendingPathComponent("build/sample.table.bin")), Data([1, 2, 3, 4]),
            "the compiled table is installed with the package")
        // The source snapshot keeps recipe inputs and model references, not compiled products.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: resources.deletingLastPathComponent()
                    .appendingPathComponent("recipe-inputs/build/sample.table.bin").path))
    }

    // MARK: - Applying the user's Rime config

    /// The host applies the 「Rime 配置」 folder by reinstalling the active package from its own
    /// installed files. A compiled-only package has no text dictionaries to re-read, so the new
    /// generation must still find its compiled tables in the installed recipe snapshot. They stay
    /// file references there - the deployment product is never loaded as source bytes - and the
    /// reinstalled resources hold the same bytes. Grammar models keep their reference behavior.
    func testApplyingTheRimeConfigKeepsCompiledTablesInTheInstalledSnapshot() async throws {
        var files = Self.compiledPackage
        files["sample.gram"] = Data([21, 22, 23])
        let package = try write(files, to: "reinstall-package")
        let config = scratch.appendingPathComponent("reinstall-config")
        let configState = scratch.appendingPathComponent("reinstall-config-state")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configState, withIntermediateDirectories: true)
        let manager = RecipePackageManager(
            rootURL: scratch.appendingPathComponent("reinstall-store"),
            userConfigDirectory: config, userConfigStateDirectory: configState)
        let prepared = try manager.prepareSchemeImport(directory: package)
        let compiled = ["build/sample.table.bin", "build/sample.reverse.bin", "build/sample.prism.bin"]
        let deploy: RecipePackageManager.Deploy = { deployment in
            // The deploy compiles the schema into the user directory, as the engine does on a real run.
            let build = deployment.userDataURL.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try Data("schema_list:\n  - schema: sample\n".utf8)
                .write(to: build.appendingPathComponent("default.yaml"))
            try Data("schema: {schema_id: sample}\n".utf8)
                .write(to: build.appendingPathComponent("sample.schema.yaml"))
            return .init(availableComponents: [], validatedSchemaID: "sample", validatedEnabledSchemaIDs: ["sample"])
        }
        let installed = try await manager.installSchemeImport(prepared, deploy: deploy)
        XCTAssertEqual(installed.schemaID, "sample")
        let firstActive = try await manager.activeInstallation()
        let first = try XCTUnwrap(firstActive)

        // The production read entry: what an install records for a later reinstall.
        let snapshot = try RecipePackageManager.readInstalledRecipeSources(resources: first.resourceURL)
        for path in compiled {
            XCTAssertNil(snapshot.files[path], "\(path) is a compiled product, not source text")
        }
        XCTAssertNil(snapshot.files["sample.gram"], "a grammar model travels as a file reference")
        for path in compiled + ["sample.gram"] {
            let expected = try XCTUnwrap(prepared.fileResources[path], "\(path) is a package file reference")
            let recorded = try XCTUnwrap(
                snapshot.fileResources[path], "the installed snapshot lost \(path) as a file reference")
            XCTAssertEqual(recorded.size, expected.size)
            XCTAssertEqual(recorded.sha256, expected.sha256)
            let recordedBytes = try RecipeFileResource.reference(at: recorded.url)
            XCTAssertEqual(
                recordedBytes.sha256, expected.sha256, "the snapshot reference does not hold the installed \(path)")
        }

        // The user changes one config file; the host's apply reinstalls into a fresh generation.
        try Data("patch:\n  menu/page_size: 7\n".utf8)
            .write(to: config.appendingPathComponent("sample.custom.yaml"))
        let reinstalled = try await manager.reinstallActivePackage(deploy: deploy)
        let secondActive = try await manager.activeInstallation()
        let second = try XCTUnwrap(secondActive)
        XCTAssertEqual(reinstalled?.generation, second.installation.generation)
        XCTAssertNotEqual(second.installation.generation, first.installation.generation)

        // The reinstall starts from the snapshot: the compiled tables must survive the round trip.
        let nextSnapshot = try RecipePackageManager.readInstalledRecipeSources(resources: second.resourceURL)
        for path in compiled {
            let expected = try XCTUnwrap(prepared.fileResources[path])
            XCTAssertNil(nextSnapshot.files[path], "\(path) is a compiled product, not source text")
            let recorded = try XCTUnwrap(nextSnapshot.fileResources[path], "the reinstall lost \(path)")
            XCTAssertEqual(recorded.size, expected.size)
            XCTAssertEqual(recorded.sha256, expected.sha256)
            let reinstalledBytes = try RecipeFileResource.reference(
                at: second.resourceURL.appendingPathComponent(path))
            XCTAssertEqual(reinstalledBytes.size, expected.size)
            XCTAssertEqual(
                reinstalledBytes.sha256, expected.sha256, "the reinstalled \(path) bytes changed")
        }
        let expectedModel = try XCTUnwrap(prepared.fileResources["sample.gram"])
        let model = try XCTUnwrap(nextSnapshot.fileResources["sample.gram"], "a grammar model survives a reinstall")
        XCTAssertEqual(model.size, expectedModel.size)
        XCTAssertEqual(model.sha256, expectedModel.sha256)
    }

    /// Adding a keyboard plans a recipe over the installed package (its sources and its current
    /// workspace) and installs the result as a new generation. A compiled-only package has nothing
    /// to rebuild its tables from, so the plan must accept the compiled files and carry them over.
    func testARecipeOverACompiledPackageKeepsItsCompiledTables() async throws {
        let package = try write(Self.compiledPackage, to: "recipe-package")
        let manager = RecipePackageManager(rootURL: scratch.appendingPathComponent("recipe-store"))
        let prepared = try manager.prepareSchemeImport(directory: package)
        let deploy: RecipePackageManager.Deploy = { deployment in
            let build = deployment.userDataURL.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try Data("schema_list:\n  - schema: sample\n".utf8)
                .write(to: build.appendingPathComponent("default.yaml"))
            try Data("schema: {schema_id: sample}\n".utf8)
                .write(to: build.appendingPathComponent("sample.schema.yaml"))
            return .init(availableComponents: [], validatedSchemaID: "sample", validatedEnabledSchemaIDs: ["sample"])
        }
        _ = try await manager.installSchemeImport(prepared, deploy: deploy)
        let firstActive = try await manager.activeInstallation()
        let first = try XCTUnwrap(firstActive)

        let sources = try RecipePackageManager.readInstalledRecipeSources(resources: first.resourceURL)
        let workspace = try RecipePackageManager.readRecipeWorkspaceSnapshot(resources: first.resourceURL)
        let recipe = try DeclarativeRecipe(
            path: "keyboard-adapters.recipe.yaml",
            source: Data("recipe:\n  Rx: keyboard-adapters\n  description: adapters\n".utf8))
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "sample", selectedRecipe: "keyboard-adapters",
            arguments: [], packageFiles: sources.files, existingFiles: workspace.files,
            sourceRevision: first.installation.revision, expectedGeneration: first.installation.generation,
            packageFileResources: sources.fileResources, existingFileResources: workspace.fileResources,
            userCustomBaseline: workspace.userCustomFiles)
        _ = try await manager.installRecipePlan(plan, packageID: "sample", schemaID: "sample", deploy: deploy)

        let secondActive = try await manager.activeInstallation()
        let second = try XCTUnwrap(secondActive)
        XCTAssertNotEqual(second.installation.generation, first.installation.generation)
        for path in ["build/sample.table.bin", "build/sample.reverse.bin", "build/sample.prism.bin"] {
            let expected = try XCTUnwrap(prepared.fileResources[path])
            let installed = try RecipeFileResource.reference(at: second.resourceURL.appendingPathComponent(path))
            XCTAssertEqual(installed.sha256, expected.sha256, "the new generation lost \(path)")
        }
    }

    /// kagiroi ships its kanji and connection schemas beside the one its default.yaml lists; the
    /// import preview counted all six as input methods.
    func testOnlyTheListedSchemasAreOfferedAsInputMethods() throws {
        var files = Self.compiledPackage
        files["sample_kanji.schema.yaml"] = Data("schema:\n  schema_id: sample_kanji\n  name: Kanji\n".utf8)
        let prepared = try RecipePackageManager(rootURL: scratch.appendingPathComponent("offered-store"))
            .prepareSchemeImport(directory: try write(files, to: "offered-package"))
        XCTAssertEqual(Set(prepared.schemaIDs), ["sample", "sample_kanji"])
        XCTAssertEqual(prepared.offeredSchemaIDs, ["sample"])
    }

    func testAComponentModulePathKeepsItsDirectories() throws {
        let schema = Data(
            """
            schema:
              schema_id: japanese
              name: Japanese
            engine:
              translators:
                - lua_translator@*kagiroi/kagiroi_translator
            """.utf8)
        let files: [String: Data] = [
            "default.yaml": Data("schema_list:\n  - schema: japanese\n".utf8),
            "japanese.schema.yaml": schema,
            "lua/kagiroi/kagiroi_translator.lua": Data("return {}\n".utf8),
        ]
        let package = try write(files, to: "lua-package")
        XCTAssertNoThrow(try manager().prepareSchemeImport(directory: package))

        // The module path stays a path under lua/: one that climbs out of it is still refused.
        var climbing = files
        climbing["japanese.schema.yaml"] = Data(
            """
            schema:
              schema_id: japanese
              name: Japanese
            engine:
              translators:
                - lua_translator@*../escape
            """.utf8)
        let unsafe = try write(climbing, to: "lua-escape")
        XCTAssertThrowsError(try manager().prepareSchemeImport(directory: unsafe)) { error in
            XCTAssertTrue(
                String(describing: error).contains("依赖项路径非法"),
                "a component module path that leaves lua/ is still refused as an unsafe path: \(error)")
        }
    }

    // MARK: - The locally compiled runtime package

    private static let kagiroiSchemas = [
        "kagiroi", "kagiroi_ansikana", "kagiroi_kanji", "kagiroi_matrix", "kagiroi_romaji", "kagiroi_szromaji",
    ]

    /// Real local condition: the runtime package compiled from the pinned kagiroi source on this
    /// machine - six schemas, the default configuration, Lua, OpenCC data and the shared presets,
    /// with the local `build/*.table.bin`, `*.reverse.bin` and `*.prism.bin` and no text dictionary.
    ///
    /// Opt-in because the package weighs about 175 MB: set `KAGIROI_RUNTIME_PACKAGE` to its root. A
    /// deployment directory may keep the compiled files beside the configuration; that flat form is
    /// staged into `build/` here. A missing root skips, an unusable root fails.
    func testTheLocallyCompiledKagiroiRuntimePackageImportsEveryCompiledFile() throws {
        guard let path = ProcessInfo.processInfo.environment["KAGIROI_RUNTIME_PACKAGE"], !path.isEmpty else {
            throw XCTSkip(
                "set KAGIROI_RUNTIME_PACKAGE to the locally compiled kagiroi runtime package root "
                    + "(source configuration plus build/*.table.bin)")
        }
        let source = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            XCTFail("KAGIROI_RUNTIME_PACKAGE is not a directory: \(path)")
            return
        }
        let relative = try files(in: source)
        let dictionaries = relative.filter { $0.lowercased().hasSuffix(".dict.yaml") }
        guard dictionaries.isEmpty else {
            XCTFail("the fixture must be a compiled-only package without text dictionaries: \(dictionaries)")
            return
        }
        let schemas = relative.filter { !$0.contains("/") && $0.hasSuffix(".schema.yaml") }
        XCTAssertEqual(
            Set(schemas.map { String($0.dropLast(".schema.yaml".count)) }), Set(Self.kagiroiSchemas),
            "the package root must hold exactly the six kagiroi schemas")
        for required in [
            "default.yaml", "key_bindings.yaml", "punctuation.yaml", "symbols.yaml",
            "lua/kagiroi/kagiroi.lua", "lua/kagiroi/kagiroi_translator.lua", "opencc/kagiroi_h2k.json",
        ] {
            XCTAssertTrue(relative.contains(required), "the package is missing \(required)")
        }
        let compiled = Self.kagiroiSchemas.flatMap { id in
            ["table", "reverse", "prism"].map { "\(id).\($0).bin" }
        }
        let missing = compiled.filter { name in
            !relative.contains { $0 == name || $0 == "build/" + name }
        }
        guard missing.isEmpty else {
            XCTFail("the package lacks the compiled files the import needs: \(missing)")
            return
        }

        let package = try stagedPackage(from: source, compiled: compiled)
        let prepared = try manager().prepareSchemeImport(directory: package)

        XCTAssertEqual(Set(prepared.schemaIDs), Set(Self.kagiroiSchemas))
        for name in compiled {
            let path = "build/" + name
            let resourcePath = package.appendingPathComponent(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: resourcePath.path)
            let size = try XCTUnwrap(attributes[.size] as? Int)
            XCTAssertNil(prepared.preparedBytes(for: path), "\(name) must stay a file reference")
            let resource = try XCTUnwrap(prepared.fileResources[path], "\(name) is not part of the package")
            XCTAssertEqual(resource.size, size)
            XCTAssertTrue(
                prepared.manifest.files.contains { $0.path == path && $0.size == resource.size },
                "\(name) must be installed like every other package file")
        }
        if let path = ProcessInfo.processInfo.environment["KAGIROI_PATCH_OUT"] {
            let patch = try XCTUnwrap(prepared.preparedBytes(for: "kagiroi.custom.yaml"))
            try patch.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    // MARK: - Fixtures

    private static var compiledPackage: [String: Data] {
        [
            "default.yaml": Data("schema_list:\n  - schema: sample\n".utf8),
            "sample.schema.yaml": Data(
                """
                schema:
                  schema_id: sample
                  name: Sample
                translator:
                  dictionary: sample
                  prism: sample
                """.utf8),
            "build/sample.table.bin": Data([1, 2, 3, 4]),
            "build/sample.reverse.bin": Data([5, 6, 7]),
            "build/sample.prism.bin": Data([8, 9]),
        ]
    }

    /// Text dictionary present, one compiled table beside it, and an imported dictionary that is missing.
    private static var sourcePackageWithMissingImport: [String: Data] {
        [
            "default.yaml": Data("schema_list:\n  - schema: main\n".utf8),
            "main.schema.yaml": Data("schema:\n  schema_id: main\ntranslator:\n  dictionary: main\n".utf8),
            "main.dict.yaml": Data("---\nname: main\nversion: '1'\nimport_tables:\n  - extra\n...\n".utf8),
            "build/main.table.bin": Data([9, 8, 7]),
        ]
    }

    private static func dictionary(named name: String) -> Data {
        Data("---\nname: \(name)\nversion: '1'\n...\n".utf8)
    }

    private func manager() -> RecipePackageManager {
        RecipePackageManager(rootURL: scratch.appendingPathComponent("store-" + UUID().uuidString))
    }

    @discardableResult
    private func write(_ files: [String: Data], to name: String) throws -> URL {
        let directory = scratch.appendingPathComponent(name)
        for (path, data) in files {
            let destination = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
        }
        return directory
    }

    private func zip(_ files: [String: Data], named name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count),
                provider: { position, count in
                    data.subdata(in: Int(position)..<(Int(position) + count))
                })
        }
        return url
    }

    /// The package root with the compiled files under `build/`, the layout the import reads. A flat
    /// deployment directory is copied into that form; the source directory itself is only read.
    private func stagedPackage(from source: URL, compiled: [String]) throws -> URL {
        let relative = try files(in: source)
        if compiled.allSatisfy({ relative.contains("build/" + $0) }) { return source }
        let staged = scratch.appendingPathComponent("runtime")
        let build = staged.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        for path in relative {
            let destination =
                path.hasSuffix(".bin")
                ? build.appendingPathComponent((path as NSString).lastPathComponent)
                : staged.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appendingPathComponent(path), to: destination)
        }
        return staged
    }

    /// Every regular file of `directory`, as paths relative to it.
    private func files(in directory: URL) throws -> [String] {
        let root = directory.standardizedFileURL.path
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return [] }
        var paths: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            paths.append(String(path.dropFirst(root.count + 1)))
        }
        return paths.sorted()
    }
}
