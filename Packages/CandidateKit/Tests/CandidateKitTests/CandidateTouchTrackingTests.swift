import XCTest

@testable import CandidateKit

final class CandidateTouchTrackingTests: XCTestCase {
    private let start = CGPoint(x: 40, y: 20)

    func testImmediateDownUpSelectsExactlyOnce() {
        var touch = CandidateTouchTracking()
        touch.begin(at: start)
        XCTAssertTrue(touch.isPressed)
        XCTAssertTrue(touch.end(at: start))
        XCTAssertFalse(touch.isPressed)
        XCTAssertFalse(touch.end(at: start))
    }

    func testSmallFingerDriftStillSelects() {
        var touch = CandidateTouchTracking()
        touch.begin(at: start)
        touch.move(to: CGPoint(x: 43, y: 22))
        XCTAssertTrue(touch.end(at: CGPoint(x: 46, y: 24)))
    }

    func testHorizontalVerticalAndDiagonalDragsNeverSelect() {
        for offset in [CGPoint(x: 10, y: 0), CGPoint(x: -10, y: 0), CGPoint(x: 0, y: 10), CGPoint(x: 8, y: 8)] {
            var touch = CandidateTouchTracking()
            touch.begin(at: start)
            let end = CGPoint(x: start.x + offset.x, y: start.y + offset.y)
            touch.move(to: end)
            XCTAssertFalse(touch.isPressed)
            XCTAssertFalse(touch.end(at: end))
        }
    }

    func testReturningToStartAfterDraggingDoesNotRearmTheTap() {
        var touch = CandidateTouchTracking()
        touch.begin(at: start)
        touch.move(to: CGPoint(x: 60, y: 20))
        touch.move(to: start)
        XCTAssertFalse(touch.end(at: start))
    }

    func testFastSwipeWithOnlyAFinalSampleDoesNotSelect() {
        var touch = CandidateTouchTracking()
        touch.begin(at: start)
        XCTAssertFalse(touch.end(at: CGPoint(x: 70, y: 20)))
    }

    func testSmallEdgeCrossingAndReturnStillSelects() {
        let nearRightEdge = CGPoint(x: 78, y: 20)
        var touch = CandidateTouchTracking()
        touch.begin(at: nearRightEdge)
        touch.move(to: CGPoint(x: 82, y: 20))
        XCTAssertTrue(touch.end(at: nearRightEdge))
    }

    func testSmallDriftAcrossEveryCellEdgeStillSelectsTheOriginalTarget() {
        // Hit testing accepted these points in an 80 x 40 cell. A quick lift may
        // cross its edge without becoming a scroll or selecting the adjacent cell.
        let edgeTaps: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 40, y: 38), CGPoint(x: 40, y: 42)),
            (CGPoint(x: 40, y: 2), CGPoint(x: 40, y: -2)),
            (CGPoint(x: 2, y: 20), CGPoint(x: -2, y: 20)),
            (CGPoint(x: 78, y: 20), CGPoint(x: 82, y: 20)),
            (CGPoint(x: 78, y: 38), CGPoint(x: 82, y: 42)),
        ]
        for (down, up) in edgeTaps {
            var touch = CandidateTouchTracking()
            touch.begin(at: down)
            XCTAssertTrue(touch.end(at: up))
            XCTAssertFalse(touch.end(at: up), "an edge tap must still select exactly once")
        }
    }

    func testScrollCancellationCannotTurnIntoASelection() {
        var touch = CandidateTouchTracking()
        touch.begin(at: start)
        touch.cancel()
        touch.move(to: start)
        XCTAssertFalse(touch.end(at: start))
    }

    func testStationaryFingerStillSelectsWhenTheCellMoves() {
        var touch = CandidateTouchTracking()
        touch.begin(at: start)
        let resizedCell = CGRect(x: 0, y: 0, width: 30, height: 40)
        XCTAssertFalse(resizedCell.contains(start))
        XCTAssertTrue(touch.end(at: start), "layout movement is not finger movement")
    }

    func testNextTapWorksImmediatelyAfterCancelledDrag() {
        var touch = CandidateTouchTracking()
        touch.begin(at: start)
        touch.move(to: CGPoint(x: 60, y: 20))
        XCTAssertFalse(touch.end(at: start))
        for _ in 0..<10 {
            touch.begin(at: start)
            XCTAssertTrue(touch.end(at: start))
        }
    }

    func testADriftThatStaysOnTheWordStillSelects() {
        // An 80 x 40 cell: drifting 14 pt down or 30 pt sideways keeps the finger on the word.
        let cell = CGRect(x: 0, y: 0, width: 80, height: 40)
        for end in [CGPoint(x: 40, y: 34), CGPoint(x: 70, y: 20), CGPoint(x: 10, y: 20), CGPoint(x: 86, y: 46)] {
            var touch = CandidateTouchTracking()
            touch.begin(at: CGPoint(x: 40, y: 20), cell: cell)
            touch.move(to: end)
            XCTAssertTrue(touch.end(at: end), "\(end)")
        }
    }

    func testLeavingTheWordCancelsEvenIfTheFingerComesBack() {
        let cell = CGRect(x: 0, y: 0, width: 80, height: 40)
        var touch = CandidateTouchTracking()
        touch.begin(at: CGPoint(x: 40, y: 20), cell: cell)
        touch.move(to: CGPoint(x: 100, y: 20))
        touch.move(to: CGPoint(x: 40, y: 20))
        XCTAssertFalse(touch.end(at: CGPoint(x: 40, y: 20)))
    }
}
