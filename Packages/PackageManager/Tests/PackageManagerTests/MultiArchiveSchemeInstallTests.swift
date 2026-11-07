import XCTest
import ZIPFoundation

@testable import PackageManager

/// One catalogue entry can be assembled from several upstream archives. The merge has to install as one
/// package, keep every upstream licence readable, and never replace an installed scheme with a half-checked
/// merge. Which schemas a catalogue entry advertises is decided by the entry's own metadata, not by the
/// general multi-archive import, so only the upstream default.yaml entry is checked here.
final class MultiArchiveSchemeInstallTests: XCTestCase {
    /// Synthetic fixtures: A is the entry archive, B the dependency it references. Both upstream
    /// licences are LGPL-3.0, and each fixture's licence and notice name that fixture in English.
    private static let entrySchemaID = "bopomofo_tw"
    private static let entryLicense = "Fixture A: LGPL-3.0 upstream license text\n"
    private static let dependencyLicense = "Fixture B: LGPL-3.0 upstream license text\n"
    private static let entryNotice = "Fixture A: upstream NOTICE text\n"
    private static let dependencyNotice = "Fixture B: upstream NOTICE text\n"
    private static let entryReadme = "Fixture A: README text\n"
    private static let dependencyReadme = "Fixture B: README text\n"

    /// Fixture A, the entry archive: one schema that needs a dictionary and a companion schema.
    private static let bopomofoArchive: [String: Data] = [
        "default.yaml": Data("schema_list:\n  - schema: bopomofo_tw\n".utf8),
        "bopomofo_tw.schema.yaml": Data(
            """
            schema:
              schema_id: bopomofo_tw
              name: 注音
              dependencies: [terra_pinyin]
            translator:
              dictionary: terra_pinyin

            """.utf8),
        "LICENSE": Data(MultiArchiveSchemeInstallTests.entryLicense.utf8),
        "NOTICE": Data(MultiArchiveSchemeInstallTests.entryNotice.utf8),
        "README.md": Data(MultiArchiveSchemeInstallTests.entryReadme.utf8),
    ]

    /// Fixture B, the dependency archive: its own schema and dictionary, plus same-named licence and notice.
    private static let terraPinyinArchive: [String: Data] = [
        "terra_pinyin.schema.yaml": Data(
            """
            schema:
              schema_id: terra_pinyin
              name: 地球拼音
            translator:
              dictionary: terra_pinyin

            """.utf8),
        "default.yaml": Data("schema_list:\n  - schema: terra_pinyin\n".utf8),
        "terra_pinyin.dict.yaml": Data("---\nname: terra_pinyin\nversion: '1'\n...\n你\tni\t100\n".utf8),
        "LICENSE": Data(MultiArchiveSchemeInstallTests.dependencyLicense.utf8),
        "NOTICE": Data(MultiArchiveSchemeInstallTests.dependencyNotice.utf8),
        "README.md": Data(MultiArchiveSchemeInstallTests.dependencyReadme.utf8),
    ]

    /// Fixture C: another archive that ships the dependency dictionary under the same name but with
    /// different content, as a broken or divergent upstream fork does.
    private static let conflictingTerraPinyinArchive: [String: Data] = [
        "terra_pinyin.dict.yaml": Data("---\nname: terra_pinyin\nversion: '2'\n...\n你\tni\t200\n".utf8)
    ]

    func testTwoArchivesMergeIntoOneInstallablePackage() async throws {
        let root = try temporaryDirectory()
        let store = root.appendingPathComponent("store")
        let manager = RecipePackageManager(rootURL: store)
        let prepared = try manager.prepareSync([
            try archive(Self.bopomofoArchive, named: "rime-bopomofo.zip", in: root),
            try archive(Self.terraPinyinArchive, named: "rime-terra-pinyin.zip", in: root),
        ])

        // The entry point still follows the entry archive's default.yaml, and everything that schema
        // references is present in the merged file set.
        XCTAssertEqual(prepared.manifest.schemaID, Self.entrySchemaID)
        XCTAssertTrue(prepared.schemaIDs.contains(Self.entrySchemaID))
        XCTAssertEqual(prepared.sourceFiles["default.yaml"], Self.bopomofoArchive["default.yaml"])
        XCTAssertEqual(
            prepared.sourceFiles["terra_pinyin.dict.yaml"],
            Self.terraPinyinArchive["terra_pinyin.dict.yaml"])
        XCTAssertEqual(
            prepared.sourceFiles["terra_pinyin.schema.yaml"],
            Self.terraPinyinArchive["terra_pinyin.schema.yaml"])
        XCTAssertNoThrow(try SchemeSourceCheck.dependencies(prepared.sourceFiles))

        // The merged package installs as one generation, and the dependency bytes land where librime
        // reads them instead of being dropped by archive-unwrapping.
        let installed = try await manager.installSchemeImport(prepared, deploy: Self.deploy)
        let current = try await manager.activeInstallation()
        let active = try XCTUnwrap(current)
        XCTAssertEqual(active.installation.generation, installed.generation)
        XCTAssertEqual(
            try Data(contentsOf: active.resourceURL.appendingPathComponent("terra_pinyin.dict.yaml")),
            Self.terraPinyinArchive["terra_pinyin.dict.yaml"])
    }

