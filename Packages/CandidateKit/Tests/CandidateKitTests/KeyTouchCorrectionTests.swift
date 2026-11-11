import CandidateKit
import XCTest

final class KeyTouchCorrectionTests: XCTestCase {
    func testTheTopOfTheKeyAreaIsReadAsIs() {
        XCTAssertEqual(KeyTouchCorrection.lift(y: 10, rowHeight: 50, areaTop: 10, areaBottom: 210), 0)
    }

    func testTheBottomIsReadNinePercentOfARowHigher() {
        XCTAssertEqual(
            KeyTouchCorrection.lift(y: 210, rowHeight: 50, areaTop: 10, areaBottom: 210), 4.5, accuracy: 0.001)
    }

    func testTheLiftGrowsWithTheDepthInTheArea() {
        XCTAssertEqual(
            KeyTouchCorrection.lift(y: 110, rowHeight: 50, areaTop: 10, areaBottom: 210), 2.25, accuracy: 0.001)
    }

    func testPointsOutsideTheAreaAreClampedAndEmptyAreasDoNothing() {
        XCTAssertEqual(KeyTouchCorrection.lift(y: 0, rowHeight: 50, areaTop: 10, areaBottom: 210), 0)
        XCTAssertEqual(
            KeyTouchCorrection.lift(y: 400, rowHeight: 50, areaTop: 10, areaBottom: 210), 4.5, accuracy: 0.001)
        XCTAssertEqual(KeyTouchCorrection.lift(y: 50, rowHeight: 50, areaTop: 10, areaBottom: 10), 0)
    }

    func testAPressJustBelowARowBoundaryOnTheLowerRowsGoesToTheRowAbove() {
        // Four 50 pt rows: a press 3 pt into the bottom row is read as the row above.
        let y: CGFloat = 153
        let read = y - KeyTouchCorrection.lift(y: y, rowHeight: 50, areaTop: 0, areaBottom: 200)
        XCTAssertLessThan(read, 150)
        XCTAssertLessThan(y - 150, KeyTouchCorrection.band(rowHeight: 50))
    }
}
