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

    /// The keys shrink with the gap: they are not the phone shell's 444 pt beside a narrow gap.
    func testTheGapComesOutOfTheKeysAsWellAsTheCandidates() throws {
        // An iPhone in landscape, about 790 pt: a 15 % gap and two even halves.
        let phone = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(keyAreaWidth: 790, maximumKeypadWidth: 444, side: .left))
        XCTAssertEqual(phone.stripWidth, 118.5, accuracy: 1e-9)
        XCTAssertEqual(phone.keypadWidth, 335.75, accuracy: 1e-9)
        XCTAssertEqual(phone.candidateWidth, 335.75, accuracy: 1e-9)
        // A wider gap narrows the keys too.
        let wider = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(
                keyAreaWidth: 790, maximumKeypadWidth: 444, side: .left, gapPercent: 25))
        XCTAssertLessThan(wider.keypadWidth, phone.keypadWidth)
        // A tablet: the keys stop at the shell's width and the candidates take the rest.
        let tablet = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(keyAreaWidth: 1200, maximumKeypadWidth: 444, side: .left))
        XCTAssertEqual(tablet.keypadWidth, 444)
        XCTAssertEqual(tablet.candidateWidth, 1200 - 180 - 444, accuracy: 1e-9)
        // No gap still leaves room for the swap button.
        let none = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(
                keyAreaWidth: 790, maximumKeypadWidth: 444, side: .left, gapPercent: 0))
        XCTAssertEqual(none.stripWidth, 40)
    }

    func testTooLittleRoomOrOffLeavesTheSideBlank() {
        // 280 pt keys need 560 pt after the gap: 659 pt is short, 660 fits.
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 658, maximumKeypadWidth: 444, side: .left))
        XCTAssertNotNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 660, maximumKeypadWidth: 444, side: .left))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, maximumKeypadWidth: 444, side: .off))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: .nan, maximumKeypadWidth: 444, side: .left))
        XCTAssertEqual(NineKeySideCandidatePolicy.clampedGapPercent(-3), 0)
        XCTAssertEqual(NineKeySideCandidatePolicy.clampedGapPercent(99), 30)
        XCTAssertEqual(NineKeySideCandidatePolicy.clampedGapPercent(17), 15)
    }
}

final class CandidateEmojiWidthTests: XCTestCase {
    /// An emoji draws as one glyph however many scalars it is made of, like a Chinese character.
    func testAnEmojiIsOneCharacterWide() {
        let han = CandidateTextMetrics.estimatedWidth("你", fontSize: 20)
        for emoji in ["😀", "❤️", "👍🏻", "🇨🇳", "👨‍👩‍👧"] {
            XCTAssertEqual(CandidateTextMetrics.estimatedWidth(emoji, fontSize: 20), han, emoji)
        }
        XCTAssertEqual(CandidateTextMetrics.estimatedWidth("a1", fontSize: 20), 2 * 20 * 0.62, accuracy: 1e-9)
    }
}

final class CandidateExpandedGridTests: XCTestCase {
    private func entry(_ text: String, _ index: Int) -> BrowserCandidate {
        BrowserCandidate(
            pageIndex: 0, pageLocalIndex: index,
            candidate: Candidate(index: index, text: text, comment: "", selectKey: nil, selectLabel: nil))
    }

    /// Every row divides into the same columns: a long word spans several, and a short row is
    /// padded with empty cells so the dividers line up from row to row.
    func testRowsSpanWholeColumnsAndPadToTheGrid() {
        let typography = CandidateTypography(candidateSize: 20, secondarySize: 12)
        let rows = CandidateExpandedGrid.rows(
            entries: [entry("你", 0), entry("你好", 1), entry("中华人民共和国", 2), entry("好", 3)],
            columns: 4, columnWidth: 60, typography: typography, cellPaddingX: 8)
        XCTAssertTrue(rows.allSatisfy { $0.reduce(0) { $0 + $1.span } == 4 })
        XCTAssertEqual(rows[0].compactMap(\.entry?.text), ["你", "你好"])
        XCTAssertEqual(rows[1].first?.entry?.text, "中华人民共和国")
        XCTAssertGreaterThan(rows[1].first?.span ?? 0, 1)
        XCTAssertEqual(CandidateExpandedGrid.columns(availableWidth: 300, fontSize: 21), 5)
        XCTAssertEqual(CandidateExpandedGrid.columns(availableWidth: 60, fontSize: 21), 2)
    }
}
