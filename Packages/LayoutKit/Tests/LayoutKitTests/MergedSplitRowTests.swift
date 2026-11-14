import LayoutKit
import XCTest

final class MergedSplitRowTests: XCTestCase {
    /// Split, the last row's keys are all one size and span what the row above spends on keys, so
    /// with the same gutter the outer edges line up; no half is crammed.
    func testTheSplitLastRowIsEvenAndSpansTheRowAbove() {
        // 14 keys: five keys above; zx cv bn m below with the word-split key and Delete.
        let widths = MergedKeypadGeometry.splitLastRow(
            upperWidths: [100, 100, 100, 100, 100], lastWeights: [1, 1, 1, 1], spacing: 4)
        XCTAssertEqual(widths.count, 6)
        XCTAssertTrue(widths.allSatisfy { abs($0 - widths[0]) < 0.001 })
        XCTAssertEqual(widths.reduce(0, +) + 5 * 4, 500 + 4 * 4, accuracy: 0.001)
    }
}
