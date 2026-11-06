import XCTest

@testable import KeyboardCore

final class ConfirmedCompositionTests: XCTestCase {
    private func snapshot(_ preedit: String, _ start: Int, _ end: Int, caret: Int? = nil) -> EngineSnapshot {
        var result = EngineSnapshot(preedit: preedit, rawInput: "su3cl3", isComposing: true)
        result.preeditSelStart = start
        result.preeditSelEnd = end
        result.preeditCaretByte = caret ?? preedit.utf8.count
        return result
    }

    func testWholeSelectionUsesNativeUTF8Offsets() {
        XCTAssertTrue(snapshot("你好", 6, 6).isFullyConfirmedComposition)
        XCTAssertTrue(snapshot("這", 3, 3).isFullyConfirmedComposition)
    }

    func testGuessedCompositionIsNotConfirmed() {
        XCTAssertFalse(snapshot("ㄋㄧˇ ㄏㄠˇ", 0, 17).isFullyConfirmedComposition)
    }

    func testPartialSelectionKeepsUnconfirmedTail() {
        XCTAssertFalse(snapshot("你ㄏㄠˇ", 3, 11).isFullyConfirmedComposition)
    }

    func testFirstToneSpaceDoesNotConfirm() {
        XCTAssertFalse(snapshot("ㄓㄜˉ", 0, 8).isFullyConfirmedComposition)
    }

    func testEmptyMenuAndCollapsedRangeAloneCannotConfirm() {
        XCTAssertFalse(snapshot("ㄓㄜˉ", 0, 0).isFullyConfirmedComposition)
        XCTAssertFalse(snapshot("你好", 2, 2).isFullyConfirmedComposition)
    }

    func testIdleOrEmptyInputCannotConfirm() {
        var idle = snapshot("你好", 6, 6)
        idle.isComposing = false
        XCTAssertFalse(idle.isFullyConfirmedComposition)
        idle.isComposing = true
        idle.rawInput = ""
        XCTAssertFalse(idle.isFullyConfirmedComposition)
        XCTAssertFalse(snapshot("", 0, 0).isFullyConfirmedComposition)
    }

    func testCursorInsideAndInsertedSoftCursorFailClosed() {
        XCTAssertFalse(snapshot("你好", 6, 6, caret: 3).isFullyConfirmedComposition)
        XCTAssertFalse(snapshot("你‸好", 6, 6).isFullyConfirmedComposition)
    }
}
