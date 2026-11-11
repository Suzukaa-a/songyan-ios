import XCTest

@testable import KeyboardCore

final class KeyCapShiftTitleTests: XCTestCase {
    func testChinese26KeyLettersFollowShift() {
        let rows = KeyboardLayoutTable.mainRows(for: .qwerty26)
        let caps = rows.flatMap(\.caps).filter { KeyCapShiftTitle.followsShift($0.action) }
        XCTAssertGreaterThanOrEqual(caps.count, 26)
        for cap in caps {
            guard case .code(let code) = cap.action else { return XCTFail("not a code key") }
            XCTAssertEqual(KeyCapShiftTitle.title(cap.title, action: cap.action, shiftActive: true), code.uppercased())
            XCTAssertEqual(KeyCapShiftTitle.title(cap.title, action: cap.action, shiftActive: false), code)
            // Only the title is derived; the action and id stay lowercase and case free.
            XCTAssertEqual(cap.action, .code(code.lowercased()))
            XCTAssertEqual(cap.id, cap.id.lowercased())
        }
    }

    func testCustomTitleKeepsLabel() {
        XCTAssertEqual(
            KeyCapShiftTitle.title("拼", action: .code("p"), isCustom: true, shiftActive: true), "拼")
        XCTAssertEqual(
            KeyCapShiftTitle.title("p", action: .code("p"), isCustom: true, shiftActive: true), "p")
    }

    func testActionsShiftDoesNotChangeKeepTitle() {
        for action in [KeyAction.literal("a"), .code("2"), .code("'"), .code("ab"), .space, .backspace, .enter] {
            XCTAssertEqual(KeyCapShiftTitle.title("a", action: action, shiftActive: true), "a")
        }
    }
}
