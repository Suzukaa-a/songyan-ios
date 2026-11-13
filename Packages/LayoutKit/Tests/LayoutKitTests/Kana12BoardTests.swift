import XCTest

@testable import LayoutKit

/// An edited twelve-key board is still the twelve-key board: it keeps its own labels and side keys
/// instead of falling back to ordinary rows (which cannot draw its rails or its わ row).
final class Kana12BoardTests: XCTestCase {
    func testTheBundledBoardReadsAsTwelveKeys() throws {
        let board = try XCTUnwrap(Kana12Board.of(BuiltinLayouts.kana12))
        XCTAssertEqual(board.grid.map(\.count), [3, 3, 3, 3])
        XCTAssertEqual(board.leading.map(\.action.type), [.cursorLeft, .pageSwitch, .languageSwitch, .globe])
        XCTAssertEqual(board.trailing.map(\.action.type), [.backspace, .space, .enter])
        XCTAssertNotNil(board.leadingArea)
    }

    func testAnEditedBoardStaysATwelveKeyBoardWithItsOwnLabels() throws {
        var rows = BuiltinLayouts.kana12.rows
        var keys = rows[0].keys
        keys[0] = keys[0].settingLabel("ア")
        rows[0] = LayoutRow(keys: keys)
        let edited = BuiltinLayouts.kana12.copy().replacingRowsFollowingSplit(rows)
        let board = try XCTUnwrap(Kana12Board.of(edited))
        XCTAssertEqual(board.grid[0][0].label, "ア")
        XCTAssertEqual(board.grid[0][0].action.value, "a")
    }

    func testOtherShapesAreNotTwelveKeyBoards() {
        XCTAssertNil(Kana12Board.of(BuiltinLayouts.qwerty26))
        var rows = BuiltinLayouts.kana12.rows
        rows.removeLast()
        XCTAssertNil(Kana12Board.of(BuiltinLayouts.kana12.copy().replacingRowsFollowingSplit(rows)))
    }

    func testAPageWithoutSideAreasBorrowsTheMainLayouts() throws {
        var page = BuiltinLayouts.kana12.copy()
        page.auxiliaryAreas = nil
        XCTAssertNil(Kana12Board.of(page))
        let board = try XCTUnwrap(Kana12Board.of(page, mainLayout: BuiltinLayouts.kana12))
        XCTAssertNil(board.leadingArea, "borrowed keys are not this page's to edit")
        XCTAssertEqual(board.trailing.count, 3)
    }

    func testSideKeysShareTheFourRows() {
        XCTAssertEqual(Kana12Board.railSpans(count: 4), [1, 1, 1, 1])
        XCTAssertEqual(Kana12Board.railSpans(count: 3), [1, 1, 2])
        XCTAssertEqual(Kana12Board.railSpans(count: 1), [4])
        XCTAssertEqual(Kana12Board.railSpans(count: 5), Array(repeating: 0.8, count: 5))
    }
}
