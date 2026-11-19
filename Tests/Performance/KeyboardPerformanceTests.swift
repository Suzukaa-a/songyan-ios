import XCTest

#if DEBUG || !SONGYAN_PERF
    #error("Run KeyboardPerformance with Release and SONGYAN_PERF")
#endif

final class KeyboardPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnboardingRecommendationsStartCollapsedAndExpand() {
        let app = openOnboardingSchemes()
        XCTAssertTrue(app.buttons["schemes.download.rime-ice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["雾凇拼音"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "schemes.featured.rime-ice").firstMatch.exists)
        XCTAssertFalse(downloadButton(app, "万象拼音").exists)
        XCTAssertFalse(downloadButton(app, "注音（台湾）").exists)
        let more = app.buttons["schemes.more"]
        XCTAssertTrue(more.exists)
        more.tap()
        XCTAssertTrue(downloadButton(app, "万象拼音").waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertTrue(downloadButton(app, "注音（台湾）").exists)
    }

    @MainActor
    func testOnboardingRecommendationDownloadCanBeCancelledInPlace() {
        let app = openOnboardingSchemes()
        let download = app.buttons["schemes.download.rime-ice"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        let confirm = app.buttons["schemes.confirmDownload"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.links["查看项目主页"].exists)
        XCTAssertFalse(progressButton(app, "rime-ice").exists)
        confirm.tap()
        let cancel = progressButton(app, "rime-ice")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.progressIndicators.firstMatch.exists)
        XCTAssertFalse(download.exists)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        XCTAssertTrue(download.isEnabled)
        XCTAssertFalse(downloadButton(app, "万象拼音").exists)
    }

    /// Rows inside the collapsible group and the progress block report their container's
    /// identifier instead of their own, so these are found by accessibility label and container id.
    @MainActor
    private func downloadButton(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "下载" + name)).firstMatch
    }

    @MainActor
    private func progressButton(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons.matching(identifier: "schemes.progress." + id).firstMatch
    }

