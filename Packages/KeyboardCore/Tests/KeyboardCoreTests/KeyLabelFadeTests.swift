import XCTest

@testable import KeyboardCore

@MainActor
final class KeyLabelFadeTests: XCTestCase {
    func testEnteringTheDragFiresOnceAndHidesLabels() {
        let fade = KeyLabelFade()
        XCTAssertEqual(fade.opacity, 1)
        XCTAssertTrue(fade.setDragging(true, reduceMotion: false, notify: false))
        XCTAssertFalse(fade.setDragging(true, reduceMotion: false, notify: false))
        XCTAssertEqual(fade.opacity, 0)
        XCTAssertEqual(fade.animationDuration, 0.15, accuracy: 0.0001)
    }

    func testReleaseBringsLabelsBackOnceWithTheSameDuration() {
        let fade = KeyLabelFade()
        fade.setDragging(true, reduceMotion: false, notify: false)
        XCTAssertTrue(fade.setDragging(false, reduceMotion: false, notify: false))
        XCTAssertFalse(fade.setDragging(false, reduceMotion: false, notify: false))
        XCTAssertEqual(fade.opacity, 1)
        XCTAssertEqual(fade.animationDuration, 0.15, accuracy: 0.0001)
    }

    func testReduceMotionJumps() {
        let fade = KeyLabelFade()
        fade.setDragging(true, reduceMotion: true, notify: false)
        XCTAssertEqual(fade.animationDuration, 0)
    }

    func testNotificationPostedOnChangeOnly() {
        let fade = KeyLabelFade()
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: .keyLabelFadeDidChange, object: fade, queue: nil
        ) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        fade.setDragging(true, reduceMotion: false)
        fade.setDragging(true, reduceMotion: false)
        fade.setDragging(false, reduceMotion: false)
        XCTAssertEqual(count, 2)
    }
}
