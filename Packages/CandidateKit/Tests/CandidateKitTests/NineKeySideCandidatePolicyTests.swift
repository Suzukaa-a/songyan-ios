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
        // 556 pt beside the keys: 40 % of it is the gap, the rest the column.
        XCTAssertEqual(left.stripWidth, 222.4, accuracy: 1e-9)
        XCTAssertEqual(left.candidateWidth, 556 - 222.4, accuracy: 1e-9)
        let right = try XCTUnwrap(
            NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, keypadWidth: 444, side: .right))
        XCTAssertEqual(right.keypadDock, .left)
    }

    func testTheGapTakesItsShareButLeavesTheColumnAndTheButtonTheirMinimum() {
        XCTAssertEqual(NineKeySideCandidatePolicy.stripWidth(room: 600, gapPercent: 50), 300, accuracy: 1e-9)
        // 346 pt (an iPhone in landscape): 40 % is 138.4 and the column keeps 207.6.
        XCTAssertEqual(NineKeySideCandidatePolicy.stripWidth(room: 346), 138.4, accuracy: 1e-9)
        // Too little room for the share: the column keeps 200 pt.
        XCTAssertEqual(NineKeySideCandidatePolicy.stripWidth(room: 300, gapPercent: 60), 100, accuracy: 1e-9)
        XCTAssertEqual(NineKeySideCandidatePolicy.stripWidth(room: 220, gapPercent: 10), 40)
        XCTAssertEqual(NineKeySideCandidatePolicy.clampedGapPercent(3), 10)
        XCTAssertEqual(NineKeySideCandidatePolicy.clampedGapPercent(99), 60)
        XCTAssertEqual(NineKeySideCandidatePolicy.clampedGapPercent(43), 40)
    }

    func testTooLittleRoomOrOffLeavesTheSideBlank() {
        // 444 keys + the 40 pt button + a 200 pt column need 684 pt.
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 683, keypadWidth: 444, side: .left))
        XCTAssertNotNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 684, keypadWidth: 444, side: .left))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: 1000, keypadWidth: 444, side: .off))
        XCTAssertNil(NineKeySideCandidatePolicy.plan(keyAreaWidth: .nan, keypadWidth: 444, side: .left))
    }
}
