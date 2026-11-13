import XCTest

final class CandidateProbeTests: XCTestCase {
    @MainActor
    func testCandidateCommitsInsideUIKitKeyboardHost() {
        verifyKeyboardHost(passiveAncestor: false)
    }

    @MainActor
    func testNonCancellingAncestorTapDoesNotConsumeCandidateSelection() {
        verifyKeyboardHost(passiveAncestor: true)
    }

    @MainActor
    func testSuppressedRecognizerTargetStillCommitsValidatedRelease() {
        verifyKeyboardHost(passiveAncestor: true, deferredAncestor: true)
    }

    @MainActor
    private func verifyKeyboardHost(passiveAncestor: Bool, deferredAncestor: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments =
            ["--keyboard-host"] + (passiveAncestor ? ["--passive-ancestor"] : [])
            + (deferredAncestor ? ["--deferred-ancestor"] : [])
        app.launch()
        let candidate = app.buttons["word0"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        candidate.press(forDuration: 0.03)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:1")
        XCTAssertEqual(app.textFields["hostDocument"].value as? String, "word0")
        if passiveAncestor {
            XCTAssertEqual(
                app.staticTexts["observerCount"].label, deferredAncestor ? "observed:1 required" : "observed:1")
        }
        for count in 2...5 {
            app.buttons["lastCode"].tap()
            candidate.press(forDuration: 0.01)
            XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:\(count)")
            XCTAssertEqual(app.textFields["hostDocument"].value as? String, String(repeating: "word0", count: count))
        }
        let third = app.buttons["word2"]
        let beforeX = third.frame.minX
        let start = third.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -140, dy: 0)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:5")
        XCTAssertLessThan(third.frame.minX, beforeX - 30)
    }

