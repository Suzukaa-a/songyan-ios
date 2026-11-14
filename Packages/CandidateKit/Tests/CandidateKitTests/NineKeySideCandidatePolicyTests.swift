@testable import CandidateKit
import KeyboardCore
import LayoutKit
import XCTest

final class NineKeySideCandidatePolicyTests: XCTestCase {
    func testLeftIsTheDefaultAndMirroringSwapsSides() {
        XCTAssertEqual(NineKeyCandidateSide.resolve(nil), .left)
        XCTAssertEqual(NineKeyCandidateSide.resolve("bogus"), .left)
        XCTAssertEqual(NineKeyCandidateSide.resolve("off"), .off)
        XCTAssertEqual(NineKeyCandidateSide.left.mirrored, .right)
        XCTAssertEqual(NineKeyCandidateSide.right.mirrored, .left)
        XCTAssertEqual(NineKeyCandidateSide.off.mirrored, .off)
    }

    func testTheKeysDockAwayFromTheCandidates() throws {
        let left = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, maximumKeypadWidth: 444, side: .left))
        XCTAssertEqual(left.keypadDock, .right)
        let right = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, maximumKeypadWidth: 444, side: .right))
        XCTAssertEqual(right.keypadDock, .left)
    }

    /// The gap is the wide-screen middle gap; the keys shrink with it and the candidates sit
    /// opposite at 90 % of their width.
    func testTheGapComesOutOfTheKeysAsWellAsTheCandidates() throws {
        // An iPhone in landscape, about 790 pt: a 62.4 pt gap, the rest shared 1 : 0.9.
        let phone = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(keyAreaWidth: 790, maximumKeypadWidth: 444, side: .left))
        XCTAssertEqual(phone.stripWidth, WideMiddleGap.width(for: 790, percent: 10), accuracy: 1e-9)
        XCTAssertEqual(phone.keypadWidth, (790 - phone.stripWidth) / 1.9, accuracy: 1e-9)
        XCTAssertEqual(phone.candidateWidth, phone.keypadWidth * 0.9, accuracy: 1e-9)
        // A wider gap narrows the keys too.
        let wider = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(
                keyAreaWidth: 790, maximumKeypadWidth: 444, side: .left, gapPercent: 20))
        XCTAssertLessThan(wider.keypadWidth, phone.keypadWidth)
        // A tablet: the keys stop at the shell's width and the gap takes the rest.
        let tablet = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(keyAreaWidth: 1200, maximumKeypadWidth: 444, side: .left))
        XCTAssertEqual(tablet.keypadWidth, 444)
        XCTAssertEqual(tablet.stripWidth, 1200 - 444 * 1.9, accuracy: 1e-9)
        // No gap still leaves room for the swap button.
        let none = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(
                keyAreaWidth: 790, maximumKeypadWidth: 444, side: .left, gapPercent: 0))
        XCTAssertEqual(none.stripWidth, 40, accuracy: 1e-9)
    }

    func testTooLittleRoomOrOffLeavesTheSideBlank() {
        // 280 pt keys, a 252 pt column and the 40 pt button need 572 pt: 570 is short, 574 fits.
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 570, maximumKeypadWidth: 444, side: .left))
        XCTAssertNotNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 574, maximumKeypadWidth: 444, side: .left))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, maximumKeypadWidth: 444, side: .off))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: .nan, maximumKeypadWidth: 444, side: .left))
    }
}

final class CandidateEmojiWidthTests: XCTestCase {
    /// An emoji draws as one glyph however many scalars it is made of, a little wider than a
    /// Chinese character.
    func testAnEmojiIsOneGlyphWide() {
        let han = CandidateTextMetrics.estimatedWidth("你", fontSize: 20)
        XCTAssertEqual(han, 20)
        for emoji in ["😀", "❤️", "👍🏻", "🇨🇳", "👨‍👩‍👧"] {
            XCTAssertEqual(CandidateTextMetrics.estimatedWidth(emoji, fontSize: 20), 25, emoji)
        }
        XCTAssertEqual(CandidateTextMetrics.estimatedWidth("a1", fontSize: 20), 2 * 20 * 0.62, accuracy: 1e-9)
    }
}

