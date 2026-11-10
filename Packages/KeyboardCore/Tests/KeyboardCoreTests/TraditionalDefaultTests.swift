import XCTest

@testable import KeyboardCore

/// The bundled scheme's four script states: a locale may seed a new installation, never replace an
/// existing user's choice. Mirrors the Android `TraditionalDefaultTest` case for case.
final class TraditionalDefaultTests: XCTestCase {
    private func state(_ tags: [String], existing: Bool = false) -> BuiltinScriptState? {
        TraditionalDefault.initialState(localeTags: tags, hasExistingSettings: existing)
    }

    func testTaiwanStartsWithTaiwanPhrases() {
        for tag in ["zh-TW", "zh-Hant-TW"] {
            XCTAssertEqual(state([tag]), .taiwan, tag)
        }
    }

    func testHongKongAndMacaoStartWithHongKongForms() {
        for tag in ["zh-HK", "zh-MO", "zh-Hant-HK", "zh-Hant-MO"] {
            XCTAssertEqual(state([tag]), .hongKong, tag)
        }
    }

    func testOtherTraditionalLocalesStartWithTraditionalForms() {
        for tag in ["zh-Hant", "zh-Hant-US"] {
            XCTAssertEqual(state([tag]), .traditional, tag)
        }
    }

    func testSimplifiedAndOtherLocalesKeepTheSimplifiedDefault() {
        for tags in [[String](), ["zh"], ["zh-CN"], ["ja-JP"], ["en-US"]] {
            XCTAssertEqual(state(tags), .simplified, "\(tags)")
        }
    }

    func testAnExplicitSimplifiedScriptWinsOverTheRegion() {
        XCTAssertEqual(state(["zh-Hans-TW"]), .simplified)
    }

    func testExistingUserSettingsAreNeverReplacedByLocaleDefaults() {
        XCTAssertNil(state(["zh-TW"], existing: true))
        XCTAssertNil(state(["ja-JP"], existing: true))
    }

    func testTheGroupKeepsTheSchemaOptionNamesAndOrder() {
        XCTAssertEqual(BuiltinScriptState.allCases.map(\.optionName), ["simplification", "zht", "zh_tw", "zh_hk"])
        XCTAssertEqual(TraditionalDefault.optionGroup, ["simplification", "zht", "zh_tw", "zh_hk"])
    }

    // MARK: - Installing the default (the same rule the keyboard boot calls)

    private let schemas = ["songyan_quanpin", "songyan_flypy"]

    private func seed(
        _ tags: [String], existing: Set<String> = [], failOn: Set<String> = []
    ) -> (BuiltinScriptDefault.SeedOutcome?, [EngineOptionDescriptor]) {
        var written: [EngineOptionDescriptor] = []
        let outcome = BuiltinScriptDefault.seedIfNeeded(
            evidence: BuiltinScriptBootstrapEvidence(hostEra: .current), localeTags: tags,
            resourceID: "songyan-builtin", schemaIDs: schemas,
            readChoice: { existing.contains($0) },
            write: { option in
                if failOn.contains(option.schemaID) { throw CocoaError(.fileWriteUnknown) }
                written.append(option)
            })
        return (outcome, written)
    }

    func testANewTaiwanInstallSeedsEveryBuiltinSchemeWithOneExclusiveState() {
        let (outcome, written) = seed(["zh-Hant-TW"])
        XCTAssertEqual(outcome?.state, .taiwan)
        XCTAssertEqual(outcome?.seededSchemaIDs, schemas)
        XCTAssertTrue(outcome?.isComplete == true)
        XCTAssertEqual(written.map(\.schemaID), schemas)
        XCTAssertEqual(written.map(\.name), ["zh_tw", "zh_tw"])
        XCTAssertEqual(Set(written.map { $0.choiceGroup.first }), ["simplification"])
    }

    func testASchemeWithAnExplicitChoiceKeepsItWhileASiblingIsSeeded() {
        let (outcome, written) = seed(["zh-Hant-TW"], existing: ["songyan_flypy"])
        XCTAssertEqual(outcome?.state, .taiwan)
        XCTAssertEqual(outcome?.seededSchemaIDs, ["songyan_quanpin"])
        XCTAssertEqual(written.map(\.schemaID), ["songyan_quanpin"])
    }

