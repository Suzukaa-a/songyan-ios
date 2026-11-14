import CandidateKit
import KeyboardCore
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

    /// The keys shrink with the gap; the candidates sit opposite at 90 % of their width.
    func testTheGapComesOutOfTheKeysAsWellAsTheCandidates() throws {
        // An iPhone in landscape, about 790 pt: a 15 % gap, the rest shared 1 : 0.9.
        let phone = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(keyAreaWidth: 790, maximumKeypadWidth: 444, side: .left))
        XCTAssertEqual(phone.keypadWidth, 671.5 / 1.9, accuracy: 1e-9)
        XCTAssertEqual(phone.candidateWidth, phone.keypadWidth * 0.9, accuracy: 1e-9)
        XCTAssertEqual(phone.stripWidth + phone.keypadWidth + phone.candidateWidth, 790, accuracy: 1e-9)
        // A wider gap narrows the keys too.
        let wider = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(
                keyAreaWidth: 790, maximumKeypadWidth: 444, side: .left, gapPercent: 25))
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
        // 280 pt keys need 532 pt after the 15 % gap: 625 pt is short, 627 fits.
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 625, maximumKeypadWidth: 444, side: .left))
        XCTAssertNotNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 627, maximumKeypadWidth: 444, side: .left))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, maximumKeypadWidth: 444, side: .off))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: .nan, maximumKeypadWidth: 444, side: .left))
        XCTAssertEqual(NineKeySideCandidatePolicy.clampedGapPercent(-3), 0)
        XCTAssertEqual(NineKeySideCandidatePolicy.clampedGapPercent(99), 30)
        XCTAssertEqual(NineKeySideCandidatePolicy.clampedGapPercent(17), 15)
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

final class CandidateColumnUnitTests: XCTestCase {
    private func entry(_ text: String, _ index: Int) -> BrowserCandidate {
        BrowserCandidate(
            pageIndex: 0, pageLocalIndex: index,
            candidate: Candidate(index: index, text: text, comment: "", selectKey: nil, selectLabel: nil))
    }

    /// A list of two-character words gets two-character columns: an emoji among them takes one
    /// column like the words, so every row divides the same way.
    func testTheColumnFollowsTheListsTypicalCandidate() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 12)
        let words = ["奶酪", "🧀", "买来", "难看", "南开", "耐劳", "难堪"].enumerated().map { entry($1, $0) }
        let rows = CandidateExpandedFlow.layout(
            entries: words, expanded: .init(), typography: typography, cellPaddingX: 12, availableWidth: 300)
        XCTAssertTrue(rows.allSatisfy { Set($0.widths).count == 1 }, "\(rows.map(\.widths))")
        XCTAssertEqual(rows.map(\.entries.count), [4, 3])
        // Single characters keep narrow columns.
        let singles = ["你", "忙", "梦", "密"].enumerated().map { entry($1, $0) }
        XCTAssertLessThan(
            CandidateExpandedFlow.columnUnit(
                entries: singles, availableWidth: 300, typography: typography, cellPaddingX: 12),
            CandidateExpandedFlow.columnUnit(
                entries: words, availableWidth: 300, typography: typography, cellPaddingX: 12))
    }
}
