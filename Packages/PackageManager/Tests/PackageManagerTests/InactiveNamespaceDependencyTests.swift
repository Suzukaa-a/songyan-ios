import Foundation
import XCTest

@testable import PackageManager

/// The dependency closure may treat a dictionary as required only when a native component can name
/// its namespace. librime creates a Dictionary with ticket.name_space + "/dictionary" (rime dict
/// dictionary.cc), and components exist only for the entries of
/// engine/{processors,segmentors,translators,filters} (rime engine.cc, ticket.cc). A dictionary
/// under a root namespace no engine entry claims is never loaded natively, so the closure keeps it
/// optional: reported and still fetchable, but not blocking the import.
///
/// These cases pin only the closure the importer runs (SchemeSourceCheck.dependencies, also called
/// from prepareSchemeImport). They make no claim about Lua components that construct translators
/// dynamically at run time; a dictionary missing for such a component is a silently absent lookup,
/// exactly like a declared optional dependency. Every other dependency edge (translator dictionary,
/// __include / __patch, opencc, import_preset) keeps its old strictness.
final class InactiveNamespaceDependencyTests: XCTestCase {
    private let moranDictionary = "moran.chars.dict.yaml"
    private let mungyeongDictionary = "mungyeong.extended.dict.yaml"

    /// The translators of a schema shaped like the frozen kagiroi source: the reverse-lookup
    /// components are absent (they are comments in the upstream YAML, i.e. not data).
    private let defaultTranslators = [
        "punct_translator",
        "table_translator@custom_phrase",
        "lua_translator@*probe/translator",
    ]

    // MARK: - Fixtures

    private func engineLines(translators: [String]) -> [String] {
        var lines = [
            "engine:",
            "  processors:",
            "    - ascii_composer",
            "    - recognizer",
            "    - key_binder",
            "    - lua_processor@*probe/kana",
            "    - speller",
            "    - punctuator",
            "    - selector",
            "    - navigator",
            "    - express_editor",
            "  segmentors:",
            "    - ascii_segmentor",
            "    - matcher",
            "    - abc_segmentor",
            "    - punct_segmentor",
            "    - fallback_segmentor",
            "  translators:",
        ]
        lines += translators.map { "    - \($0)" }
        lines += ["  filters:", "    - uniquifier"]
        return lines
    }

    private func namespaceLines(moran: [String], mungyeong: [String]) -> [String] {
        func block(_ name: String, _ dictionary: String, _ extra: [String]) -> [String] {
            ["\(name):", "  dictionary: \(dictionary)", "  target: probe"]
                + extra.map { "  \($0)" }
                + ["  tag: \(name)"]
        }
        return block("moran", "moran.chars", moran) + block("mungyeong", "mungyeong.extended", mungyeong)
    }

    /// engineBlock nil writes the default four lists; an empty string omits the section; anything
    /// else is inserted verbatim (a null section, an opaque __include, ...).
    private func schema(
        translators: [String]? = nil,
        engineBlock: String? = nil,
        translatorDictionary: String = "probe",
        additionalRoot: String = "",
        moran: [String] = [],
        mungyeong: [String] = []
    ) -> String {
        var lines = ["schema:", "  schema_id: probe", "  name: Probe", ""]
        if let engineBlock = engineBlock {
            if !engineBlock.isEmpty {
                lines += engineBlock.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            }
        } else {
            lines += engineLines(translators: translators ?? defaultTranslators)
        }
        lines += ["", "translator:", "  dictionary: \(translatorDictionary)", ""]
        lines += [
            "recognizer:",
            "  import_preset: default",
            "  patterns:",
            "    moran: '^C'",
            "    mungyeong: '^K'",
            "",
        ]
        if !additionalRoot.isEmpty {
            lines += additionalRoot.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        lines += namespaceLines(moran: moran, mungyeong: mungyeong)
        return lines.joined(separator: "\n")
    }

    private func files(_ schema: String, extra: [String: String] = [:]) -> [String: Data] {
        var result: [String: Data] = [
            "default.yaml": Data("schema_list:\n  - schema: probe\n".utf8),
            "probe.schema.yaml": Data(schema.utf8),
            "probe.dict.yaml": Data("---\nname: probe\nversion: '1'\n...\n".utf8),
            "lua/probe/kana.lua": Data("return {}\n".utf8),
            "lua/probe/translator.lua": Data("return {}\n".utf8),
        ]
        for (path, text) in extra {
            result[path] = Data(text.utf8)
        }
        return result
    }

    // MARK: - Inactive namespace: dictionary becomes optional

    func testAnInactiveNativeNamespaceDictionaryIsOptional() throws {
        let source = files(schema())
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, [])
        XCTAssertEqual(closure.optional, [moranDictionary, mungyeongDictionary])
        XCTAssertNoThrow(try SchemeSourceCheck.dependencies(source))
    }

    // MARK: - A native component alias claims its namespace again

