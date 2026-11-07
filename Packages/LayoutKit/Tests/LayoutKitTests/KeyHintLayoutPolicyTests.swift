import XCTest

@testable import LayoutKit

/// A hint is one line, so the letters and hints of a row share two baselines: a long shuangpin
/// final shrinks or truncates, it never wraps and never lifts its letter above its neighbours.
final class KeyHintLayoutPolicyTests: XCTestCase {

    /// Deterministic stand-in for `NSString.size(withAttributes:)`: a fixed advance per character.
    private func width(_ text: String, advance: Double = 5) -> Double {
        Double(text.count) * advance
    }

    // MARK: One line, shrink then truncate

    func testHintsNeverWrap() {
        XCTAssertEqual(KeyHintLayoutPolicy.maximumLines, 1)
        // The 9-character Xiaohe hint in a 24pt column is far too wide for one line; it still takes one.
        XCTAssertLessThan(KeyHintLayoutPolicy.fitScale(measuredWidth: width("iang/uang"), availableWidth: 24), 1)
        XCTAssertEqual(
            KeyHintLayoutPolicy.height(lineHeight: 11), KeyHintLayoutPolicy.singleLineHeight,
            "a hint's band is one line tall however long its text is")
    }

    func testAHintThatFitsKeepsItsSize() {
        for hint in ["iu", "ei", "sh", "ch", "an", "ou"] {
            XCTAssertEqual(KeyHintLayoutPolicy.fitScale(measuredWidth: width(hint), availableWidth: 24), 1)
        }
        XCTAssertEqual(KeyHintLayoutPolicy.fitScale(measuredWidth: 40, availableWidth: 40), 1)
    }

    func testALongHintShrinksToFitDownToTheFloor() {
        let scale = KeyHintLayoutPolicy.fitScale(measuredWidth: 50, availableWidth: 40)
        XCTAssertEqual(scale, 0.8, accuracy: 0.0001)
        XCTAssertFalse(KeyHintLayoutPolicy.truncates(measuredWidth: 50, availableWidth: 40))
    }

    func testATooLongHintStopsAtTheFloorAndTruncates() {
        let scale = KeyHintLayoutPolicy.fitScale(measuredWidth: 100, availableWidth: 40)
        XCTAssertEqual(scale, KeyHintLayoutPolicy.minimumScaleFactor, accuracy: 0.0001)
        XCTAssertTrue(KeyHintLayoutPolicy.truncates(measuredWidth: 100, availableWidth: 40))
    }

    func testDegenerateInputsAreSafe() {
        XCTAssertEqual(KeyHintLayoutPolicy.fitScale(measuredWidth: 40, availableWidth: 0), 1)
        XCTAssertEqual(KeyHintLayoutPolicy.fitScale(measuredWidth: .infinity, availableWidth: 24), 1)
        XCTAssertEqual(KeyHintLayoutPolicy.fitScale(measuredWidth: 40, availableWidth: .nan), 1)
        XCTAssertFalse(KeyHintLayoutPolicy.truncates(measuredWidth: 40, availableWidth: 0))
        XCTAssertEqual(KeyHintLayoutPolicy.height(lineHeight: 0), KeyHintLayoutPolicy.singleLineHeight)
        XCTAssertEqual(KeyHintLayoutPolicy.height(lineHeight: .nan), KeyHintLayoutPolicy.singleLineHeight)
    }

    // MARK: Shared baselines

    /// Key content heights of a portrait and a landscape row, and the letter fonts of the cases below.
    private let contentHeights = [50.0, 42.0, 34.0]

    func testEveryLetterOfARowSitsOnOneBaselineWhateverItsHint() {
        let hint = KeyHintLayoutPolicy.height(lineHeight: 11)
        for height in contentHeights {
            // "a" keeps the band without a hint; "s d" and "l" show a long one, which is one line too.
            let reserved = KeyHintLayoutPolicy.titleMidY(contentHeight: height, lineHeight: 20, hintHeight: hint)
            let shown = KeyHintLayoutPolicy.titleMidY(
                contentHeight: height, lineHeight: 20, hintHeight: KeyHintLayoutPolicy.height(lineHeight: 11))
            XCTAssertEqual(reserved, shown, "content height \(height)")
        }
    }

    func testTheLetterStaysAboveTheHintOnAShortKey() {
        let hint = KeyHintLayoutPolicy.singleLineHeight
        for height in contentHeights {
            let mid = KeyHintLayoutPolicy.titleMidY(contentHeight: height, lineHeight: 20, hintHeight: hint)
            let bottom = mid + 10
            XCTAssertLessThanOrEqual(
                bottom, height - hint - 1 + 0.0001,
                "the letter's line ends above the hint at content height \(height)")
            XCTAssertGreaterThanOrEqual(mid - 10, -2 - 0.0001, "and never rises past the top margin")
        }
    }

    func testAKeyWithoutABandKeepsItsLetterCentred() {
        XCTAssertEqual(KeyHintLayoutPolicy.titleMidY(contentHeight: 50, lineHeight: 20, hintHeight: 0), 25)
    }

    func testABandLiftsTheLetterByTheSameAmountOnEveryTallKey() {
        XCTAssertEqual(KeyHintLayoutPolicy.titleMidY(contentHeight: 50, lineHeight: 20, hintHeight: 12), 21)
        XCTAssertEqual(KeyHintLayoutPolicy.titleMidY(contentHeight: 60, lineHeight: 20, hintHeight: 12), 26)
    }

    // MARK: Per-letter columns on merged keys

    func testMergedKeyColumnsKeepLongHintsReadable() {
        // A pair cap on a 390pt-wide keyboard: 14-key splits the row into five equal caps,
        // 18-key spans two 26-key units plus their gap; both are ~75pt, ~69pt of content.
        let fourteen = (390.0 - 4 * 4) / 5
        let unit = (390.0 - 9 * 4) / 10
        let eighteen = 2 * unit + 4
        for cap in [fourteen, eighteen] {
            let column = KeyHintLayoutPolicy.columnWidth(total: cap - 6, columns: 2)
            XCTAssertGreaterThan(column, 30)
            for hint in ["ing/uai", "iang/uang", "ong/iong"] {
                XCTAssertFalse(
                    KeyHintLayoutPolicy.truncates(measuredWidth: width(hint), availableWidth: column),
                    "\(hint) fits its column by shrinking alone")
            }
        }
    }

    func testColumnSplitLeavesTheGapBetweenColumns() {
        XCTAssertEqual(KeyHintLayoutPolicy.columnWidth(total: 70, columns: 2), 34)
        XCTAssertEqual(KeyHintLayoutPolicy.columnWidth(total: 70, columns: 1), 70)
        XCTAssertEqual(KeyHintLayoutPolicy.columnWidth(total: 70, columns: 0), 0)
    }
}
