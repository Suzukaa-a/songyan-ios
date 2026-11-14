import LayoutKit
import XCTest

final class MergedSplitRowTests: XCTestCase {
    /// Split, the last row fills the halves of the row above; the word-split key and Delete take
    /// the 26-key board's side width and the letters share the rest of each half.
    func testTheSplitLastRowFillsTheUpperHalvesAroundTheSideKeys() {
        // 18 keys: three keys a half above; z xc v | bn m below.
        let widths = MergedKeypadGeometry.splitLastRow(
            upperWidths: [80, 80, 80, 80, 80, 80], upperBreak: 3, lastWeights: [1, 1, 1, 1, 1], lastBreak: 3,
            spacing: 4, sideWidth: 70)
        XCTAssertEqual(widths.left.first ?? 0, 70, accuracy: 0.001)
        XCTAssertEqual(widths.right.last ?? 0, 70, accuracy: 0.001)
        XCTAssertEqual(widths.left.reduce(0, +) + Double(widths.left.count - 1) * 4, 248, accuracy: 0.001)
        XCTAssertEqual(widths.right.reduce(0, +) + Double(widths.right.count - 1) * 4, 248, accuracy: 0.001)
    }
}
