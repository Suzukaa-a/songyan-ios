import XCTest

@testable import LayoutKit

final class KeyboardDeleteSwipePolicyTests: XCTestCase {
    private let startX = 300.0
    private let step = KeyboardCursorDragPolicy.stepWidth
    private let begun = KeyboardDeleteSwipePolicy.begin(startX: 300)

    private func move(_ state: KeyboardDeleteSwipePolicy.State, to x: Double, reach: Int = .max)
        -> KeyboardDeleteSwipePolicy.State
    {
        KeyboardDeleteSwipePolicy.move(state, x: x, startX: startX, reach: reach)
    }

    func testStepIsTheSpaceBarStep() {
        XCTAssertEqual(KeyboardCursorDragPolicy.stepWidth, 12)
        XCTAssertEqual(KeyboardCursorDragPolicy.startDistance, 14)
    }

    func testStartsOnlyLeftwardsPastTheThresholdAndMostlyHorizontal() {
        XCTAssertFalse(KeyboardDeleteSwipePolicy.canBegin(dx: -13.9, dy: 0))
        XCTAssertTrue(KeyboardDeleteSwipePolicy.canBegin(dx: -14, dy: 0))
        XCTAssertTrue(KeyboardDeleteSwipePolicy.canBegin(dx: -30, dy: 29))
        XCTAssertFalse(KeyboardDeleteSwipePolicy.canBegin(dx: -30, dy: 31), "more vertical than horizontal")
        XCTAssertFalse(KeyboardDeleteSwipePolicy.canBegin(dx: 30, dy: 0), "rightwards never starts")
    }

    func testSettingCompositionPendingCodesAndVoiceOverGateTheSwipe() {
        func available(
            on: Bool = true, composing: Bool = false, pending: Bool = false, voiceOver: Bool = false
        ) -> Bool {
            KeyboardDeleteSwipePolicy.isAvailable(
                settingOn: on, isComposing: composing, hasPendingCodes: pending, voiceOverRunning: voiceOver)
        }
        XCTAssertTrue(available())
        XCTAssertFalse(available(on: false))
        XCTAssertFalse(available(composing: true))
        XCTAssertFalse(available(pending: true))
        XCTAssertFalse(available(voiceOver: true))
    }

    func testOneCharacterPerStep() {
        XCTAssertEqual(move(begun, to: startX - 14.5).count, 1, "past 14 pt is already one 12 pt step")
        XCTAssertEqual(move(begun, to: startX - 14.5).anchorX, startX - step)
        XCTAssertEqual(move(begun, to: startX - 14).count, 0, "exactly at the threshold is still the dead zone")
        XCTAssertEqual(move(begun, to: startX - 3 * step - 1).count, 3)
        XCTAssertEqual(move(begun, to: startX - 13.9).count, 0, "inside the dead zone")
    }

    func testSlidingBackShrinksOneCharacterPerStep() {
        let three = move(begun, to: startX - 3 * step - 1)
        XCTAssertEqual(three.count, 3)
        // Each step back is measured from where the last step ended.
        XCTAssertEqual(move(three, to: three.anchorX + step - 1).count, 3)
        let two = move(three, to: three.anchorX + step)
        XCTAssertEqual(two.count, 2)
        let five = move(begun, to: startX - 5 * step - 1)
        XCTAssertEqual(move(five, to: five.anchorX + 2 * step).count, 3)
    }

    func testBackAtTheStartIsZeroAndRestartsTheCount() {
        let deep = move(begun, to: startX - 5 * step)
        XCTAssertEqual(deep.count, 5)
        let back = move(deep, to: startX - 13)
        XCTAssertEqual(back, begun)
        XCTAssertEqual(move(deep, to: startX + 80), begun, "right of the touch-down point marks nothing")
    }

    func testCountClampsToTheReachableCharacters() {
        let clamped = move(begun, to: startX - 40 * step, reach: 4)
        XCTAssertEqual(clamped.count, 4)
        XCTAssertEqual(move(begun, to: startX - 40 * step, reach: 0).count, 0)
    }

    func testReversingAtTheClampReactsOnTheNextStep() {
        let clamped = move(begun, to: startX - 40 * step - 1, reach: 2)
        // The anchor kept following the finger: one step back shrinks at once.
        let back = move(clamped, to: startX - 39 * step, reach: 2)
        XCTAssertEqual(back.count, 1)
    }

    func testMarkedTextNeverSplitsAnEmojiOrCombiningSequence() {
        let family = "👨‍👩‍👧"
        let text = "a\(family)e\u{301}🇯🇵b"
        XCTAssertEqual(KeyboardDeleteSwipePolicy.marked(in: text, count: 1), "b")
        XCTAssertEqual(KeyboardDeleteSwipePolicy.marked(in: text, count: 2), "🇯🇵b")
        XCTAssertEqual(KeyboardDeleteSwipePolicy.marked(in: text, count: 3), "e\u{301}🇯🇵b")
        XCTAssertEqual(KeyboardDeleteSwipePolicy.marked(in: text, count: 4), "\(family)e\u{301}🇯🇵b")
        XCTAssertEqual(KeyboardDeleteSwipePolicy.marked(in: text, count: 5), text)
        XCTAssertEqual(KeyboardDeleteSwipePolicy.marked(in: text, count: 99), text)
        XCTAssertEqual(KeyboardDeleteSwipePolicy.marked(in: text, count: 0), "")
    }

    func testReachIsBoundedOncePerSwipe() {
        let long = String(repeating: "字", count: KeyboardDeleteSwipePolicy.reachLimit + 40)
        XCTAssertEqual(KeyboardDeleteSwipePolicy.reachable(long).count, KeyboardDeleteSwipePolicy.reachLimit)
        XCTAssertEqual(KeyboardDeleteSwipePolicy.reachable("短"), "短")
    }
}
