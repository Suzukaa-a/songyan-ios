import CoreGraphics
import XCTest

@testable import CandidateKit

final class KeyCalloutGeometryTests: XCTestCase {
    private let safe = CGRect(x: 4, y: 4, width: 382, height: 300)

    func testALowerRowBubbleIsLiftedClearOfTheFinger() {
        let key = CGRect(x: 100, y: 150, width: 36, height: 42)
        let bubble = KeyCalloutGeometry.bubbleFrame(key: key, safe: safe)
        let lift = (key.height * KeyCalloutGeometry.maximumLift).rounded()
        XCTAssertEqual(bubble.maxY, key.minY - lift)
        XCTAssertEqual(bubble.height, 52)
        XCTAssertEqual(bubble.midX, key.midX)
    }

    func testATopRowBubbleGivesUpTheLiftBeforeItsHeight() {
        // 60 pt above the key: the full 52 pt bubble fits, with 8 pt of lift.
        let key = CGRect(x: 100, y: 64, width: 36, height: 42)
        let bubble = KeyCalloutGeometry.bubbleFrame(key: key, safe: safe)
        XCTAssertEqual(bubble.height, 52)
        XCTAssertEqual(bubble.maxY, key.minY - 8)
        XCTAssertEqual(bubble.minY, safe.minY)
    }

    func testABubbleWithNoRoomOverlapsTheKeyInsteadOfLeavingTheKeyboard() {
        let key = CGRect(x: 100, y: 20, width: 36, height: 42)
        let bubble = KeyCalloutGeometry.bubbleFrame(key: key, safe: safe)
        XCTAssertEqual(bubble.minY, safe.minY)
        XCTAssertEqual(bubble.height, 52)
        XCTAssertGreaterThan(bubble.maxY, key.minY)
    }

    func testAnEdgeKeyBubbleStaysInsideTheKeyboard() {
        let key = CGRect(x: 4, y: 150, width: 36, height: 42)
        let bubble = KeyCalloutGeometry.bubbleFrame(key: key, safe: safe)
        XCTAssertEqual(bubble.minX, safe.minX)
    }
}