    @MainActor
    func testExpandedVerticalScrollDoesNotSelect() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["word0"].waitForExistence(timeout: 10))
        app.buttons["expand"].tap()
        let first = app.buttons["word0"]
        XCTAssertTrue(first.isHittable)
        let start = app.buttons["word6"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -150)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertFalse(first.isHittable)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:0")
        XCTAssertEqual(app.staticTexts["flashCount"].label, "flashes:0")
    }

    @MainActor
    func testFailedSelectionNeverFlashesConfirmation() {
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["word0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        for failure in ["rejectEngine", "rejectHost"] {
            app.buttons[failure].tap()
            first.press(forDuration: 0.02)
            XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:0")
            XCTAssertEqual(app.staticTexts["flashCount"].label, "flashes:0")
        }
        app.buttons["accept"].tap()
        first.press(forDuration: 0.02)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:1")
        XCTAssertEqual(app.staticTexts["flashCount"].label, "flashes:1")
    }

    @MainActor
    func testDisappearedWordDoesNotCommitOrFlashItsReplacement() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["word0"].waitForExistence(timeout: 10))
        app.buttons["shrinkOnPress"].tap()
        app.buttons["word0"].press(forDuration: 0.15)
        XCTAssertTrue(app.buttons["word2"].exists)
        XCTAssertFalse(app.buttons["word0"].exists)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:0")
        XCTAssertEqual(app.staticTexts["flashCount"].label, "flashes:0")
    }

    @MainActor
    func testRemovingTheWholeCandidateAreaCancelsThePress() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["word0"].waitForExistence(timeout: 10))
        app.buttons["removeOnPress"].tap()
        app.buttons["word0"].press(forDuration: 0.15)
        XCTAssertFalse(app.buttons["word0"].exists)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:0")
        XCTAssertEqual(app.staticTexts["flashCount"].label, "flashes:0")
    }

    @MainActor
    func testDisablingCandidatesCancelsThePress() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["word0"].waitForExistence(timeout: 10))
        app.buttons["disableOnPress"].tap()
        app.buttons["word0"].press(forDuration: 0.15)
        XCTAssertFalse(app.buttons["word0"].isEnabled)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:0")
        XCTAssertEqual(app.staticTexts["flashCount"].label, "flashes:0")
    }

    @MainActor
    func testExpandedCandidateSurvivesRemovalOfItsOriginalCell() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["word0"].waitForExistence(timeout: 10))
        app.buttons["expand"].tap()
        app.buttons["shrinkOnPress"].tap()
        app.buttons["word2"].press(forDuration: 0.15)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:1")
        XCTAssertEqual(app.staticTexts["lastCommit"].label, "last:word2")
    }

    @MainActor
    func testRerankedCandidateSurvivesRemovalOfItsOriginalCell() {
        let app = XCUIApplication()
        app.launch()
        let third = app.buttons["word2"]
        XCTAssertTrue(third.waitForExistence(timeout: 10))
        app.buttons["shrinkOnPress"].tap()
        third.press(forDuration: 0.15)
        XCTAssertTrue(app.buttons["word2"].exists)
        XCTAssertFalse(app.buttons["word0"].exists)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:1")
        XCTAssertEqual(app.staticTexts["lastCommit"].label, "last:word2")
        XCTAssertEqual(app.staticTexts["flashCount"].label, "flashes:1")
    }
    @MainActor
    func testReplacementDuringRealSwipeDoesNotSelect() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let third = app.buttons["word2"]
        XCTAssertTrue(third.waitForExistence(timeout: 10))
        app.buttons["replaceDuringTouch"].tap()
        let beforeX = third.frame.minX
        let start = third.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -160, dy: 0)), withVelocity: .slow,
            thenHoldForDuration: 0.1)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:0")
        XCTAssertLessThan(app.buttons["new1-2"].frame.minX, beforeX - 30)
    }

    @MainActor
    func testNewCandidateImmediatelyAfterReplacementSelects() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["word0"].waitForExistence(timeout: 10))
        for count in 1...6 {
            app.buttons["replaceBeforeTouch"].tap()
            app.buttons["new\(count)-0"].press(forDuration: 0.01)
            XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:\(count)")
            XCTAssertEqual(app.staticTexts["lastCommit"].label, "last:new\(count)-0")
        }
    }

    @MainActor
    func testFinalLetterReplacesCandidateAsTouchStarts() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["word0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        app.buttons["replaceDuringTouch"].tap()
        first.press(forDuration: 0.08)
        XCTAssertTrue(app.buttons["new1-0"].exists, "final letter must replace A with B before release")
        XCTAssertEqual(app.staticTexts["lastCommit"].label, "last:new1-0")
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:1")
    }

    @MainActor
    func testFinalDecodeBetweenPressAndRelease() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["word0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        for count in 1...8 {
            app.buttons["decodeOnPress"].tap()
            first.press(forDuration: 0.08)
            XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:\(count)")
        }
    }

    @MainActor
    func testQuickSelectionDrainsTheQueuedFinalCode() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["word0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        for count in 1...8 {
            app.buttons["pendingDecode"].tap()
            first.press(forDuration: 0.01)
            XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:\(count)")
            XCTAssertEqual(app.staticTexts["lastCommit"].label, "last:word0")
            XCTAssertEqual(app.staticTexts["pendingCount"].label, "pending:0")
        }
    }

    @MainActor
    func testSmallDriftAcrossBottomEdgeStillSelects() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["word0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        for count in 1...8 {
            app.buttons["decodeOnPress"].tap()
            let nearEdge = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(
                CGVector(dx: 0, dy: -2))
            nearEdge.press(
                forDuration: 0.01, thenDragTo: nearEdge.withOffset(CGVector(dx: 0, dy: 4)), withVelocity: .fast,
                thenHoldForDuration: 0)
            XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:\(count)")
        }
    }

    @MainActor
    func testReorderingWhilePressedKeepsTheTouchedWord() {
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["word0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        app.buttons["reorderOnPress"].tap()
        first.press(forDuration: 0.08)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:1")
        XCTAssertEqual(app.staticTexts["lastCommit"].label, "last:word0")
        XCTAssertGreaterThan(app.buttons["word0"].frame.minX, app.buttons["word1"].frame.minX)
    }

    @MainActor
    func testLoadingMoreWhilePressedDoesNotCancelAStationaryFinger() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["word0"].waitForExistence(timeout: 10))
        app.buttons["fit"].tap()
        let second = app.buttons["word1"]
        let pressedX = second.frame.midX
        app.buttons["growOnPress"].tap()
        second.press(forDuration: 0.08)
        XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:1")
        XCTAssertEqual(app.staticTexts["lastCommit"].label, "last:word1")
        XCTAssertLessThan(second.frame.maxX, pressedX, "the cell moved out from under the stationary finger")
    }

    @MainActor
    func testRefreshBetweenDownAndUpCommitsTheActualWord() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["word0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        app.buttons["liveRefresh"].tap()
        for count in 1...8 {
            first.press(forDuration: 0.08)
            XCTAssertEqual(app.staticTexts["commitCount"].label, "commits:\(count)")
            XCTAssertEqual(app.staticTexts["lastCommit"].label, "last:word0")
        }
        app.buttons["liveRefresh"].tap()
    }

    @MainActor
    func testQuickTapsAndRealSwipes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let first = app.buttons["word0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        let counter = app.staticTexts["commitCount"]
        for count in 1...8 {
            app.buttons["refresh"].tap()
            first.press(forDuration: 0.01)
            XCTAssertEqual(counter.label, "commits:\(count)")
        }
        let point = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        point.press(
            forDuration: 0.01, thenDragTo: point.withOffset(CGVector(dx: 3, dy: 2)), withVelocity: .fast,
            thenHoldForDuration: 0)
        XCTAssertEqual(counter.label, "commits:9", "small drift is still a tap")
        let third = app.buttons["word2"]
        let beforeX = third.frame.minX
        let start = third.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(
            forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -160, dy: 0)), withVelocity: .slow,
            thenHoldForDuration: 0.1)
        XCTAssertEqual(counter.label, "commits:9", "a real scroll must not commit")
        XCTAssertLessThan(third.frame.minX, beforeX - 30, "the native horizontal scroll must actually move the row")
        app.buttons["refresh"].tap()
        first.tap()
        XCTAssertEqual(counter.label, "commits:10", "a tap after a drag still works")
        app.buttons["fit"].tap()
        first.press(forDuration: 0.01)
        XCTAssertEqual(counter.label, "commits:11", "a non-scrolling row still works")
    }
}
