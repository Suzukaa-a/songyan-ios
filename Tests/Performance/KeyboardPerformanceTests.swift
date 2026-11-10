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
        let backspace = keyboard.keys["退格"]
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
    func testExpandedCandidatesRepeatDeleteAndStopWhenTheyClose() {
        let app = prepareKeyboard()
        let field = app.textViews["试打输入框"]
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        for letter in ["n", "i", "h", "a", "o"] { keyboard.keys[letter].tap() }
        point(app, 376, 543).tap()
        XCTAssertTrue(keyboard.buttons["收起候选"].waitForExistence(timeout: 5))
        point(app, 332, 543).press(forDuration: 1.0)
        let remaining = expectation(for: NSPredicate(format: "value == %@", "你好n"), evaluatedWith: field)
        wait(for: [remaining], timeout: 5)
        XCTAssertTrue(keyboard.keys["i"].waitForExistence(timeout: 5))
        keyboard.keys["i"].tap()
        keyboard.keys["空格"].tap()
        let continued = expectation(for: NSPredicate(format: "value == %@", "你好你"), evaluatedWith: field)
        wait(for: [continued], timeout: 5)
    }

    @MainActor
    func testHeldDeleteStopsWhenCompositionClears() {
        let app = prepareKeyboard()
        let field = app.textViews["试打输入框"]
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        for spelling in [["n"], ["n", "i"]] {
            for letter in spelling { keyboard.keys[letter].tap() }
            let composing = expectation(
                for: NSPredicate(format: "value == %@", "你好" + spelling.joined()), evaluatedWith: field)
            wait(for: [composing], timeout: 5)
            keyboard.keys["退格"].press(forDuration: 1.0)
            let retained = expectation(for: NSPredicate(format: "value == %@", "你好"), evaluatedWith: field)
            wait(for: [retained], timeout: 5)
        }
        keyboard.keys["退格"].tap()
        let shortened = expectation(for: NSPredicate(format: "value == %@", "你"), evaluatedWith: field)
        wait(for: [shortened], timeout: 5)
        keyboard.keys["退格"].press(forDuration: 1.0)
        let cleared = expectation(for: NSPredicate(format: "value == %@", ""), evaluatedWith: field)
        wait(for: [cleared], timeout: 5)
    }

    @MainActor
    func testPairedNumericKeypadKeepsSymbolPagesCycling() {
        selectNumericPage("数字九宫格")
        defer { selectNumericPage("自动 123") }
        let app = prepareKeyboard()
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        app.buttons["清空"].tap()
        point(app, 36, 768).tap()
        XCTAssertTrue(keyboard.keys["1"].waitForExistence(timeout: 5))
        point(app, 288, 768).tap()
        XCTAssertFalse(keyboard.keys["1"].exists)
        let firstPage = keyboard.keys.allElementsBoundByIndex.map(\.label)
        for turn in 0..<4 {
            point(app, 36, 710).tap()
            XCTAssertFalse(keyboard.keys["1"].exists)
            let current = keyboard.keys.allElementsBoundByIndex.map(\.label)
            if turn.isMultiple(of: 2) {
                XCTAssertNotEqual(current, firstPage)
            } else {
                XCTAssertEqual(current, firstPage)
            }
        }
        point(app, 36, 768).tap()
        XCTAssertTrue(keyboard.keys["n"].waitForExistence(timeout: 5))
        typeGreeting(keyboard)
        let committed = expectation(
            for: NSPredicate(format: "value == %@", "你好"), evaluatedWith: app.textViews["试打输入框"])
        wait(for: [committed], timeout: 5)
    }

    @MainActor
    func testNumericPageFlickAndHoldUseTheVisibleAlternate() {
        let app = prepareKeyboard()
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        let field = app.textViews["试打输入框"]
        app.buttons["清空"].tap()
        point(app, 36, 768).tap()
        let one = keyboard.keys["1"]
        XCTAssertTrue(one.waitForExistence(timeout: 5))
        let start = one.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -44)),
            withVelocity: .fast, thenHoldForDuration: 0)
        let flicked = expectation(for: NSPredicate(format: "value == %@", "一"), evaluatedWith: field)
        wait(for: [flicked], timeout: 5)
        if !one.exists { point(app, 36, 768).tap() }
        XCTAssertTrue(one.waitForExistence(timeout: 5))
        one.press(forDuration: 0.8)
        let held = expectation(for: NSPredicate(format: "value == %@", "一一"), evaluatedWith: field)
        wait(for: [held], timeout: 5)
    }

    @MainActor
    private func selectNumericPage(_ name: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-app.songyan.settings.onboardingCompleted", "YES", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let keyboards = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "我的键盘")).firstMatch
        XCTAssertTrue(keyboards.waitForExistence(timeout: 10))
        keyboards.tap()
        let pages = app.buttons["userKeyboard.pages.songyan_quanpin:qwerty26"]
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        pages.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "页面")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons[name].tap()
        app.buttons["保存搭配"].tap()
        app.terminate()
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
        // Custom keyboard keys belong to the extension process, outside the host app's tree.
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        // On a fresh simulator the first pick can close the menu but leave the system keyboard
        // up, with the extension launched and suspended; picking again shows it.
        var shown = false
        for _ in 0..<3 where !shown {
            point(app, 43, 840).press(forDuration: 1.5)
            // The picker adds the host app's name in the system language (松烟, 松煙 or Songyan).
            let pickerItem = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "松烟键盘 — ")).firstMatch
            XCTAssertTrue(
                pickerItem.waitForExistence(timeout: 5), "Enable Songyan on the dedicated simulator before testing")
            pickerItem.tap()
            shown = keyboard.keys["n"].waitForExistence(timeout: 15)
        }
        XCTAssertTrue(shown)
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
