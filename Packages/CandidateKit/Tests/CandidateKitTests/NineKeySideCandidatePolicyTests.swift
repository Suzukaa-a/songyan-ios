import CandidateKit
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
            NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, keypadWidth: 444, side: .left))
        XCTAssertEqual(left.keypadDock, .right)
        XCTAssertEqual(left.stripWidth, 60, accuracy: 1e-9)
        XCTAssertEqual(left.candidateWidth, 1000 - 444 - 60, accuracy: 1e-9)
        let right = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, keypadWidth: 444, side: .right))
        XCTAssertEqual(right.keypadDock, .left)
    }

    func testTheStripGrowsWithTheWidthButNeverBelowTheButton() {
        XCTAssertEqual(NineKeySideCandidatePolicy.stripWidth(keyAreaWidth: 600), 40)
        XCTAssertEqual(NineKeySideCandidatePolicy.stripWidth(keyAreaWidth: 1200), 72, accuracy: 1e-9)
    }

    func testTooLittleRoomOrOffLeavesTheSideBlank() {
        // 444 keys + a 6 % strip + a 200 pt column need about 685.1 pt.
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 685, keypadWidth: 444, side: .left))
        XCTAssertNotNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 686, keypadWidth: 444, side: .left))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, keypadWidth: 444, side: .off))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: .nan, keypadWidth: 444, side: .left))
    }
}
