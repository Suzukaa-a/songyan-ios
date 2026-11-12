import XCTest

@testable import LayoutKit

final class KeyboardCursorDragPolicyTests: XCTestCase {
    func testHorizontalThresholdAndDirection() {
        for dx in [-14.0, 14, -50, 50] {
            XCTAssertTrue(allows(dx: dx, dy: 13))
        }
        XCTAssertFalse(allows(dx: 13.99, dy: 0))
        XCTAssertFalse(allows(dx: 14, dy: -14))
        XCTAssertFalse(allows(dx: 14, dy: 15))
    }

    func testSettingCompositionAndPendingCodesGateTakeover() {
        XCTAssertFalse(allows(settingOn: false))
        XCTAssertFalse(allows(isComposing: true))
        XCTAssertFalse(allows(hasPendingCodes: true))
        XCTAssertTrue(allows())
    }

    func testSidewaysOwnersNeverYieldEvenForLongHorizontalDrags() {
        for owner in KeyboardCursorDragPolicy.Ownership.allCases where owner != .keyboard {
            XCTAssertFalse(allows(ownership: owner, dx: 200, dy: 0), "\(owner)")
        }
    }

    func testMergedLetterSwipeStillSelectsAtItsOwnThreshold() {
        var letter = LetterSwipeTracker(letterCount: 2)
        XCTAssertFalse(allows(ownership: .sidewaysKey, dx: 14, dy: 0))
        XCTAssertFalse(allows(ownership: .sidewaysKey, dx: LetterSwipeTracker.lockDistance, dy: 0))
        XCTAssertTrue(letter.update(dx: LetterSwipeTracker.lockDistance, dy: 0))
        XCTAssertEqual(letter.choice, 1)
    }

    private func allows(
        settingOn: Bool = true, isComposing: Bool = false, hasPendingCodes: Bool = false,
        ownership: KeyboardCursorDragPolicy.Ownership = .keyboard, dx: Double = 20, dy: Double = 0
    ) -> Bool {
        KeyboardCursorDragPolicy.canBegin(
            settingOn: settingOn, isComposing: isComposing, hasPendingCodes: hasPendingCodes,
            ownership: ownership, dx: dx, dy: dy)
    }
}