    func testTheMergeKeepsEveryUpstreamLicenseWithoutOverwritingTheOther() async throws {
        let root = try temporaryDirectory()
        let store = root.appendingPathComponent("store")
        let manager = RecipePackageManager(rootURL: store)
        let prepared = try manager.prepareSync([
            try archive(Self.bopomofoArchive, named: "rime-bopomofo.zip", in: root),
            try archive(Self.terraPinyinArchive, named: "rime-terra-pinyin.zip", in: root),
        ])
        _ = try await manager.installSchemeImport(prepared, deploy: Self.deploy)
        let current = try await manager.activeInstallation()
        let active = try XCTUnwrap(current)
        let installed = try installedResourceTexts(at: active.resourceURL)

        let texts = [
            Self.entryLicense, Self.dependencyLicense, Self.entryNotice, Self.dependencyNotice,
            Self.entryReadme, Self.dependencyReadme,
        ]
        var paths: [String] = []
        for text in texts {
            let matches = installed.filter { $0.value == text }.map(\.key)
            XCTAssertFalse(
                matches.isEmpty, "安装后的资源里找不到：\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            paths.append(try XCTUnwrap(matches.first))
        }
        XCTAssertEqual(Set(paths).count, texts.count, "同名的 LICENSE/NOTICE 不能互相覆盖")
    }

    func testAMissingDependencyIsRefusedAndTheInstalledSchemeStaysUntouched() async throws {
        let root = try temporaryDirectory()
        let store = root.appendingPathComponent("store")
        let manager = RecipePackageManager(rootURL: store)
        let entry = try archive(Self.bopomofoArchive, named: "rime-bopomofo.zip", in: root)
        let dependency = try archive(Self.terraPinyinArchive, named: "rime-terra-pinyin.zip", in: root)
        let installed = try await manager.installSchemeImport(
            try manager.prepareSync([entry, dependency]), deploy: Self.deploy)
        let generationsBefore = try generationNames(in: store)
        XCTAssertEqual(generationsBefore, [installed.generation])

        // A dependency archive that lost the dictionary its schema needs must be refused by the merge.
        var incomplete = Self.terraPinyinArchive
        incomplete["terra_pinyin.dict.yaml"] = nil
        let broken = try archive(incomplete, named: "rime-terra-pinyin-incomplete.zip", in: root)
        XCTAssertThrowsError(try manager.prepareSync([entry, broken])) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(description.contains("terra_pinyin.dict.yaml"), description)
        }

        // Refused before any commit: the installed generation, its files and the store stay as they were.
        let current = try await manager.activeInstallation()
        let active = try XCTUnwrap(current)
        XCTAssertEqual(active.installation.generation, installed.generation)
        XCTAssertEqual(try generationNames(in: store), generationsBefore)
        XCTAssertEqual(
            try Data(contentsOf: active.resourceURL.appendingPathComponent("bopomofo_tw.schema.yaml")),
            Self.bopomofoArchive["bopomofo_tw.schema.yaml"])
    }

