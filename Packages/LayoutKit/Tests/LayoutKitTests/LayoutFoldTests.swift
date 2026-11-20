import XCTest

@testable import LayoutKit

/// One reading of merged keys for 14, 18 and 9 keys: the codes written on the keys, never the titles.
final class LayoutFoldTests: XCTestCase {
    private func firstRowKey(_ definition: LayoutDefinition, _ index: Int) -> LayoutKey {
        definition.rows[0].keys[index]
    }

    /// `definition` with the keys equal to the given ones covering the given codes, as the editor writes them.
    private func withCodes(
        _ definition: LayoutDefinition, _ kind: LayoutInput.Builtin, _ changes: [(LayoutKey, String)]
    ) -> LayoutDefinition {
        var result = LayoutFold.writtenOut(definition, kind: kind)
        for (original, codes) in changes {
            result.rows = result.rows.map { row in
                LayoutRow(
                    keys: row.keys.map { key in
                        key.label == original.label && key.action == original.action
                            ? LayoutFold.key(key, covering: codes) : key
                    })
            }
        }
        return result
    }

    private var merged14: LayoutDefinition { BuiltinLayouts.merged14 }

    func testTheBundledLayoutsFoldIntoTheBundledGroupings() throws {
        let map14 = try XCTUnwrap(LayoutFold.map(merged14, kind: .merged14))
        XCTAssertEqual(map14["w"], "q")
        XCTAssertEqual(map14.count, 26)
        XCTAssertEqual(LayoutFold.map(BuiltinLayouts.phone9, kind: .phone9)?["c"], "2")
        XCTAssertEqual(LayoutFold.map(BuiltinLayouts.merged18, kind: .merged18)?.count, 26)
        // Writing out the bundled grouping changes nothing.
        XCTAssertEqual(LayoutFold.map(LayoutFold.writtenOut(merged14, kind: .merged14), kind: .merged14), map14)
    }

    func testTitlesOnlySayWhatTheKeysShow() {
        var retitled = merged14
        retitled.rows[0] = LayoutRow(keys: [firstRowKey(merged14, 0).title("Q")] + merged14.rows[0].keys.dropFirst())
        XCTAssertEqual(LayoutFold.map(retitled, kind: .merged14), LayoutFold.map(merged14, kind: .merged14))
        XCTAssertEqual(LayoutFold.codesOn(retitled, kind: .merged14, key: firstRowKey(retitled, 0)), ["q", "w"])
    }

    func testARegroupedFourteenKeyLayoutFoldsAsWritten() throws {
        let moved = withCodes(
            merged14, .merged14, [(firstRowKey(merged14, 0), "q"), (firstRowKey(merged14, 1), "wer")])
        let map = try XCTUnwrap(LayoutFold.map(moved, kind: .merged14))
        XCTAssertEqual(map["w"], "e")
        XCTAssertEqual(map["q"], "q")
        // ER kept sending e, which is still among its codes.
        XCTAssertEqual(firstRowKey(moved, 1).action.value, "e")
        XCTAssertTrue(LayoutFold.repeated(moved).isEmpty)
        XCTAssertEqual(LayoutFold.coverage(moved), LayoutFold.coverage(merged14))
    }

    func testAKeyWhoseCodeLeftItsCodesSendsTheFirstOfThem() throws {
        XCTAssertEqual(LayoutFold.key(firstRowKey(merged14, 1), covering: "wr").action.value, "w")
        let two = try XCTUnwrap(BuiltinLayouts.phone9.rows.flatMap(\.keys).first { $0.action.value == "2" })
        XCTAssertEqual(LayoutFold.key(two, covering: "ab").action.value, "2")
    }

    func testRepeatedCodesAndDroppedCodesAreNamed() {
        let repeated = withCodes(merged14, .merged14, [(firstRowKey(merged14, 0), "qwe")])
        XCTAssertNil(LayoutFold.map(repeated, kind: .merged14))
        XCTAssertEqual(LayoutFold.repeated(repeated), ["e"])
        let dropped = withCodes(merged14, .merged14, [(firstRowKey(merged14, 1), "r")])
        XCTAssertEqual(LayoutFold.coverage(merged14).subtracting(LayoutFold.coverage(dropped)), ["e"])
    }

    func testStrokesAndMarksAreCodesLikeAnyOther() {
        let withMark = withCodes(merged14, .merged14, [(firstRowKey(merged14, 0), "qw;")])
        XCTAssertTrue(LayoutFold.coverage(withMark).contains(";"))
        XCTAssertTrue(LayoutFold.unusable(withMark).isEmpty)
        XCTAssertEqual(LayoutFold.map(withMark, kind: .merged14)?[";"], "q")
    }

    func testOnlyPrintableAsciiCanBeACode() {
        // librime reads a key as one printable ASCII character; a stroke drawn as 一 never reaches it.
        let drawn = withCodes(merged14, .merged14, [(firstRowKey(merged14, 0), "qw一")])
        XCTAssertEqual(LayoutFold.unusable(drawn), ["一"])
        var fullWidth = BuiltinLayouts.qwerty26
        fullWidth.rows[0] = LayoutRow(
            keys: [firstRowKey(fullWidth, 0).settingAction(LayoutAction(.code, value: "ｑ"))]
                + fullWidth.rows[0].keys.dropFirst())
        XCTAssertEqual(LayoutFold.unusable(fullWidth), ["ｑ"])
        for layout in BuiltinLayouts.all { XCTAssertEqual(LayoutFold.unusable(layout), [], layout.id) }
    }

    func testAnImportedLayoutThatNamesNoKindIsKnownByWhatItsKeysSend() {
        let unnamed = LayoutDefinition(id: "x", name: "x", input: LayoutInput(), rows: merged14.rows)
        XCTAssertEqual(LayoutFold.kind(of: unnamed), .merged14)
        XCTAssertEqual(LayoutFold.map(unnamed, kind: .merged14), LayoutFold.map(merged14, kind: .merged14))
        XCTAssertNil(LayoutFold.kind(of: BuiltinLayouts.qwerty26))
    }

    func testAMergedKeyboardReportsOnlyTheCodesItCoversLessThanTheBundledOne() {
        let needed = "abcdefghijklmnopqrstuvwxyz".map(String.init) + ["'", ";"]
        // The bundled 14 keys never send ';' and that is how the scheme is typed on them.
        XCTAssertEqual(
            LayoutCodeCoverage.missingToReport(merged14, kind: .merged14, needed: needed, optional: ["'"]), [])
        let dropped = withCodes(merged14, .merged14, [(firstRowKey(merged14, 1), "r")])
        XCTAssertEqual(
            LayoutCodeCoverage.missingToReport(dropped, kind: .merged14, needed: needed, optional: ["'"]), ["e"])
        XCTAssertEqual(
            LayoutCodeCoverage.missingToReport(
                BuiltinLayouts.phone9, kind: .phone9, needed: needed, optional: ["'"]), [])
    }

    func testWrittenCodesRoundTripThroughJSON() throws {
        let moved = withCodes(merged14, .merged14, [(firstRowKey(merged14, 0), "q")])
        let data = try JSONEncoder().encode(moved)
        XCTAssertEqual(try JSONDecoder().decode(LayoutDefinition.self, from: data), moved)
        // A key without codes writes no field, so files from before stay as they were.
        let plain = try JSONEncoder().encode(merged14)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("\"codes\""))
    }
}
