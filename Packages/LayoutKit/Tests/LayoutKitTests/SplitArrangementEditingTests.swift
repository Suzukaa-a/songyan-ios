import XCTest

@testable import LayoutKit

final class SplitArrangementEditingTests: XCTestCase {
    private let start = BuiltinLayouts.qwerty26
    private var defaults: [Int]? { BuiltinLayouts.handSplit(for: start)?.rowBreaks }

    private func letter(_ c: Character) -> LayoutKey {
        LayoutKey(label: String(c), action: LayoutAction(.code, value: String(c)))
    }

    private func text(_ rows: [LayoutRow]) -> [String] { rows.map { $0.keys.map(\.label).joined() } }

    private func adding(_ c: Character, after address: SplitKeyAddress, to layout: LayoutDefinition? = nil)
        throws -> LayoutDefinition
    {
        try XCTUnwrap((layout ?? start).addingSplitKey(after: address, key: letter(c), defaultBreaks: defaults)).layout
    }

    func testTheSplitViewShowsTheRowsCutAtTheirBreaksUntilTheFirstEdit() {
        XCTAssertEqual(text(start.splitLetterRows(defaultBreaks: defaults)), ["qwertyuiop", "asdfghjkl", "zxcvbnm"])
        XCTAssertEqual(start.splitCuts(defaultBreaks: defaults), [5, 5, 5])
        XCTAssertFalse(start.hasExplicitSplit)
        XCTAssertEqual(start.splitLetterIndices, [0, 1, 2])
    }

    func testTheFirstEditMakesTheArrangementExplicitAndLeavesTheWholeRowsAlone() throws {
        let added = try adding("y", after: SplitKeyAddress(row: 0, key: 4))
        XCTAssertTrue(added.hasExplicitSplit)
        let halves = try XCTUnwrap(added.split?.halves)
        XCTAssertEqual(halves[0].left.map(\.label).joined(), "qwerty")
        XCTAssertEqual(halves[0].right.map(\.label).joined(), "yuiop")
        XCTAssertEqual(added.rows, start.rows)
        // One entry per row of the layout, the control row's two space halves included.
        XCTAssertEqual(halves.count, start.rows.count)
        XCTAssertEqual(halves.last?.left.last?.action.type, .space)
        XCTAssertNoThrow(try added.validate())
        // A pure relabel of a key makes it explicit as well.
        let relabelled = start.replacingSplitKey(
            at: SplitKeyAddress(row: 0, key: 0), with: letter("q").settingLabel("Q"), defaultBreaks: defaults)
        XCTAssertTrue(relabelled.hasExplicitSplit)
        XCTAssertEqual(relabelled.split?.halves?[0].left.first?.label, "Q")
        XCTAssertEqual(relabelled.rows, start.rows)
    }

    func testAKeyAddedBeforeTheCutIsInTheLeftHalfAndAfterItInTheRight() throws {
        let left = try adding("1", after: SplitKeyAddress(row: 1, key: 0))
        XCTAssertEqual(left.splitCuts()[1], 6)
        let right = try adding("2", after: SplitKeyAddress(row: 1, key: 5))
        XCTAssertEqual(right.splitCuts()[1], 5)
    }

    func testAHalfKeepsItsLastKey() throws {
        var layout = start
        // Row 2 is zxcvb | nm: take the right half down to one key, then try to remove that one.
        layout = try XCTUnwrap(layout.removingSplitKey(at: SplitKeyAddress(row: 2, key: 6), defaultBreaks: defaults))
            .layout
        XCTAssertEqual(layout.splitCuts()[2], 5)
        XCTAssertNil(layout.removingSplitKey(at: SplitKeyAddress(row: 2, key: 5)))
        XCTAssertNotNil(layout.removingSplitKey(at: SplitKeyAddress(row: 2, key: 0)))
    }

    func testMovingACutEditsTheBreakWithoutAnArrangementAndMovesAKeyAcrossWithOne() throws {
        let moved = try XCTUnwrap(start.movingSplitCut(row: 0, by: -1, defaultBreaks: defaults))
        XCTAssertFalse(moved.hasExplicitSplit)
        XCTAssertEqual(moved.split?.breakIndex(row: 0, keyCount: 10), 4)
        // Rows the user did not touch keep the keyboard's own cut.
        XCTAssertEqual(moved.splitCuts(defaultBreaks: nil).prefix(1), [4])
        let explicit = try adding("y", after: SplitKeyAddress(row: 0, key: 0))
        let across = try XCTUnwrap(explicit.movingSplitCut(row: 0, by: 1))
        XCTAssertEqual(across.splitCuts()[0], explicit.splitCuts()[0] + 1)
        XCTAssertEqual(text(across.splitLetterRows()), text(explicit.splitLetterRows()))
        XCTAssertNil(start.movingSplitCut(row: 0, by: -5, defaultBreaks: defaults))
    }

    func testMovingAKeyKeepsTheCuts() throws {
        let moved = try XCTUnwrap(
            start.movingSplitKey(at: SplitKeyAddress(row: 0, key: 4), by: 1, defaultBreaks: defaults))
        XCTAssertEqual(text(moved.layout.splitLetterRows())[0], "qwertyuiop".replacingOccurrences(of: "ty", with: "yt"))
        XCTAssertEqual(moved.layout.splitCuts()[0], 5)
        XCTAssertEqual(moved.selected, SplitKeyAddress(row: 0, key: 5))
    }

    func testRestoringTheAutomaticSplitDropsTheArrangement() throws {
        let explicit = try adding("y", after: SplitKeyAddress(row: 0, key: 0))
        let restored = explicit.restoringAutomaticSplit()
        XCTAssertNil(restored.split?.halves)
        XCTAssertEqual(restored.splitCuts(defaultBreaks: defaults)[0], 5)
    }

    func testRowsAddedRemovedOrMovedInTheWholeViewFollowIntoTheArrangement() throws {
        let explicit = try adding("y", after: SplitKeyAddress(row: 0, key: 0))
        let added = explicit.replacingRowsFollowingSplit(explicit.rows + [LayoutRow(keys: [letter("9")])])
        let halves = try XCTUnwrap(added.split?.halves)
        XCTAssertEqual(halves.count, added.rows.count)
        XCTAssertNoThrow(try added.validate())
        XCTAssertEqual(halves.last?.keys.map(\.label), ["9"])
        // The control row's entry is the one that was there.
        XCTAssertEqual(halves[3], explicit.split?.halves?[3])

        var swapped = explicit.rows
        swapped.swapAt(0, 1)
        let moved = explicit.replacingRowsFollowingSplit(swapped)
        XCTAssertEqual(moved.split?.halves?[1], explicit.split?.halves?[0])
        XCTAssertEqual(moved.split?.halves?[0], explicit.split?.halves?[1])

        var dropped = explicit.rows
        dropped.remove(at: 1)
        let removed = explicit.replacingRowsFollowingSplit(dropped)
        XCTAssertEqual(
            removed.split?.halves,
            [explicit.split?.halves?[0], explicit.split?.halves?[2], explicit.split?.halves?[3]].compactMap { $0 })
        XCTAssertNoThrow(try removed.validate())

        // A key edit of a whole row does not reach the arrangement.
        var edited = explicit.rows
        edited[0] = LayoutRow(keys: [letter("q")] + edited[0].keys.dropFirst())
        XCTAssertEqual(explicit.replacingRowsFollowingSplit(edited).split?.halves, explicit.split?.halves)
    }

    func testTheGapDefaultsToAutomatic() {
        XCTAssertTrue(LayoutSplitConfiguration(activation: .always).automaticGap)
    }
}
