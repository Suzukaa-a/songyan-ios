import LayoutKit
import XCTest

final class MergedSplitRowTests: XCTestCase {
    /// Split, the last row's letters keep the upper rows' width instead of stretching across the
    /// room the narrower side keys leave.
    func testASplitLastRowKeepsTheUpperLetterWidth() {
        let weights: [[Double]] = [[1, 1.5, 1.5, 1, 1, 1.5, 1], [1, 1.5, 1.5, 1, 1.5, 1], [1, 1.5, 1, 1.5, 1]]
        let split = MergedKeypadGeometry.rows(
            weights: weights, width: 600, spacing: 4, sideWidth: 60, matchesUpperKeys: true)
        let whole = MergedKeypadGeometry.rows(weights: weights, width: 600, spacing: 4, sideWidth: 60)
        XCTAssertEqual(split[2].keyWidths[0], split[0].keyWidths[0], accuracy: 0.001)
        XCTAssertGreaterThan(whole[2].keyWidths[0], split[2].keyWidths[0])
    }
}
