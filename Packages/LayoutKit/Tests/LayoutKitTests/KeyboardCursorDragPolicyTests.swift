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

    func testIdleKeyboardCanBeginButBusyKeyboardCannot() {
        XCTAssertTrue(allows(isIdle: true))
        XCTAssertFalse(allows(isIdle: false))
    }

    func testNonIdleKeyboardNeverBeginsForAnyOwnershipOrDistance() {
        for owner in KeyboardCursorDragPolicy.Ownership.allCases {
            for dx in [-200.0, -14, 14, 200] {
                XCTAssertFalse(allows(isIdle: false, ownership: owner, dx: dx))
            }
        }
    }

    func testEngagedInteractionPermanentlyOwnsTheTouch() {
        var attempt = KeyboardCursorDragPolicy.Attempt()
        XCTAssertTrue(attempt.observe(isIdle: true))
        XCTAssertFalse(attempt.observe(isIdle: false))
        XCTAssertFalse(attempt.observe(isIdle: true))
        XCTAssertFalse(attempt.observe(isIdle: true))
    }

    private func allows(
        settingOn: Bool = true, isComposing: Bool = false, hasPendingCodes: Bool = false, isIdle: Bool = true,
        ownership: KeyboardCursorDragPolicy.Ownership = .keyboard, dx: Double = 20, dy: Double = 0
    ) -> Bool {
        KeyboardCursorDragPolicy.canBegin(
            settingOn: settingOn, isComposing: isComposing, hasPendingCodes: hasPendingCodes, isIdle: isIdle,
            ownership: ownership, dx: dx, dy: dy)
    }
}
