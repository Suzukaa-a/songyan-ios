import XCTest

@testable import KeyboardCore

/// The cached input language must read a scheme's real alphabet even when the resource
/// descriptor only carries an empty string (unknown) and the backend already caches it.
@MainActor
final class InputSessionInputLanguageTests: XCTestCase {
    /// 大千 注音 alphabet: the first row is contiguous, tones and punctuation follow.
    private let bopomofoAlphabet = "1qaz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/- 6347"

    private final class AlphabetEngine: EngineBackend {
        let kind: EngineBackendKind = .demoSimulator("input-language-cache")
        var statusSummary: String { "input-language-cache" }
        var schemas: [KeyboardSchemaDescriptor]
        private(set) var options: [EngineOptionState]
        private var snapshot: EngineSnapshot

        init(schemas: [KeyboardSchemaDescriptor], options: [EngineOptionState], current: String) {
            self.schemas = schemas
            self.options = options
            var state = EngineSnapshot()
            state.schemaID = current
            self.snapshot = state
        }

        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func validateSchema(_ schemaID: String) throws {}
        func selectSchema(_ schemaID: String) throws {
            snapshot.schemaID = schemaID
        }
        var availableSchemas: [KeyboardSchemaDescriptor] { schemas }
        func optionStates() throws -> [EngineOptionState] { options }
        func setOption(_ name: String, value: Bool) throws -> EngineSnapshot {
            options = options.map { option in
                option.descriptor.name == name
                    ? EngineOptionState(descriptor: option.descriptor, value: value) : option
            }
            return snapshot
        }
        func processKey(_ keyValue: String) throws -> EngineSnapshot { snapshot }
        func selectCandidate(_ index: Int) throws -> EngineSnapshot { snapshot }
        func nextPage() throws -> EngineSnapshot { snapshot }
        func previousPage() throws -> EngineSnapshot { snapshot }
        func currentSnapshot() -> EngineSnapshot { snapshot }
        func shutdown() {}
    }

    private func resource(
        schemaID: String, descriptorAlphabet: String
    ) -> KeyboardResourceSet {
        let root = URL(fileURLWithPath: "/unused")
        return KeyboardResourceSet(
            id: "pkg", name: "test", sharedDirectory: root, userDirectory: root,
            layoutEntries: [.init(layout: .qwerty26, schemaID: schemaID)],
            schemas: [KeyboardSchemaDescriptor(id: schemaID, name: "", alphabet: descriptorAlphabet)],
            selectedSchemaID: schemaID)
    }

    /// The backend lists no schemas until the engine is up; the empty answer must not be cached.
    func testAnAlphabetReadBeforeTheEngineIsUpIsNotCached() {
        let schemaID = "custom_zhuyin"
        let engine = AlphabetEngine(schemas: [], options: [], current: schemaID)
        let session = InputSession(
            engine: engine, layout: .qwerty26,
            resourceSet: resource(schemaID: schemaID, descriptorAlphabet: ""))
        engine.schemas = [KeyboardSchemaDescriptor(id: schemaID, name: "", alphabet: bopomofoAlphabet)]
        session.reloadOptions()
        XCTAssertEqual(
            session.inputLanguage,
            InputLanguageProfile(language: .traditionalChinese, family: .zhuyin))
    }

    func testEmptyResourceAlphabetFallsBackToTheBackendCacheForTheFamily() {
        let schemaID = "custom_zhuyin"
        let engine = AlphabetEngine(
            schemas: [KeyboardSchemaDescriptor(id: schemaID, name: "", alphabet: bopomofoAlphabet)],
            options: [], current: schemaID)
        let session = InputSession(
            engine: engine, layout: .qwerty26,
            resourceSet: resource(schemaID: schemaID, descriptorAlphabet: ""))
        XCTAssertEqual(
            session.inputLanguage,
            InputLanguageProfile(language: .traditionalChinese, family: .zhuyin),
            "an empty descriptor alphabet is unknown, not an empty speller alphabet")

        // Repeated configuration prepares must keep the resolved profile.
        session.reloadOptions()
        session.reloadOptions()
        XCTAssertEqual(
            session.inputLanguage,
            InputLanguageProfile(language: .traditionalChinese, family: .zhuyin))
    }

    func testDeclaredSwitchAndRepeatedPrepareKeepTheProfile() {
        let schemaID = "user_scheme"
        let descriptor = EngineOptionDescriptor(
            resourceID: "pkg", schemaID: schemaID, name: "traditionalization", title: "字形",
            disabledLabel: "关闭", enabledLabel: "开启", declaredConversion: "s2t.json")
        let engine = AlphabetEngine(
            schemas: [
                KeyboardSchemaDescriptor(
                    id: schemaID, name: "", alphabet: "abcdefghijklmnopqrstuvwxyz")
            ], options: [EngineOptionState(descriptor: descriptor, value: false)], current: schemaID)
        let session = InputSession(
            engine: engine, layout: .qwerty26,
            resourceSet: resource(schemaID: schemaID, descriptorAlphabet: "abcdefghijklmnopqrstuvwxyz"))
        XCTAssertEqual(
            session.inputLanguage,
            InputLanguageProfile(language: .simplifiedChinese, family: .generic))

        try? session.setOption("traditionalization", value: true)
        XCTAssertEqual(
            session.inputLanguage,
            InputLanguageProfile(language: .traditionalChinese, family: .generic))
        session.reloadOptions()
        session.reloadOptions()
        XCTAssertEqual(
            session.inputLanguage,
            InputLanguageProfile(language: .traditionalChinese, family: .generic))

        try? session.setOption("traditionalization", value: false)
        XCTAssertEqual(
            session.inputLanguage,
            InputLanguageProfile(language: .simplifiedChinese, family: .generic))
    }
}
