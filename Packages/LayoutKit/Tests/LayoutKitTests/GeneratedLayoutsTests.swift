import XCTest

@testable import LayoutKit

final class GeneratedLayoutsTests: XCTestCase {
    private let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)

    func testTheBuiltInBoardMissesWhatItNeverSends() {
        let missing = LayoutCodeCoverage.missing(BuiltinLayouts.qwerty26, needed: letters + [";", "'"])
        XCTAssertTrue(missing.contains(";"))
        XCTAssertTrue(letters.allSatisfy { !missing.contains($0) })
    }

    func testAKeys26BoardSendsEveryCodeTheSchemeNeeds() throws {
        let codes = letters + [";", "'"]
        let board = GeneratedLayouts.keys26(schemaID: "wubi86", name: "26 键＋编码键", codes: codes)
        XCTAssertEqual(board.id, "auto.wubi86.keys26")
        XCTAssertEqual(board.input, LayoutInput(schemaID: "wubi86", builtinLayout: .qwerty26))
        XCTAssertEqual(LayoutCodeCoverage.missing(board, needed: codes), [])
        try board.validate()
        XCTAssertEqual(board.rows[1].keys.map(\.label).suffix(2), [";", "'"])
    }

    func testAGeneratedKeys26BoardListsTheKeysItAdds() {
        // A rime-ice-like profile: the apostrophe is optional for the speller, yet the board carries it.
        let codes = letters + letters.map { $0.uppercased() } + ["`", "'"]
        XCTAssertEqual(LayoutCodeCoverage.missing(BuiltinLayouts.qwerty26, needed: codes), ["`", "'"])
        let board = GeneratedLayouts.keys26(schemaID: "rime_ice", name: "26 键＋编码键", codes: codes)
        XCTAssertEqual(GeneratedLayouts.addedCodes(board), ["`", "'"])
        XCTAssertNil(GeneratedLayouts.addedCodes(BuiltinLayouts.qwerty26))
        XCTAssertNil(GeneratedLayouts.addedCodes(board.copy(name: "mine")))
    }

    func testNeededDigitsBecomeATopRowAndExtraSymbolsJoinIt() {
        let codes = letters + ["3", "1", ";", "'", "`"]
        let board = GeneratedLayouts.keys26(schemaID: "x", name: "n", codes: codes)
        XCTAssertEqual(board.rows[0].keys.map(\.label), ["1", "3", "`"])
        XCTAssertEqual(board.rows.count, BuiltinLayouts.qwerty26.rows.count + 1)
        XCTAssertEqual(LayoutCodeCoverage.missing(board, needed: codes), [])
    }

    func testTheStrokePadHasOneKeyPerStrokeWithItsCaption() throws {
        let strokes = zip(["h", "s", "p", "n", "z"], ["⼀", "⼁", "⼃", "⼂", "⼄"]).map { (code: $0, label: $1) }
        let pad = GeneratedLayouts.strokes(schemaID: "stroke", name: "笔画", strokes: strokes)
        XCTAssertEqual(pad.rows[0].keys.map(\.label), ["⼀", "⼁", "⼃"])
        XCTAssertEqual(pad.rows[1].keys.map(\.label), ["⼂", "⼄", "⌫"])
        XCTAssertEqual(pad.rows[0].keys.map(\.action.value), ["h", "s", "p"])
        XCTAssertEqual(Set(LayoutCodeCoverage.declared(pad)).intersection(letters), ["h", "s", "p", "n", "z"])
        try pad.validate()
    }

    func testALowercaseKeyCoversItsUppercase() {
        let covered = LayoutCodeCoverage.declared(BuiltinLayouts.qwerty26)
        XCTAssertTrue(covered.contains("A") && covered.contains("a"))
    }
}
