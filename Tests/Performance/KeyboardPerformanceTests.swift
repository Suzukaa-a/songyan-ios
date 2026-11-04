import XCTest

#if DEBUG || !SONGYAN_PERF
    #error("Run KeyboardPerformance with Release and SONGYAN_PERF")
#endif

final class KeyboardPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testKeyboardAppearance() {
        let app = prepareKeyboard()
        let field = app.textViews["试打输入框"]
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        measure(metrics: [metric("appearance")], options: options()) {
            dismissKeyboard(app, keyboard: keyboard)
            startMeasuring()
            field.tap()
            stopMeasuring()
        }
    }

    @MainActor
    func testTypingWithTheRealEngine() {
        let app = prepareKeyboard()
        let field = app.textViews["试打输入框"]
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        measure(metrics: [metric("key"), metric("engineOp"), metric("refresh")], options: options()) {
            dismissKeyboard(app, keyboard: keyboard)
            field.tap()
            XCTAssertTrue(keyboard.keys["n"].waitForExistence(timeout: 5))
            for letter in ["n", "i", "h", "a"] {
                keyboard.keys[letter].tap()
            }
            let prefix = expectation(for: NSPredicate(format: "value ENDSWITH %@", "a"), evaluatedWith: field)
            wait(for: [prefix], timeout: 5)
            startMeasuring()
            keyboard.keys["o"].tap()
            let decoded = expectation(for: NSPredicate(format: "value ENDSWITH %@", "o"), evaluatedWith: field)
            wait(for: [decoded], timeout: 5)
            stopMeasuring()
            keyboard.keys["空格"].tap()
            let committed = expectation(for: NSPredicate(format: "value == %@", "你好"), evaluatedWith: field)
            wait(for: [committed], timeout: 5)
        }
    }

    @MainActor
    func testClearingCompositionStartsFresh() {
        let app = prepareKeyboard()
        let field = app.textViews["试打输入框"]
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        app.buttons["清空"].tap()
        keyboard.keys["n"].tap()
        keyboard.keys["i"].tap()
        app.buttons["清空"].tap()
        keyboard.keys["a"].tap()
        let fresh = expectation(for: NSPredicate(format: "value == %@", "a"), evaluatedWith: field)
        wait(for: [fresh], timeout: 5)
    }

    @MainActor
    func testExpandedCandidatesAllowCorrectionAndContinuedTyping() {
        let app = prepareKeyboard()
        let field = app.textViews["试打输入框"]
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        app.buttons["清空"].tap()
        for letter in ["n", "i", "h", "a", "o"] {
            keyboard.keys[letter].tap()
        }
        // SwiftUI controls in the extension report local accessibility frames on the simulator.
        point(app, 376, 543).tap()
        let backspace = keyboard.buttons["退格"]
        XCTAssertTrue(backspace.waitForExistence(timeout: 5))
        for _ in 0..<3 { point(app, 332, 543).tap() }
        let corrected = expectation(for: NSPredicate(format: "value == %@", "ni"), evaluatedWith: field)
        wait(for: [corrected], timeout: 5)
        XCTAssertTrue(keyboard.buttons["收起候选"].exists)
        XCTAssertTrue(keyboard.buttons["你"].exists)
        point(app, 24, 596).tap()
        let committed = expectation(for: NSPredicate(format: "value == %@", "你"), evaluatedWith: field)
        wait(for: [committed], timeout: 5)
        XCTAssertTrue(keyboard.keys["a"].waitForExistence(timeout: 5))
        keyboard.keys["a"].tap()
        point(app, 376, 543).tap()
        point(app, 332, 543).tap()
        let cleared = expectation(for: NSPredicate(format: "value == %@", "你"), evaluatedWith: field)
        wait(for: [cleared], timeout: 5)
        XCTAssertTrue(keyboard.keys["n"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func prepareKeyboard() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-app.songyan.settings.onboardingCompleted", "YES", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let tryout = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "试打")).firstMatch
        XCTAssertTrue(tryout.waitForExistence(timeout: 10))
        tryout.tap()
        let field = app.textViews["试打输入框"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
        point(app, 43, 840).press(forDuration: 1.5)
        let pickerItem = app.staticTexts["松烟键盘 — 松烟"].firstMatch
        XCTAssertTrue(
            pickerItem.waitForExistence(timeout: 5), "Enable Songyan on the dedicated simulator before testing")
        pickerItem.tap()
        // Custom keyboard keys belong to the extension process, outside the host app's tree.
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        XCTAssertTrue(keyboard.keys["n"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.frame.width, 402)
        XCTAssertEqual(app.frame.height, 874)
        typeGreeting(keyboard)
        let committed = expectation(for: NSPredicate(format: "value == %@", "你好"), evaluatedWith: field)
        wait(for: [committed], timeout: 10)
        return app
    }

    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication, keyboard: XCUIApplication) {
        app.buttons["perf.resetTryout"].tap()
        // A new focus request can overlap the previous keyboard disappearance.
        XCTAssertTrue(keyboard.keys["n"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func typeGreeting(_ keyboard: XCUIApplication) {
        for key in ["n", "i", "h", "a", "o", "空格"] {
            keyboard.keys[key].tap()
        }
    }

    @MainActor
    private func point(_ app: XCUIApplication, _ x: Double, _ y: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func metric(_ name: String) -> XCTOSSignpostMetric {
        XCTOSSignpostMetric(subsystem: "app.songyan.ime", category: "KeyboardPerformance", name: name)
    }

    private func options() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }
}