final class CandidateExpandedFirstRowTests: XCTestCase {
    /// Expanded, the strip stays as the first row: the cells it shows whole are counted, and the
    /// list below starts after them.
    func testTheListStartsAfterTheStripsWholeCells() {
        XCTAssertEqual(
            CandidateCollapsedFlow.wholeCellCount(cellWidths: [44, 44, 60, 44], spacing: 5, viewportWidth: 158), 3)
        XCTAssertEqual(
            CandidateCollapsedFlow.wholeCellCount(cellWidths: [44, 44, 60, 44], spacing: 5, viewportWidth: 157), 2)
        XCTAssertEqual(CandidateCollapsedFlow.wholeCellCount(cellWidths: [44], spacing: 5, viewportWidth: 300), 1)
        let candidates = (0..<5).map {
            Candidate(index: $0, text: "字\($0)", comment: "", selectKey: nil, selectLabel: nil)
        }
        let state = CandidatePresentationState(
            preedit: "zi", rawInput: "zi", candidates: candidates, highlightedIndex: 0,
            pageIndex: 0, canPageBackward: false, canPageForward: false, isComposing: true)
        var context = CandidateAreaContext(
            state: state, bar: .systemDefault, actions: CandidateAreaActionSink { _ in },
            typography: .init(candidateSize: 20, secondarySize: 10), browser: CandidateBrowser(), isExpanded: true)
        context.expandedSkips = 3
        XCTAssertEqual(context.expandedEntries.map(\.text), ["字3", "字4"])
        XCTAssertEqual(context.displayEntries.count, 5, "the strip still has them all")
    }
}

final class CandidateJustifiedRowsTests: XCTestCase {
    private func entry(_ text: String, _ index: Int) -> BrowserCandidate {
        BrowserCandidate(
            pageIndex: 0, pageLocalIndex: index,
            candidate: Candidate(index: index, text: text, comment: "", selectKey: nil, selectLabel: nil))
    }

    /// Each full row reaches the edge with its cells touching, so the rule between two candidates
    /// sits halfway between them; the last row keeps the earlier rows' share and stays short.
    func testFullRowsReachTheEdgeAndTheTailKeepsTheirRhythm() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 12)
        let entries = (0..<9).map { entry(String(repeating: "字", count: $0 % 3 + 1), $0) }
        let flowed = CandidateExpandedFlow.layout(
            entries: entries, expanded: .init(), typography: typography, cellPaddingX: 7, availableWidth: 300)
        let rows = CandidateExpandedFlow.justified(flowed, availableWidth: 300, spacing: 5)
        XCTAssertGreaterThan(rows.count, 1)
        for row in rows.dropLast() { XCTAssertEqual(row.widths.reduce(0, +), 300, accuracy: 0.001) }
        XCTAssertLessThanOrEqual(rows.last!.widths.reduce(0, +), 300.001)
        // Every cell of a row grew by the same amount.
        for (plain, spread) in zip(flowed, rows) {
            let grown = zip(plain.widths, spread.widths).map { $1 - $0 }
            XCTAssertTrue(grown.allSatisfy { abs($0 - grown[0]) < 0.001 })
        }
    }

    func testFillerRowsNeverShareAnIdWithTheCandidates() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 12)
        let rows = CandidateExpandedFlow.layout(
            entries: [entry("你", 0), entry("好", 1)], expanded: .init(), typography: typography,
            cellPaddingX: 12, availableWidth: 300)
        let grid = CandidateExpandedFlow.gridRows(rows, minimumRows: 4)
        XCTAssertEqual(grid.map(\.id), [0, 1, 2, 3])
        XCTAssertNotNil(grid[0].row, "the candidates come first")
    }
}
