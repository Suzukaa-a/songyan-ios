import XCTest
import ZIPFoundation

@testable import PackageManager

/// Packages shaped like the rime/rime-* repositories, which lean on each other: a missing reverse
/// lookup costs only the lookup, another installed package may provide it, and a desktop Rime folder
/// offers only the input methods nothing else depends on.
final class DesktopFolderImportTests: XCTestCase {
    private let manager = RecipePackageManager(rootURL: FileManager.default.temporaryDirectory)

    func testAMissingReverseLookupDependencyOnlyCostsTheLookup() throws {
        let prepared = try prepare(wubiFiles(), named: "rime-wubi-master.zip")

        XCTAssertEqual(prepared.schemaIDs, ["wubi86", "wubi_pinyin"])
        XCTAssertEqual(prepared.declaration.name, "rime-wubi")
        XCTAssertEqual(prepared.missingFeatures, [MissingFeature(kind: .reverseLookup, names: ["pinyin_simp"])])
        XCTAssertEqual(MissingFeature.repository(of: "pinyin_simp"), "rime/rime-pinyin-simp")
        XCTAssertTrue(
            prepared.missingFeatures[0].userFacingDescription.contains("pinyin_simp（rime/rime-pinyin-simp）"),
            prepared.missingFeatures[0].userFacingDescription)
    }

    func testADependencyAnotherInstalledPackageProvidesIsCopiedIn() throws {
        let lender = Dictionary(uniqueKeysWithValues: pinyinSimpFiles().map { ($0.key, $0.value) })
        let prepared = try prepare(wubiFiles(), named: "rime-wubi-master.zip") { lender[$0] }

        XCTAssertNotNil(prepared.preparedBytes(for: "pinyin_simp.dict.yaml"))
        XCTAssertNotNil(prepared.preparedBytes(for: "pinyin_simp.schema.yaml"))
        XCTAssertNil(prepared.sourceFiles["pinyin_simp.dict.yaml"], "the source record keeps only what was picked")
        XCTAssertEqual(prepared.schemaIDs, ["wubi86", "wubi_pinyin"], "the borrowed schema is a lookup")
        // pinyin_simp declares a stroke lookup of its own; the notice names it too.
        XCTAssertEqual(prepared.missingFeatures, [MissingFeature(kind: .reverseLookup, names: ["stroke"])])
    }

    func testABorrowedFileNeverReplacesOneThePackageShips() throws {
        var files = wubiFiles()
        let own = Data("---\nname: pinyin_simp\nversion: 'own'\n...\n".utf8)
        files["pinyin_simp.dict.yaml"] = own
        let prepared = try prepare(files, named: "rime-wubi-master.zip") { _ in Data("---\nname: x\n...\n".utf8) }
        XCTAssertEqual(prepared.preparedBytes(for: "pinyin_simp.dict.yaml"), own)
    }

    func testADesktopFolderOffersOnlyTheSchemasNoOtherDependsOnAndIsNamedAfterThePackage() throws {
        let files = wubiFiles().merging(pinyinSimpFiles()) { a, _ in a }
            .merging(strokeAndLunaFiles()) { a, _ in a }
        let prepared = try prepare(files, named: "rime-wubi-bundle.zip", wrapper: "rime-wubi-bundle")

        XCTAssertEqual(prepared.manifest.schemaID, "wubi86")
        XCTAssertEqual(prepared.schemaIDs, ["wubi86", "wubi_pinyin", "luna_pinyin_simp"])
        XCTAssertEqual(prepared.offeredSchemaIDs, ["wubi86", "wubi_pinyin", "luna_pinyin_simp"])
        XCTAssertEqual(prepared.declaration.name, "rime-wubi-bundle")
        XCTAssertEqual(prepared.missingFeatures, [])
    }

    func testAPackageWithItsOwnConfigurationKeepsItsListAndName() throws {
        var files = wubiFiles().merging(pinyinSimpFiles()) { a, _ in a }
        files["default.yaml"] = Data("schema_list:\n  - schema: wubi_pinyin\n  - schema: pinyin_simp\n".utf8)
        let prepared = try prepare(files, named: "rime-wubi-master.zip")

        XCTAssertEqual(prepared.offeredSchemaIDs, ["wubi_pinyin", "pinyin_simp"])
        XCTAssertEqual(prepared.declaration.name, "五筆·拼音")
    }

    func testAPackageNameDropsTheBranchAndExtension() {
        XCTAssertEqual(RecipePackageManager.cleanPackageName("rime-wubi-master.zip"), "rime-wubi")
        XCTAssertEqual(RecipePackageManager.cleanPackageName("rime-wubi-4f6b6e0c2a1d"), "rime-wubi")
        XCTAssertEqual(RecipePackageManager.cleanPackageName("我的方案.ZIP"), "我的方案")
        XCTAssertNil(RecipePackageManager.cleanPackageName(" .zip"))
        XCTAssertNil(
            RecipePackageManager.cleanPackageName("scheme-0F3C2B1A-0000-4000-8000-123456789ABC.zip"),
            "a download's temporary file name names nothing")
    }