    /// Different bytes under the same runtime path cannot be resolved: a later archive's schema would
    /// silently read the earlier archive's file instead of its own. The merge must refuse, not alias.
    func testDifferentRuntimeFilesWithTheSameNameAreRefusedInsteadOfAliased() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let entry = try archive(Self.bopomofoArchive, named: "rime-bopomofo.zip", in: root)
        let dependency = try archive(Self.terraPinyinArchive, named: "rime-terra-pinyin.zip", in: root)
        let conflicting = try archive(
            Self.conflictingTerraPinyinArchive, named: "rime-terra-pinyin-fork.zip", in: root)
        XCTAssertThrowsError(try manager.prepareSync([entry, dependency, conflicting])) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(description.contains("terra_pinyin.dict.yaml"), description)
        }
    }

    /// Identical bytes under the same runtime path are one file, not two competing copies.
    func testIdenticalRuntimeFilesAreReusedInsteadOfDuplicated() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let entry = try archive(Self.bopomofoArchive, named: "rime-bopomofo.zip", in: root)
        let dependency = try archive(Self.terraPinyinArchive, named: "rime-terra-pinyin.zip", in: root)
        let duplicate = try archive(Self.terraPinyinArchive, named: "rime-terra-pinyin-copy.zip", in: root)
        let prepared = try manager.prepareSync([entry, dependency, duplicate])
        let copies = prepared.sourceFiles.keys.filter { $0.hasSuffix("terra_pinyin.dict.yaml") }
        XCTAssertEqual(copies.count, 1, "同内容的运行时文件只保留一份：\(copies.sorted())")
        let copy = try XCTUnwrap(copies.first)
        XCTAssertEqual(prepared.sourceFiles[copy], Self.terraPinyinArchive["terra_pinyin.dict.yaml"])
    }

    func testRecommendedDownloadRejectsBytesThatChangedAfterTheCatalogChecksumWasRecorded() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let urls = [
            try archive(Self.bopomofoArchive, named: "entry.zip", in: root),
            try archive(Self.terraPinyinArchive, named: "dependency.zip", in: root),
        ]
        let source = try recommendation(archives: urls)
        let handle = try FileHandle(forWritingTo: urls[0])
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        XCTAssertThrowsError(try manager.prepareRecommended(source, archiveURLs: urls)) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(description.contains("校验"), description)
        }
    }

    func testRecommendedPreparationAdvertisesOnlyItsEntryWhileKeepingDependencyFiles() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let urls = [
            try archive(Self.bopomofoArchive, named: "entry.zip", in: root),
            try archive(Self.terraPinyinArchive, named: "dependency.zip", in: root),
        ]
        let prepared = try manager.prepareRecommended(try recommendation(archives: urls), archiveURLs: urls)
        XCTAssertEqual(prepared.schemaIDs, [Self.entrySchemaID])
        XCTAssertEqual(prepared.manifest.schemaID, Self.entrySchemaID)
        XCTAssertNotNil(prepared.sourceFiles["terra_pinyin.schema.yaml"])
        XCTAssertNotNil(prepared.sourceFiles["terra_pinyin.dict.yaml"])
    }

    func testRecommendedPreparationRequiresEveryDeclaredArchive() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let urls = [
            try archive(Self.bopomofoArchive, named: "entry.zip", in: root),
            try archive(Self.terraPinyinArchive, named: "dependency.zip", in: root),
        ]
        let source = try recommendation(archives: urls)
        XCTAssertThrowsError(try manager.prepareRecommended(source, archiveURLs: [urls[0]])) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(description.contains("下载"), description)
        }
    }

    private func recommendation(
        archives: [URL], advertised: [String] = [MultiArchiveSchemeInstallTests.entrySchemaID]
    ) throws -> RecommendedSchemeSource {
        let homepage = URL(string: "https://example.com/upstream")!
        return RecommendedSchemeSource(
            id: "fixture", nameKey: "fixture.name", detailKey: "fixture.detail", languageTag: "zh-Hant",
            archives: try archives.map { url in
                let data = try Data(contentsOf: url)
                return RecommendedSchemeArchive(
                    id: url.lastPathComponent, url: homepage.appendingPathComponent(url.lastPathComponent),
                    homepage: homepage, sha256: sha256Hex(data), byteCountHint: Int64(data.count),
                    licenses: [RecommendedSchemeLicense(name: "LGPL-3.0", url: homepage)])
            }, advertisedSchemaIDs: advertised)
    }

    // MARK: - Boundaries a merge must keep

    /// A dependency's default.yaml is its own enable list, never the entry's. Without a shipped
    /// entry default the frontend generates one; adopting the dependency's would publish a list
    /// that has nothing to do with the package's entry.
    func testDependencyDefaultIsNeverThePublishedSchemaList() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        var entry = Self.bopomofoArchive
        entry["default.yaml"] = nil
        let entryURL = try archive(entry, named: "rime-bopomofo.zip", in: root)
        let dependency = try archive(Self.terraPinyinArchive, named: "rime-terra-pinyin.zip", in: root)
        let prepared = try manager.prepareSync([entryURL, dependency])
        let defaults = try XCTUnwrap(prepared.preparedBytes(for: "default.yaml"))
        let text = String(decoding: defaults, as: UTF8.self)
        XCTAssertNotEqual(defaults, Self.terraPinyinArchive["default.yaml"])
        // An ordinary import still publishes every input method the merged package provides.
        XCTAssertTrue(text.contains("schema: bopomofo_tw"), text)
        XCTAssertTrue(text.contains("schema: terra_pinyin"), text)
    }

    /// The catalogue entry decides the installed input method list; a shipped default.yaml keeps
    /// its other settings but publishes exactly the advertised list.
    func testAdvertisedInputMethodsReplaceAShippedDefaultSchemaList() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        var entry = Self.bopomofoArchive
        entry["default.yaml"] = Data("schema_list:\n  - schema: terra_pinyin\nkey_bindings: {}\n".utf8)
        let entryURL = try archive(entry, named: "entry.zip", in: root)
        let dependency = try archive(Self.terraPinyinArchive, named: "dependency.zip", in: root)
        let source = try recommendation(archives: [entryURL, dependency])
        let prepared = try manager.prepareRecommended(source, archiveURLs: [entryURL, dependency])
        XCTAssertEqual(prepared.schemaIDs, [Self.entrySchemaID])
        let defaults = try XCTUnwrap(prepared.preparedBytes(for: "default.yaml"))
        let text = String(decoding: defaults, as: UTF8.self)
        XCTAssertTrue(text.contains("- schema: \(Self.entrySchemaID)"), text)
        XCTAssertFalse(text.contains("terra_pinyin"), text)
    }

    /// A shipped schema_list patch would override the catalogue choice after deployment. It is
    /// refused rather than stripped, so the author's patch is never silently rewritten.
    func testAuthorSchemaListPatchMustAgreeWithTheCatalogue() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        var entry = Self.bopomofoArchive
        entry["default.custom.yaml"] = Data("patch:\n  schema_list:\n    - schema: terra_pinyin\n".utf8)
        let conflicting = try archive(entry, named: "entry-conflict.zip", in: root)
        let dependency = try archive(Self.terraPinyinArchive, named: "dependency.zip", in: root)
        let conflictingSource = try recommendation(archives: [conflicting, dependency])
        XCTAssertThrowsError(
            try manager.prepareRecommended(conflictingSource, archiveURLs: [conflicting, dependency])
        ) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(description.contains("推荐目录"), description)
        }
        entry["default.custom.yaml"] = Data("patch:\n  schema_list:\n    - schema: bopomofo_tw\n".utf8)
        let agreeing = try archive(entry, named: "entry-agreeing.zip", in: root)
        let agreeingSource = try recommendation(archives: [agreeing, dependency])
        let prepared = try manager.prepareRecommended(agreeingSource, archiveURLs: [agreeing, dependency])
        XCTAssertNotNil(prepared.sourceFiles["default.custom.yaml"], "the author's patch is kept")
        XCTAssertEqual(prepared.schemaIDs, [Self.entrySchemaID])
    }

    /// A single-archive entry still restricts the installed input methods to its advertised list.
    func testSingleArchiveRecommendationRestrictsItsInputMethods() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let url = try archive(Self.twoSchemaArchive, named: "single.zip", in: root)
        let source = try recommendation(archives: [url], advertised: ["alpha"])
        let prepared = try manager.prepareRecommended(source, archiveURLs: [url])
        XCTAssertEqual(prepared.schemaIDs, ["alpha"])
        XCTAssertEqual(prepared.manifest.schemaID, "alpha")
        let defaults = try XCTUnwrap(prepared.preparedBytes(for: "default.yaml"))
        let text = String(decoding: defaults, as: UTF8.self)
        XCTAssertTrue(text.contains("- schema: alpha"), text)
        XCTAssertFalse(text.contains("beta"), text)
    }

    /// User databases are private learning data, never package source, exactly as for one archive.
    func testUserDatabasePathsAreRefusedLikeASinglePackage() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let entry = try archive(Self.bopomofoArchive, named: "rime-bopomofo.zip", in: root)
        for (index, path) in ["lunar.userdb/000001.mdb", "terra_pinyin.userdb/terra_pinyin.userdb.txt"]
            .enumerated()
        {
            var dependency = Self.terraPinyinArchive
            dependency[path] = Data("private user data".utf8)
            let url = try archive(dependency, named: "dependency-userdb-\(index).zip", in: root)
            XCTAssertThrowsError(try manager.prepareSync([entry, url]), path) { error in
                let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                XCTAssertTrue(description.contains("用户数据"), description)
            }
        }
    }

    /// A shipped `*.userdb.txt` snapshot is offered for merging and never installed as source.
    func testShippedSnapshotsAreOfferedButNotInstalled() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let entry = try archive(Self.bopomofoArchive, named: "rime-bopomofo.zip", in: root)
        var dependency = Self.terraPinyinArchive
        dependency["terra_pinyin.userdb.txt"] = Data(Self.snapshotText.utf8)
        let url = try archive(dependency, named: "dependency.zip", in: root)
        let prepared = try manager.prepareSync([entry, url])
        XCTAssertEqual(prepared.learningDictionaryCount, 1)
        XCTAssertFalse(prepared.sourceFiles.keys.contains { $0.hasSuffix(".userdb.txt") })
    }

    /// Models keep travelling as file references (never in-memory Data) and a root prediction
    /// database is validated before it may be installed.
    func testModelFilesStayFileReferencesAndDatabasesAreValidated() async throws {
        let root = try temporaryDirectory()
        let store = root.appendingPathComponent("store")
        let manager = RecipePackageManager(rootURL: store)
        let entry = try archive(Self.bopomofoArchive, named: "rime-bopomofo.zip", in: root)
        var dependency = Self.terraPinyinArchive
        dependency["model.gram"] = Data(repeating: 7, count: 4096)
        dependency["songyan-predict.db"] = Self.predictionDatabase()
        // A nested .db is an ordinary source file, not a root prediction database.
        dependency["lua/lunar.db"] = Data("nested".utf8)
        let url = try archive(dependency, named: "dependency.zip", in: root)
        let prepared = try manager.prepareSync([entry, url])
        XCTAssertNotNil(prepared.fileResources["model.gram"])
        XCTAssertNotNil(prepared.fileResources["songyan-predict.db"])
        XCTAssertNil(prepared.sourceFiles["model.gram"])
        XCTAssertNotNil(prepared.sourceFiles["lua/lunar.db"])
        _ = try await manager.installSchemeImport(prepared, deploy: Self.deploy)
        let current = try await manager.activeInstallation()
        let active = try XCTUnwrap(current)
        XCTAssertEqual(
            try Data(contentsOf: active.resourceURL.appendingPathComponent("model.gram")).count, 4096)
        var invalid = Self.terraPinyinArchive
        invalid["songyan-predict.db"] = Data("not a prediction database".utf8)
        let invalidURL = try archive(invalid, named: "dependency-invalid.zip", in: root)
        XCTAssertThrowsError(try manager.prepareSync([entry, invalidURL])) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(description.contains("联想词库"), description)
        }
    }

    /// Several archives share one compressed budget; the second transfer may only use what the
    /// first left, and the whole set is refused before anything is unpacked.
    func testCompressedArchiveBudgetIsCumulative() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let cap = Int64(RecipeResourceBudget.archiveFile)
        XCTAssertNoThrow(try RecipeResourceBudget.validateArchives([cap]))
        XCTAssertNoThrow(try RecipeResourceBudget.validateArchives([cap - 1, 1]))
        XCTAssertThrowsError(try RecipeResourceBudget.validateArchives([cap, 1]))
        // A sparse archive already at the cap: its bytes are never read, only the size is checked.
        let large = root.appendingPathComponent("large.zip")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let writer = try FileHandle(forWritingTo: large)
        try writer.truncate(atOffset: UInt64(RecipeResourceBudget.archiveFile))
        try writer.close()
        let small = try archive(Self.bopomofoArchive, named: "small.zip", in: root)
        XCTAssertThrowsError(try manager.prepareSync([large, small])) { error in
            let description = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(description.contains("总大小"), description)
        }
    }

    /// Attribution files can carry a runtime extension (LICENSE.txt). Their notice meaning wins,
    /// so two upstream copies are both kept instead of refusing the merge.
    func testTwoArchivesMayEachShipTheirOwnLicenseTxt() throws {
        let root = try temporaryDirectory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        var entry = Self.bopomofoArchive
        entry["LICENSE.txt"] = Data("Fixture A: LICENSE.txt text\n".utf8)
        var dependency = Self.terraPinyinArchive
        dependency["LICENSE.txt"] = Data("Fixture B: LICENSE.txt text\n".utf8)
        let entryURL = try archive(entry, named: "rime-bopomofo.zip", in: root)
        let dependencyURL = try archive(dependency, named: "rime-terra-pinyin.zip", in: root)
        let prepared = try manager.prepareSync([entryURL, dependencyURL])
        let copies = prepared.sourceFiles.filter { $0.key.hasSuffix("LICENSE.txt") }
        XCTAssertEqual(Set(copies.values).count, 2, "both notices must survive: \(copies.keys.sorted())")
    }

    // MARK: - Fixtures for the boundaries above

    /// One archive with two input methods; only the advertised one may be installed.
    private static let twoSchemaArchive: [String: Data] = [
        "default.yaml": Data("schema_list:\n  - schema: alpha\n  - schema: beta\n".utf8),
        "alpha.schema.yaml": Data("schema:\n  schema_id: alpha\n  name: 甲\n".utf8),
        "beta.schema.yaml": Data("schema:\n  schema_id: beta\n  name: 乙\n".utf8),
    ]

    /// Minimal Rime user dictionary export: a header, the dictionary name and one entry.
    private static let snapshotText =
        "# Rime user dictionary\n#@/db_name\tterra_pinyin.userdb\n# no comment\n你\tni\t100\n"

    /// Structurally valid `Rime::Predict/1.0` header, as `Prediction.validateDatabases` reads it.
    private static func predictionDatabase() -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        for (index, byte) in Array("Rime::Predict/1.0".utf8).enumerated() { bytes[index] = byte }
        func set(_ offset: Int, _ value: UInt32) {
            for index in 0..<4 { bytes[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF) }
        }
        set(36, 16)  // double-array units start right after the metadata
        set(40, 4)  // four units
        set(44, 32)  // string table starts after the units
        set(48, 8)  // eight bytes of strings
        return Data(bytes)
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("multi-archive-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        return url
    }

    /// A small repository ZIP shaped like GitHub's codeload output: one wrapper directory per archive.
    private func archive(_ files: [String: Data], named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let wrapper = String(name.dropLast(4))
        let archive = try Archive(url: url, accessMode: .create)
        for (path, bytes) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: wrapper + "/" + path, type: .file, uncompressedSize: Int64(bytes.count),
                provider: { position, count in bytes.subdata(in: Int(position)..<(Int(position) + count)) })
        }
        return url
    }

    /// Stands in for the bridge's deploy callback so the store's commit path runs; it only proves what is
    /// installed, not that librime deploys the scheme (the catalogue harness covers the real engine).
    private static let deploy: RecipePackageManager.Deploy = { deployment in
        let schemaID = deployment.manifest.schemaID
        let build = deployment.userDataURL.appendingPathComponent(InstalledPackageLayout.buildDirectory)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("schema_list:\n  - schema: \(schemaID)\n".utf8)
            .write(to: build.appendingPathComponent("default.yaml"))
        try Data("schema: {schema_id: \(schemaID)}\n".utf8)
            .write(to: build.appendingPathComponent(InstalledPackageLayout.schemaFile(schemaID)))
        return .init(availableComponents: [], validatedSchemaID: schemaID, validatedEnabledSchemaIDs: [schemaID])
    }

    /// Generation directories of the store slot; a refused import must not add one.
    private func generationNames(in store: URL) throws -> [String] {
        let versions = store.appendingPathComponent(InstalledPackageLayout.versionsDirectory)
        return try FileManager.default.contentsOfDirectory(atPath: versions.path).sorted()
    }

    /// Installed resource files by package-relative path, for licence and notice checks.
    private func installedResourceTexts(at resources: URL) throws -> [String: String] {
        var texts: [String: String] = [:]
        let walker = try XCTUnwrap(
            FileManager.default.enumerator(at: resources, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = String(url.path.dropFirst(resources.path.count + 1))
            texts[path] = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        return texts
    }
}
