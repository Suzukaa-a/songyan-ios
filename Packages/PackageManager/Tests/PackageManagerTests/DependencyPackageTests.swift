import XCTest
import ZIPFoundation

@testable import PackageManager

/// A package with no input method but Rime data (rime-essay, a dictionary repository) is stored for
/// the packages that read its files; it is never deployed and offers nothing to type with.
final class DependencyPackageTests: XCTestCase {
    private func directory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        return url
    }

    private func zip(_ files: [String: String], named name: String) throws -> URL {
        let url = try directory("zip").appendingPathComponent(name)
        let wrapper = String(name.dropLast(4))
        let archive = try Archive(url: url, accessMode: .create)
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            let bytes = Data(text.utf8)
            try archive.addEntry(
                with: wrapper + "/" + path, type: .file, uncompressedSize: Int64(bytes.count),
                provider: { position, count in bytes.subdata(in: Int(position)..<(Int(position) + count)) })
        }
        return url
    }

    private func manager() throws -> RecipePackageManager {
        RecipePackageManager(rootURL: try directory("store"))
    }

    private func installedResources(_ manager: RecipePackageManager) async throws -> URL {
        let active = try await manager.activeInstallation()
        return try XCTUnwrap(active).resourceURL
    }

    private let essay = ["essay.txt": "我\t100\n", "README.md": "word list"]

    func testAZipOfDataFilesAloneIsADependencyPackageNamedAfterTheRepository() throws {
        let prepared = try manager().prepareSync([try zip(essay, named: "rime-essay-master.zip")])
        XCTAssertTrue(prepared.isDependencyPackage)
        XCTAssertEqual(prepared.schemaIDs, [])
        XCTAssertEqual(prepared.declaration.name, "rime-essay")
        XCTAssertNotNil(prepared.preparedBytes(for: "essay.txt"))
    }

    func testEveryKindOfDataFileCountsAndDocumentationAloneDoesNot() throws {
        for path in ["x.dict.yaml", "symbols.yaml", "opencc/a.json", "lua/a.lua", "m.gram"] {
            XCTAssertTrue(RecipePackageManager.isDependencyDataFile(path), path)
        }
        for path in ["default.yaml", "x.custom.yaml", "README.md", "sub/x.dict.yaml", "LICENSE"] {
            XCTAssertFalse(RecipePackageManager.isDependencyDataFile(path), path)
        }
        XCTAssertThrowsError(try manager().prepareSync([try zip(["README.md": "x"], named: "empty.zip")])) { error in
            guard case RecipeInstallError.noRimeContent = error else { return XCTFail("\(error)") }
            let notice = (error as? RecipeInstallError)?.userFacingDescription ?? ""
            XCTAssertTrue(notice.contains(".dict.yaml") && notice.contains("essay.txt"), notice)
            XCTAssertNotEqual(notice, PackageText.string("recipe.error.filesIncomplete"))
        }
    }

    func testTheSameDataFilesAreTheSamePackageWhateverTheirContent() throws {
        let manager = try manager()
        let old = try manager.prepareSync([try zip(essay, named: "rime-essay-1.zip")])
        let new = try manager.prepareSync([try zip(["essay.txt": "我\t200\n"], named: "rime-essay-2.zip")])
        XCTAssertEqual(old.declaration.id, new.declaration.id)
        XCTAssertNotEqual(old.manifest.revision, new.manifest.revision)
        let other = try manager.prepareSync([try zip(["x.dict.yaml": "---\nname: x\n...\n"], named: "x.zip")])
        XCTAssertNotEqual(old.declaration.id, other.declaration.id)
    }

    func testStoringItDeploysNothingAndLeavesNoInputMethod() async throws {
        let manager = try manager()
        let prepared = try manager.prepareSync([try zip(essay, named: "rime-essay-master.zip")])
        let installed = try await manager.installDependencyPackage(prepared)
        XCTAssertEqual(installed.schemaID, "")
        let active = try await manager.activeInstallation()
        let resources = try XCTUnwrap(active).resourceURL
        XCTAssertEqual(try String(contentsOf: resources.appendingPathComponent("essay.txt")), "我\t100\n")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: resources.deletingLastPathComponent().appendingPathComponent("user/build").path))
    }

    // MARK: - Using what a dependency package provides

    private func wubi() throws -> URL {
        try zip(
            [
                "main.schema.yaml": "schema:\n  schema_id: main\n  name: 主方案\n  dependencies: [pinyin_simp]\n"
                    + "translator:\n  dictionary: main\n  use_preset_vocabulary: true\n"
                    + "reverse_lookup:\n  dictionary: pinyin_simp\n",
                "main.dict.yaml": "---\nname: main\nversion: '1'\n...\n我\two\n",
            ], named: "rime-main.zip")
    }

    private let pinyinSimp = [
        "pinyin_simp.schema.yaml": "schema:\n  schema_id: pinyin_simp\n  name: 袖珍\n",
        "pinyin_simp.dict.yaml": "---\nname: pinyin_simp\nversion: '1'\n...\n我\two\n",
    ]

    private static let deploy: RecipePackageManager.Deploy = { deployment in
        let build = deployment.userDataURL.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("schema_list:\n  - schema: main\n".utf8).write(to: build.appendingPathComponent("default.yaml"))
        try Data("schema: {schema_id: main}\n".utf8).write(to: build.appendingPathComponent("main.schema.yaml"))
        return .init(availableComponents: [], validatedSchemaID: "main", validatedEnabledSchemaIDs: ["main"])
    }

    func testAnInstalledPackageTakesWhatALaterDependencyPackageProvides() async throws {
        let manager = try manager()
        let first = try manager.prepareSync([try wubi()])
        XCTAssertEqual(first.missingFeatures.map(\.kind), [.reverseLookup, .presetVocabulary])
        _ = try await manager.installSchemeImport(first, deploy: Self.deploy)
        let resources = try await installedResources(manager)

        let provided = ["essay.txt": Data("我\t100\n".utf8)].merging(
            pinyinSimp.mapValues { Data($0.utf8) }
        ) { a, _ in a }
        let completed = try XCTUnwrap(
            try PreparedSchemeImport.completing(installed: resources, provide: { provided[$0] }))
        XCTAssertNotNil(completed.preparedBytes(for: "essay.txt"))
        XCTAssertNotNil(completed.preparedBytes(for: "pinyin_simp.dict.yaml"))
        XCTAssertEqual(completed.manifest.id, first.manifest.id)
        XCTAssertNotEqual(completed.manifest.revision, first.manifest.revision)
        XCTAssertEqual(completed.declaration.name, first.declaration.name)
        XCTAssertEqual(completed.missingFeatures, [])

        _ = try await manager.installSchemeImport(completed, deploy: Self.deploy)
        let after = try await installedResources(manager)
        XCTAssertNil(
            try PreparedSchemeImport.completing(installed: after, provide: { provided[$0] }),
            "nothing is left to provide")
    }

    func testWhatThePackageAlreadyHasIsNeverReplaced() async throws {
        let manager = try manager()
        _ = try await manager.installSchemeImport(try manager.prepareSync([try wubi()]), deploy: Self.deploy)
        let resources = try await installedResources(manager)
        let others = ["main.dict.yaml": Data("---\nname: main\n...\n".utf8)]
        XCTAssertNil(try PreparedSchemeImport.completing(installed: resources, provide: { others[$0] }))
    }
}