    func testAMissingFileNamesTheRepositoryThatProvidesIt() {
        let error = RecipeInstallError.missingSchemaFiles(["terra_pinyin.dict.yaml", "essay.txt", "unknown.dict.yaml"])
        let notice = error.userFacingDescription
        XCTAssertTrue(
            notice.contains(
                "terra_pinyin.dict.yaml（rime/rime-terra-pinyin）、essay.txt（rime/rime-essay）、unknown.dict.yaml。"),
            notice)
    }

    func testAMissingRequiredDependencyNamesItsFilesToTheUser() throws {
        var files = wubiFiles()
        files["wubi86.dict.yaml"] = nil
        XCTAssertThrowsError(try prepare(files, named: "rime-wubi-master.zip")) { error in
            guard case RecipeInstallError.missingSchemaFiles(let paths) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(paths, ["wubi86.dict.yaml"])
            let notice = (error as? RecipeInstallError)?.userFacingDescription ?? ""
            XCTAssertTrue(notice.contains("wubi86.dict.yaml"), notice)
            XCTAssertNotEqual(notice, PackageText.string("recipe.error.filesIncomplete"))
        }
    }

    // MARK: - Fixtures

    private func prepare(
        _ files: [String: Data], named name: String, wrapper: String? = nil,
        provide: (String) -> Data? = { _ in nil }
    ) throws -> PreparedSchemeImport {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-folder-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        let url = directory.appendingPathComponent(name)
        let wrapperName = wrapper ?? String(name.dropLast(4))
        let archive = try Archive(url: url, accessMode: .create)
        for (path, bytes) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: wrapperName + "/" + path, type: .file, uncompressedSize: Int64(bytes.count),
                provider: { position, count in bytes.subdata(in: Int(position)..<(Int(position) + count)) })
        }
        return try manager.prepareSync([url], provide: provide)
    }

    private func schema(_ id: String, _ name: String, dependencies: [String] = [], body: String) -> Data {
        let list = dependencies.isEmpty ? "" : "  dependencies: [" + dependencies.joined(separator: ", ") + "]\n"
        return Data("schema:\n  schema_id: \(id)\n  name: \(name)\n\(list)\(body)".utf8)
    }

    private func dictionary(_ name: String, _ row: String) -> Data {
        Data("---\nname: \(name)\nversion: '1'\n...\n\(row)\n".utf8)
    }

    /// rime-wubi as upstream ships it: a reverse lookup by pinyin_simp, which it does not include.
    private func wubiFiles() -> [String: Data] {
        let engine =
            "engine:\n  translators:\n    - punct_translator\n    - reverse_lookup_translator\n    - table_translator\n"
        let lookup = "reverse_lookup:\n  dictionary: pinyin_simp\n  prefix: \"z\"\n"
        return [
            "wubi86.schema.yaml": schema(
                "wubi86", "五笔86", dependencies: ["pinyin_simp"],
                body: engine + "translator:\n  dictionary: wubi86\n" + lookup),
            "wubi_pinyin.schema.yaml": schema(
                "wubi_pinyin", "五筆·拼音", dependencies: ["pinyin_simp"],
                body: engine + "translator:\n  dictionary: wubi86\n  prism: wubi_pinyin\n" + lookup),
            "wubi86.dict.yaml": dictionary("wubi86", "我\ttrnt"),
        ]
    }

    /// rime-pinyin-simp: a pinyin scheme whose own reverse lookup is stroke.
    private func pinyinSimpFiles() -> [String: Data] {
        [
            "pinyin_simp.schema.yaml": schema(
                "pinyin_simp", "袖珍简化字拼音", dependencies: ["stroke"],
                body: "engine:\n  translators:\n    - script_translator\n    - reverse_lookup_translator\n"
                    + "translator:\n  dictionary: pinyin_simp\nreverse_lookup:\n  dictionary: stroke\n"),
            "pinyin_simp.dict.yaml": dictionary("pinyin_simp", "我\two"),
        ]
    }

    /// rime-stroke and rime-luna-pinyin, which name each other as their lookup, plus a luna variant.
    private func strokeAndLunaFiles() -> [String: Data] {
        [
            "stroke.schema.yaml": schema(
                "stroke", "五筆畫", dependencies: ["luna_pinyin"],
                body: "engine:\n  translators:\n    - reverse_lookup_translator\n    - table_translator\n"
                    + "translator:\n  dictionary: stroke\nreverse_lookup:\n  dictionary: luna_pinyin\n"),
            "stroke.dict.yaml": dictionary("stroke", "我\tpshpn"),
            "luna_pinyin.schema.yaml": schema(
                "luna_pinyin", "朙月拼音", dependencies: ["stroke"],
                body: "engine:\n  translators:\n    - script_translator\n    - reverse_lookup_translator\n"
                    + "translator:\n  dictionary: luna_pinyin\nreverse_lookup:\n  dictionary: stroke\n"),
            "luna_pinyin.dict.yaml": dictionary("luna_pinyin", "我\two"),
            "luna_pinyin_simp.schema.yaml": schema(
                "luna_pinyin_simp", "朙月拼音·简化字",
                body: "engine:\n  translators:\n    - script_translator\n"
                    + "translator:\n  dictionary: luna_pinyin\n  prism: luna_pinyin_simp\n"),
        ]
    }
}
