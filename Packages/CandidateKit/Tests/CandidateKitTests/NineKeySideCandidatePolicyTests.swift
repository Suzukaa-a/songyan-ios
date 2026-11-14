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
        XCTAssertEqual(left.candidateWidth, 1000 - 444 - NineKeySideCandidatePolicy.swapStripWidth)
        let right = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, keypadWidth: 444, side: .right))
        XCTAssertEqual(right.keypadDock, .left)
    }

    func testTooLittleRoomOrOffLeavesTheSideBlank() {
        // One point short of the keys, the swap strip and the narrowest useful column.
        let width = 444 + NineKeySideCandidatePolicy.swapStripWidth + NineKeySideCandidatePolicy.minimumCandidateWidth
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: width - 1, keypadWidth: 444, side: .left))
        XCTAssertNotNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: width, keypadWidth: 444, side: .left))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, keypadWidth: 444, side: .off))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: .nan, keypadWidth: 444, side: .left))
    }
}
