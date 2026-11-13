import XCTest

/// Run only against a staged app on a disposable simulator; see the runner's prerequisites.
final class CandidateProbeTests: XCTestCase {
    @MainActor
    func testProductionKeyboardCommitsCandidateIntoDocument() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "app.songyan.ime")
        app.launch()
        let tryout = app.buttons["试打、体验键盘输入与候选上屏"]
        XCTAssertTrue(tryout.waitForExistence(timeout: 20))
        tryout.tap()
        let field = app.textViews["试打输入框"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
        if !app.keys["切换到英文"].exists, app.buttons["下一个键盘"].exists {
            app.buttons["下一个键盘"].tap()
        }
        XCTAssertTrue(app.keys["切换到英文"].waitForExistence(timeout: 15))
        for count in 1...3 {
            for key in ["n", "i", "h", "a", "o"] { app.keys[key].tap() }
            let candidate = app.buttons.matching(NSPredicate(format: "label == %@", "你好")).firstMatch
            XCTAssertTrue(candidate.waitForExistence(timeout: 10))
            // Remote SwiftUI candidates report keyboard-window-local AX y on
            // this runtime. Native key frames are in screen coordinates, so use
            // the top key row to anchor the physical band immediately above it.
            let point = CGPoint(
                x: candidate.frame.midX,
                y: app.keys["q"].frame.minY - candidate.frame.height / 2 - 4)
            XCTAssertGreaterThan(point.y, 0)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
                .press(forDuration: 0.03)
            XCTAssertEqual(field.value as? String, String(repeating: "你好", count: count))
        }
    }
}
