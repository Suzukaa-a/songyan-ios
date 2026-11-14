import LayoutKit
import XCTest

final class MergedSplitRowTests: XCTestCase {
    /// Split, the last row fills exactly the halves of the row above: the word-split key and Delete
    /// as wide as a letter, the edges and the gutter in line.
    func testTheSplitLastRowTakesTheUpperHalves() {
        // 14 keys: three keys left and two right above; zx cv | bn m below.
        let widths = MergedKeypadGeometry.splitLastRow(
            upperWidths: [100, 100, 100, 100, 100], upperBreak: 3, lastWeights: [1, 1, 1, 1], lastBreak: 2,
            spacing: 4)
        XCTAssertEqual(widths.left, [100, 100, 100])
        XCTAssertEqual(widths.left.reduce(0, +) + 2 * 4, 308, accuracy: 0.001)
        XCTAssertEqual(widths.right.reduce(0, +) + 2 * 4, 204, accuracy: 0.001)
        XCTAssertEqual(widths.right.count, 3)
    }
}
