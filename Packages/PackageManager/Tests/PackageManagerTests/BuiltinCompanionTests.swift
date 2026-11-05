import KeyboardCore
import XCTest
import Yams

@testable import PackageManager

/// The bundled 14-, 18- and 9-key schemes of the built-in package are generator output, made by
/// the same `CompanionPlan` the app runs for installed schemes. Shipping them lets the keyboard
/// offer every layout before the app prepares anything, including without Full Access.
///
/// Regenerate after changing a built-in scheme, its dictionary or the generator:
/// `Tools/BuildRimeIOS/scripts/gen-builtin-companions.sh`.
final class BuiltinCompanionTests: XCTestCase {
    private static let writeEnvironment = "SONGYAN_WRITE_BUILTIN_COMPANIONS"

    private var repository: URL {
        (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
    }

    private var package: URL {
        repository.appendingPathComponent("Resources/BuiltinPackages/Basic")
    }

    /// The real frontend OpenCC distribution the host passes to its managers; the bundled package
    /// relies on it at deployment instead of shipping a second copy.
    private var sharedOpenCC: URL {
        repository.appendingPathComponent("Resources/EngineResources/opencc")
    }

    private func projection(_ source: String) throws -> CompactSchemaAdapter.SourceProjection {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "\(source).projection", withExtension: "json",
                subdirectory: "Fixtures"))
        return try XCTUnwrap(CompactSchemaAdapter.SourceProjection.decode(json: Data(contentsOf: url)))
    }

    private func yaml(_ name: String) throws -> [String: Any] {
        let text = try String(contentsOf: package.appendingPathComponent(name), encoding: .utf8)
        return try XCTUnwrap(Yams.load(yaml: text) as? [String: Any])
    }

    private func companion(_ adapter: KeyboardResourceSet.EncodingAdapter) throws -> Data {
        let source = adapter.sourceSchemaID
        let schema = try yaml("\(source).schema.yaml")
        let delimiter =
            (schema["translator"] as? [String: Any])?["delimiter"] as? String
            ?? (schema["speller"] as? [String: Any])?["delimiter"] as? String
        let plan = try CompactSchemaAdapter.CompanionPlan(
            compiled: try Data(contentsOf: package.appendingPathComponent("\(source).schema.yaml")),
            sourceID: source, projection: try projection(source), sourceDelimiter: delimiter)
        let fold = try XCTUnwrap(adapter.layout.compactFold)
        let body = try XCTUnwrap(try plan.companion(fold: fold), "\(source) cannot fold to \(fold.id) keys")
        let header = """
            # Generated from \(source).schema.yaml for the \(fold.id)-key layout; do not edit.
            # Regenerate with Tools/BuildRimeIOS/scripts/gen-builtin-companions.sh.
            # Rule sources and licenses: see \(source).schema.yaml.

            """
        return Data(header.utf8) + body
    }

    func testBundledCompanionsMatchTheGenerator() throws {
        let write = ProcessInfo.processInfo.environment[Self.writeEnvironment] == "1"
        for adapter in BuiltinTemplateSchemas.adapters {
            let fold = try XCTUnwrap(adapter.layout.compactFold)
            XCTAssertEqual(
                adapter.schemaID,
                CompactSchemaAdapter.identifier(sourceID: adapter.sourceSchemaID, fold: fold))
            let expected = try companion(adapter)
            let url = package.appendingPathComponent(adapter.schemaID + ".schema.yaml")
            if write { try expected.write(to: url, options: .atomic) }
            XCTAssertEqual(
                try? Data(contentsOf: url), expected,
                "\(adapter.schemaID) is stale; run Tools/BuildRimeIOS/scripts/gen-builtin-companions.sh")
        }
    }

    func testCompanionsCarryDisplayAndRewrite() throws {
        for adapter in BuiltinTemplateSchemas.adapters {
            let root = try yaml(adapter.schemaID + ".schema.yaml")
            XCTAssertEqual((root["schema"] as? [String: Any])?["schema_id"] as? String, adapter.schemaID)
            XCTAssertEqual((root["translator"] as? [String: Any])?["dictionary"] as? String, "songyan_basic")
            XCTAssertEqual((root["translator"] as? [String: Any])?["user_dict"] as? String, "songyan_shared")
            let rewrite = try XCTUnwrap(root["keyboard_rewrite"] as? [String: Any], adapter.schemaID)
            XCTAssertEqual(rewrite["lock"] as? String, CompactSchemaAdapter.tokenAliasLockValue)
            let display = (root["keyboard_adapter"] as? [String: Any])?["display_mode"] as? String
            XCTAssertEqual(display, adapter.layout == .phone9 ? "canonical" : "source_code", adapter.schemaID)
        }
    }

    /// The four script states are the built-in package's own data: the sources declare them and
    /// every generated companion must carry the same group and simplifiers, or a compact layout
    /// would silently lose 繁體/臺灣/香港 output.
    func testTheFourScriptStatesAreCarriedIntoEveryCompanion() throws {
        let expectedStates = ["简体", "繁體", "臺灣", "香港"]
        let conversions = ["zht": "s2t.json", "zh_tw": "s2twp.json", "zh_hk": "s2hk.json"]
        let names = BuiltinTemplateSchemas.sourceSchemaIDs + BuiltinTemplateSchemas.adapters.map(\.schemaID)
        for name in names {
            let root = try yaml(name + ".schema.yaml")
            let switches = try XCTUnwrap(root["switches"] as? [[String: Any]], name)
            let group = try XCTUnwrap(
                switches.first { $0["options"] != nil }, "\(name): no script radio group")
            XCTAssertEqual(
                group["options"] as? [String],
                ["simplification", "zht", "zh_tw", "zh_hk"], name)
            XCTAssertEqual(group["states"] as? [String], expectedStates, name)
            XCTAssertEqual(group["reset"] as? Int, 0, name)
            let engine = try XCTUnwrap(root["engine"] as? [String: Any], name)
            let filters = try XCTUnwrap(engine["filters"] as? [String], name)
            XCTAssertEqual(
                filters.last, "uniquifier", "\(name): conversions must run before uniquifier")
            for (namespace, config) in conversions {
                XCTAssertTrue(filters.contains("simplifier@\(namespace)"), name)
                let section = try XCTUnwrap(
                    root[namespace] as? [String: Any], "\(name): missing \(namespace)")
                XCTAssertEqual(section["option_name"] as? String, namespace, name)
                XCTAssertEqual(section["opencc_config"] as? String, config, name)
            }
            XCTAssertFalse(
                filters.contains("simplifier"),
                "\(name): a bare simplifier would convert the simplified default with s2t")
        }
    }

    /// A tap sends a key's own letter for its whole group, so the exact pick of that
    /// letter must be a different engine code that spells that letter only.
    func testExactPickOfAKeysOwnLetterIsDistinctFromItsTap() throws {
        for adapter in BuiltinTemplateSchemas.adapters where adapter.layout.keyFold == .letterGroups {
            let fold = try XCTUnwrap(adapter.layout.compactFold)
            let root = try yaml(adapter.schemaID + ".schema.yaml")
            let speller = try XCTUnwrap(root["speller"] as? [String: Any])
            let algebra = try XCTUnwrap(speller["algebra"] as? [String])
            let alphabet = try XCTUnwrap(speller["alphabet"] as? String)
            let preedit = (root["translator"] as? [String: Any])?["preedit_format"] as? [String]
            XCTAssertEqual(fold.exactTokens.count, adapter.layout == .merged14 ? 12 : 8)
            for (letter, token) in fold.exactTokens {
                let exact = try XCTUnwrap(algebra.firstIndex(of: "derive/\(letter)/\(token)/"), adapter.schemaID)
                let partners = fold.map.filter { $0.value == letter && $0.key != letter }.keys
                for partner in partners {
                    let tap = try XCTUnwrap(algebra.firstIndex(of: "derive/\(partner)/\(letter)/"))
                    XCTAssertLessThan(exact, tap, "\(adapter.schemaID): \(token) must see \(letter) only")
                }
                XCTAssertTrue(alphabet.contains(token), adapter.schemaID)
            }
            let xlit = try XCTUnwrap(preedit?.first, adapter.schemaID)
            let parts = xlit.split(separator: "/", omittingEmptySubsequences: false)
            XCTAssertEqual(parts.first, "xlit")
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: zip(parts[1], parts[2])),
                Dictionary(uniqueKeysWithValues: fold.exactTokens.map { ($1, $0) }))
        }
    }

    func testDefaultSchemaListDeploysSourcesAndCompanions() throws {
        let list = try XCTUnwrap(try yaml("default.yaml")["schema_list"] as? [[String: Any]])
        XCTAssertEqual(
            list.compactMap { $0["schema"] as? String },
            BuiltinTemplateSchemas.sourceSchemaIDs + BuiltinTemplateSchemas.adapters.map(\.schemaID))
        for id in BuiltinTemplateSchemas.sourceSchemaIDs {
            XCTAssertEqual(
                (try yaml("\(id).schema.yaml")["schema"] as? [String: Any])?["name"] as? String,
                BuiltinTemplateSchemas.names[id])
        }
    }

    /// The projections stand in for the live engine: they must still describe these schemes.
    func testProjectionsMatchTheBundledSchemesAndDictionary() throws {
        let dictionary = try String(
            contentsOf: package.appendingPathComponent("songyan_basic.dict.yaml"),
            encoding: .utf8)
        let rows = dictionary.components(separatedBy: "\n...\n")[1].split(separator: "\n")
            .filter { !$0.hasPrefix("#") }.map { $0.split(separator: "\t") }.filter { $0.count == 3 }
        let syllables = Set(rows.flatMap { $0[1].split(separator: " ").map(String.init) })
        XCTAssertFalse(syllables.isEmpty)
        for source in BuiltinTemplateSchemas.sourceSchemaIDs {
            let projection = try projection(source)
            let schema = try yaml("\(source).schema.yaml")
            XCTAssertEqual(projection.sourceSchema, source)
            XCTAssertEqual(projection.dictionary, "songyan_basic")
            XCTAssertEqual(projection.algebra, (schema["speller"] as? [String: Any])?["algebra"] as? [String] ?? [])
            XCTAssertEqual(Set(projection.syllables.map(\.token)), syllables, source)
        }
    }

    /// Installed like any imported scheme: the manifest's identity and the two entry schemes,
    /// without the companions that only the keyboard's offline fallback uses.
    func testBundledPackageInstallsOnlyItsEntrySchemes() throws {
        let manager = RecipePackageManager(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString),
            sharedOpenCCDirectory: sharedOpenCC)
        let prepared = try manager.prepareBundledPackage(directory: package)
        XCTAssertEqual(prepared.declaration.id, ProductionInputAvailability.builtinPackageID)
        // Adding keyboards plans recipes keyed by the package ID, whose update rules reject dots.
        XCTAssertFalse(prepared.declaration.id.contains("."))
        XCTAssertEqual(prepared.declaration.name, ProductionInputAvailability.builtinDisplayName)
        XCTAssertEqual(prepared.schemaIDs, BuiltinTemplateSchemas.sourceSchemaIDs.sorted())
        let defaults = try XCTUnwrap(prepared.preparedBytes(for: "default.yaml"))
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: defaults, as: UTF8.self)) as? [String: Any])
        let list = try XCTUnwrap(root["schema_list"] as? [[String: String]])
        XCTAssertEqual(list.compactMap { $0["schema"] }, BuiltinTemplateSchemas.sourceSchemaIDs)
        XCTAssertNil(prepared.preparedBytes(for: BuiltinTemplateSchemas.adapters[0].schemaID + ".schema.yaml"))
        XCTAssertNil(prepared.preparedBytes(for: "manifest.yaml"))
        // Same bytes, same revision: an unchanged bundle is never reinstalled.
        XCTAssertEqual(
            try manager.prepareBundledPackage(directory: package).manifest.revision, prepared.manifest.revision)
    }

    /// The installed bundle consumes the frontend OpenCC distribution: the dependency check needs the
    /// real one, never a hardcoded "these exist" waiver. Without it the same bundle fails closed.
    func testBundledPackageNeedsTheFrontendOpenCCDistribution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let withoutOpenCC = RecipePackageManager(rootURL: root)
        XCTAssertThrowsError(try withoutOpenCC.prepareBundledPackage(directory: package)) { error in
            let detail = String(describing: error)
            XCTAssertTrue(detail.contains("缺少输入方案依赖项"), detail)
            XCTAssertTrue(detail.contains("opencc/s2t.json"), detail)
        }
        let withOpenCC = RecipePackageManager(rootURL: root, sharedOpenCCDirectory: sharedOpenCC)
        XCTAssertNoThrow(try withOpenCC.prepareBundledPackage(directory: package))
    }

    /// A normal import gets no frontend distribution for free: naming an OpenCC config only passes once
    /// the package carries that data, and the config's own dictionaries are read recursively.
    func testImportedSchemeStillRefusesOpenCCOnlyTheFrontendHas() throws {
        let schema = Data("schema: {schema_id: sample}\nsimplifier: {opencc_config: s2t.json}\n".utf8)
        let bare = ["sample.schema.yaml": schema]
        XCTAssertThrowsError(try SchemeSourceCheck.dependencies(bare)) { error in
            XCTAssertTrue(String(describing: error).contains("opencc/s2t.json"), String(describing: error))
        }
        var configOnly = bare
        configOnly["opencc/s2t.json"] = try Data(contentsOf: sharedOpenCC.appendingPathComponent("s2t.json"))
        XCTAssertThrowsError(try SchemeSourceCheck.dependencies(configOnly)) { error in
            // The config's conversion chain names dictionaries; a passed config alone is not enough.
            XCTAssertTrue(String(describing: error).contains("opencc/STPhrases.ocd2"), String(describing: error))
        }
    }
}
