import XCTest

@testable import KeyboardCore

/// The bundled scheme's one four-state group is recognized only when the scheme and its complete
/// declaration are the bundled ones, so a scheme an author words itself keeps its own labels.
final class BuiltinScriptStateTests: XCTestCase {
    private let canonicalLabels = ["简体", "繁體", "臺灣", "香港"]
    private var canonicalOptions: [String] { BuiltinScriptState.allCases.map(\.optionName) }

    func testTheBundledSchemesFourStatesAreRecognized() {
        for schemaID in BuiltinTemplateSchemas.sourceSchemaIDs {
            XCTAssertEqual(
                BuiltinScriptState.knownStates(
                    schemaID: schemaID, options: canonicalOptions, labels: canonicalLabels),
                [.simplified, .traditional, .taiwan, .hongKong], schemaID)
        }
    }

    func testASchemeThatWordsItsOwnLabelsKeepsThem() {
        XCTAssertNil(
            BuiltinScriptState.knownStates(
                schemaID: "songyan_quanpin", options: canonicalOptions,
                labels: ["简体", "通繁", "臺繁", "港繁"]))
    }

    func testOnlyTheBundledSchemesAreRecognized() {
        XCTAssertNil(
            BuiltinScriptState.knownStates(
                schemaID: "luna_pinyin", options: canonicalOptions, labels: canonicalLabels))
    }

    func testAnIncompleteOrReorderedGroupIsNotRecognized() {
        XCTAssertNil(
            BuiltinScriptState.knownStates(
                schemaID: "songyan_quanpin", options: ["simplification", "zht"],
                labels: ["简体", "繁體"]))
        XCTAssertNil(
            BuiltinScriptState.knownStates(
                schemaID: "songyan_quanpin",
                options: ["zht", "simplification", "zh_tw", "zh_hk"], labels: canonicalLabels))
    }

    func testTheGroupOrderIsTheSchemaOptionOrder() {
        XCTAssertEqual(BuiltinScriptState.allCases.map(\.optionName), canonicalOptions)
        XCTAssertEqual(BuiltinScriptState.canonicalSchemaLabels, canonicalLabels)
    }
}