    func testAComponentAliasMakesItsNamespaceDictionaryRequired() throws {
        let source = files(schema(translators: defaultTranslators + ["reverse_lookup_translator@moran"]))
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, [moranDictionary])
        XCTAssertEqual(closure.optional, [mungyeongDictionary])
        XCTAssertThrowsError(try SchemeSourceCheck.dependencies(source))
    }

    // MARK: - Unknown capability stays exactly as strict as before

    /// A component class this checker cannot interpret may read config sections other than the alias
    /// it names (reverse_lookup_translator also reads reverse_lookup/), so nothing is relaxed for
    /// schemas mounting one.
    func testAnUnknownComponentAliasKeepsEveryDictionaryRequired() throws {
        let source = files(schema(translators: defaultTranslators + ["mystery_translator@moran"]))
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, [moranDictionary, mungyeongDictionary])
    }

    /// Without an alias the component's config namespace is not knowable at all: fail closed.
    func testAnUnknownComponentWithoutAliasKeepsEveryDictionaryRequired() throws {
        let source = files(schema(translators: defaultTranslators + ["mystery_translator"]))
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, [moranDictionary, mungyeongDictionary])
    }

    // MARK: - Native default namespaces keep their dictionaries

    /// A bare reverse_lookup_translator reads reverse_lookup/ (librime remaps the component kind),
    /// so that root section stays a hard dependency.
    func testTheDefaultReverseLookupSectionStaysRequiredForABareReverseLookupTranslator() throws {
        let source = files(
            schema(
                translators: defaultTranslators + ["reverse_lookup_translator"],
                additionalRoot: "reverse_lookup:\n  dictionary: luna_lookup\n"))
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, ["luna_lookup.dict.yaml"])
        XCTAssertEqual(closure.optional, [moranDictionary, mungyeongDictionary])
    }

    // MARK: - Only dictionary edges change; references stay hard

    func testAnIncludeInsideAnInactiveBlockStaysRequired() throws {
        let source = files(schema(moran: ["__include: extra:/node"]))
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, ["extra.yaml"])
        XCTAssertEqual(closure.optional, [moranDictionary, mungyeongDictionary])
    }

    func testOnlyDictionaryEdgesInsideAnInactiveBlockBecomeOptional() throws {
        let source = files(schema(moran: ["opencc_config: moran.json", "import_preset: moran_preset"]))
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, ["moran_preset.yaml", "opencc/moran.json"])
        XCTAssertEqual(closure.optional, [moranDictionary, mungyeongDictionary])
    }

    /// translator/dictionary is what SchemaUpdate compiles, so it is required whatever the engine
    /// block says.
    func testTheMainTranslatorDictionaryIsAlwaysRequired() throws {
        var source = files(schema())
        source["probe.dict.yaml"] = nil
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, ["probe.dict.yaml"])
        XCTAssertEqual(closure.optional, [moranDictionary, mungyeongDictionary])
    }

    // MARK: - Unreadable engine: keep the old strictness

    func testAnAbsentEngineKeepsEveryDictionaryRequired() throws {
        let source = files(schema(engineBlock: ""))
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, [moranDictionary, mungyeongDictionary])
    }

    func testANullEngineKeepsEveryDictionaryRequired() throws {
        let source = files(schema(engineBlock: "engine:"))
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, [moranDictionary, mungyeongDictionary])
    }

    func testAnOpaqueEngineIncludeKeepsEveryDictionaryRequired() throws {
        let source = files(
            schema(engineBlock: "engine:\n  __include: shared_engine:/engine"),
            extra: ["shared_engine.yaml": "engine:\n  translators:\n    - punct_translator\n"])
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, [moranDictionary, mungyeongDictionary])
    }

    // MARK: - A custom patch that can enable the namespace: keep the old strictness

    func testACustomPatchThatCanEnableTheNamespaceKeepsItRequired() throws {
        let source = files(
            schema(),
            extra: [
                "probe.custom.yaml":
                    "patch:\n  engine/translators/+:\n    - reverse_lookup_translator@moran\n"
            ])
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, [moranDictionary, mungyeongDictionary])
    }

    /// A patch expression this checker cannot model could also mount the component: fail closed.
    func testAnOpaqueCustomPatchKeepsEveryDictionaryRequired() throws {
        let source = files(
            schema(),
            extra: [
                "probe.custom.yaml": "__patch: [\"shared_patch:/engine\"]\n",
                "shared_patch.yaml": "engine:\n  translators:\n    - punct_translator\n",
            ])
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, [moranDictionary, mungyeongDictionary])
    }

    /// A custom file whose literal patch leaves the engine alone cannot enable the component, so the
    /// inactive namespace stays optional: otherwise every package with any custom file would fall
    /// back to the old over-strict closure.
    func testAnUnrelatedCustomPatchDoesNotDisableRelaxation() throws {
        let source = files(
            schema(),
            extra: ["probe.custom.yaml": "patch:\n  menu/page_size: 7\n"])
        let closure = try SchemeSourceCheck.dependencyClosure(source)
        XCTAssertEqual(closure.required, [])
        XCTAssertEqual(closure.optional, [moranDictionary, mungyeongDictionary])
    }
}