    func testAFailedWriteIsReportedInsteadOfClaimed() {
        let (outcome, written) = seed(["zh-Hant-TW"], failOn: ["songyan_flypy"])
        XCTAssertEqual(outcome?.seededSchemaIDs, ["songyan_quanpin"])
        XCTAssertEqual(outcome?.failedSchemaIDs, ["songyan_flypy"])
        XCTAssertFalse(outcome?.isComplete == true)
        XCTAssertEqual(written.map(\.schemaID), ["songyan_quanpin"])
    }

    func testAReadFailureIsReportedAndNeverOverwritten() {
        var written: [EngineOptionDescriptor] = []
        let outcome = BuiltinScriptDefault.seedIfNeeded(
            evidence: BuiltinScriptBootstrapEvidence(hostEra: .current), localeTags: ["zh-Hant-TW"],
            resourceID: "songyan-builtin", schemaIDs: schemas,
            readChoice: { schemaID in
                if schemaID == "songyan_quanpin" { throw CocoaError(.fileReadCorruptFile) }
                return false
            },
            write: { written.append($0) })
        XCTAssertEqual(outcome?.failedSchemaIDs, ["songyan_quanpin"])
        XCTAssertEqual(outcome?.seededSchemaIDs, ["songyan_flypy"])
        XCTAssertFalse(outcome?.isComplete == true)
        XCTAssertEqual(written.map(\.schemaID), ["songyan_flypy"], "an unreadable choice is never written over")
    }

    func testAnExistingInstallSeedsNothing() {
        var written: [EngineOptionDescriptor] = []
        let outcome = BuiltinScriptDefault.seedIfNeeded(
            evidence: BuiltinScriptBootstrapEvidence(hostEra: .legacy), localeTags: ["zh-Hant-TW"],
            resourceID: "songyan-builtin", schemaIDs: schemas,
            readChoice: { _ in false }, write: { written.append($0) })
        XCTAssertNil(outcome)
        XCTAssertTrue(written.isEmpty)
    }

    func testASameRevisionPriorInstallIsStillLegacy() {
        XCTAssertTrue(
            BuiltinScriptEraRecord.hostIndicatesExistingInstall(
                installed: true, recorded: true, userSettings: false))
        XCTAssertTrue(
            BuiltinScriptEraRecord.hostIndicatesExistingInstall(
                installed: false, recorded: true, userSettings: false))
        XCTAssertFalse(
            BuiltinScriptEraRecord.hostIndicatesExistingInstall(
                installed: false, recorded: false, userSettings: false))
    }

    func testBothBuiltinIdentitiesShareTheOptionStoreNamespace() {
        XCTAssertTrue(BuiltinScriptIdentity.isBuiltin("builtin"))
        XCTAssertTrue(BuiltinScriptIdentity.isBuiltin("songyan-builtin"))
        XCTAssertFalse(BuiltinScriptIdentity.isBuiltin("scheme-abc"))
        XCTAssertEqual(BuiltinScriptIdentity.optionStoreResourceID("builtin"), "songyan-builtin")
        XCTAssertEqual(BuiltinScriptIdentity.optionStoreResourceID("scheme-abc"), "scheme-abc")
    }

    func testTheEraIsRecordedOnceFromRealPrivateData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "era-" + UUID().uuidString))
        XCTAssertEqual(
            BuiltinScriptEraRecord.decideAndRecord(
                hostEra: nil, userDirectory: directory, defaults: defaults), .current,
            "an empty private container is a fresh install")
        try Data("x".utf8).write(to: directory.appendingPathComponent("build"))
        let second = try XCTUnwrap(UserDefaults(suiteName: "era-" + UUID().uuidString))
        XCTAssertEqual(
            BuiltinScriptEraRecord.decideAndRecord(
                hostEra: nil, userDirectory: directory, defaults: second), .legacy,
            "existing private engine data is an old install")
        // A recorded era is final: a later import/first run must not relabel it.
        XCTAssertEqual(
            BuiltinScriptEraRecord.decideAndRecord(
                hostEra: .legacy, userDirectory: directory, defaults: second), .legacy)
    }
}