    @MainActor
    private func openOnboardingSchemes() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-app.songyan.settings.onboardingCompleted", "YES", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        app.buttons["键盘与完全访问"].tap()
        // A tap during the push animation can be dropped; repeat until the guide shows step 2.
        let progress = app.otherElements["引导进度"]
        for _ in 0..<3 where !(progress.value as? String ?? "").hasPrefix("第 2 步") {
            if app.buttons["下一步"].waitForExistence(timeout: 5) { app.buttons["下一步"].tap() }
            _ = progress.waitForExistence(timeout: 2)
            Thread.sleep(forTimeInterval: 1)
        }
        app.swipeUp()
        return app
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
        measure(
            metrics: [metric("key"), metric("keyToHost"), metric("engineOp"), metric("refresh")], options: options()
        ) {
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

    /// Held Delete through a composition: every repeat is one engine delete.
    @MainActor
    func testHeldDeleteThroughAComposition() {
        let app = prepareKeyboard()
        let field = app.textViews["试打输入框"]
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        measure(metrics: [metric("key"), metric("keyToHost"), metric("engineOp")], options: options()) {
            app.buttons["清空"].tap()
            for letter in ["z", "h", "o", "n", "g", "g", "u", "o", "r", "e", "n"] {
                keyboard.keys[letter].tap()
            }
            let typed = expectation(for: NSPredicate(format: "value ENDSWITH %@", "n"), evaluatedWith: field)
            wait(for: [typed], timeout: 5)
            startMeasuring()
            keyboard.keys["退格"].press(forDuration: 2.0)
            let cleared = expectation(for: NSPredicate(format: "value == %@", ""), evaluatedWith: field)
            wait(for: [cleared], timeout: 5)
            stopMeasuring()
        }
    }

    /// 9-key composition: the key, its decode and, without a schema display value, the
    /// engine-proven reading that the field waits for.
    @MainActor
    func testNineKeyTypingWithTheRealEngine() {
        useNineKeyKeyboard(true)
        defer { useNineKeyKeyboard(false) }
        let app = prepareKeyboard(nineKey: true)
        let field = app.textViews["试打输入框"]
        let keyboard = XCUIApplication(bundleIdentifier: "app.songyan.ime.keyboard")
        measure(metrics: [metric("key"), metric("keyToHost"), metric("engineOp")], options: options()) {
            app.buttons["清空"].tap()
            for group in ["MNO", "GHI", "GHI", "ABC"] { nineKey(keyboard, group).tap() }
            let typed = expectation(for: NSPredicate(format: "value.length >= 4"), evaluatedWith: field)
            wait(for: [typed], timeout: 5)
            // The highlighted reading lands after the decode; let it settle first.
            Thread.sleep(forTimeInterval: 0.3)
            let before = field.value as? String ?? ""
            startMeasuring()
            nineKey(keyboard, "MNO").tap()
            let decoded = expectation(for: NSPredicate(format: "value != %@", before), evaluatedWith: field)
            wait(for: [decoded], timeout: 5)
            Thread.sleep(forTimeInterval: 0.3)
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
        // The expanded panel keeps the candidate strip as its first row and moves delete into the
        // right-hand key column.
        let backspace = keyboard.keys["删除"]
        XCTAssertTrue(backspace.waitForExistence(timeout: 5))
        for _ in 0..<3 { backspace.tap() }
        let corrected = expectation(for: NSPredicate(format: "value == %@", "ni"), evaluatedWith: field)
        wait(for: [corrected], timeout: 5)
        XCTAssertTrue(keyboard.buttons["收起候选"].exists)
        let first = keyboard.buttons["你"]
        XCTAssertTrue(first.exists)
        point(app, first.frame.midX, 543).tap()
        let committed = expectation(for: NSPredicate(format: "value == %@", "你"), evaluatedWith: field)
        wait(for: [committed], timeout: 5)
        XCTAssertTrue(keyboard.keys["a"].waitForExistence(timeout: 5))
        keyboard.keys["a"].tap()
        point(app, 376, 543).tap()
        keyboard.keys["删除"].tap()
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
        keyboard.keys["删除"].press(forDuration: 1.0)
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
        let pages = app.buttons["userKeyboard.pages.songyan_quanpin:qwerty26#qwerty26"]
        XCTAssertTrue(pages.waitForExistence(timeout: 5))
        pages.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "页面")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons[name].tap()
        app.buttons["保存搭配"].tap()
        app.terminate()
    }

    /// Adds and uses the built-in 9-key keyboard, or uses 26-key again and removes it, so the
    /// other tests keep their single-keyboard control row.
    @MainActor
    private func useNineKeyKeyboard(_ on: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-app.songyan.settings.onboardingCompleted", "YES", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let keyboards = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "我的键盘")).firstMatch
        XCTAssertTrue(keyboards.waitForExistence(timeout: 10))
        keyboards.tap()
        let nine = "songyan_quanpin:phone9#phone9"
        let added = app.buttons["userKeyboard.pages." + nine]
        XCTAssertTrue(app.buttons["userKeyboard.save"].waitForExistence(timeout: 5))
        if on {
            if !added.exists {
                app.buttons["userKeyboard.card." + nine].tap()
                app.buttons["userKeyboard.save"].tap()
                XCTAssertTrue(added.waitForExistence(timeout: 5))
            }
            let use = app.buttons["userKeyboard.use." + nine]
            if use.waitForExistence(timeout: 2) { use.tap() }
            let qwerty = app.buttons["userKeyboard.use.songyan_quanpin:qwerty26#qwerty26"]
            XCTAssertTrue(qwerty.waitForExistence(timeout: 5))
        } else if added.exists {
            let use = app.buttons["userKeyboard.use.songyan_quanpin:qwerty26#qwerty26"]
            if use.waitForExistence(timeout: 2) { use.tap() }
            XCTAssertTrue(app.buttons["userKeyboard.use." + nine].waitForExistence(timeout: 5))
            // The cards below the added keyboards are lazy rows; scroll until the card exists.
            let card = app.buttons["userKeyboard.card." + nine]
            for _ in 0..<6 where !card.exists || !card.isHittable { app.swipeUp() }
            card.tap()
            app.buttons["userKeyboard.save"].tap()
            XCTAssertTrue(added.waitForNonExistence(timeout: 5))
        }
        app.terminate()
    }

    @MainActor
    private func nineKey(_ keyboard: XCUIApplication, _ letters: String) -> XCUIElement {
        keyboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", letters)).firstMatch
    }

    @MainActor
    private func prepareKeyboard(nineKey: Bool = false) -> XCUIApplication {
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
            shown =
                nineKey
                ? self.nineKey(keyboard, "MNO").waitForExistence(timeout: 15)
                : keyboard.keys["n"].waitForExistence(timeout: 15)
        }
        XCTAssertTrue(shown)
        XCTAssertEqual(app.frame.width, 402)
        XCTAssertEqual(app.frame.height, 874)
        if nineKey {
            for group in ["MNO", "GHI", "GHI", "ABC", "MNO"] { self.nineKey(keyboard, group).tap() }
            keyboard.keys["空格"].tap()
        } else {
            typeGreeting(keyboard)
        }
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
