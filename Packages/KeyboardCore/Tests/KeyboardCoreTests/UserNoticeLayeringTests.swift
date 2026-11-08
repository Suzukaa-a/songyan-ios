import XCTest

@testable import KeyboardCore

/// Pure-value view-model regression for layering and de-duplicating ordinary-flow notices.
///
/// `diagnostics` must not carry ordinary success / next-step text, because raw diagnostics are only shown
/// in developer options and ordinary users would never see success or next-step guidance. This pins "what goes into the ordinary
/// flow and what is developer-only" as a pure-value predicate, independent of SwiftUI.
final class UserNoticeLayeringTests: XCTestCase {

    func testUserLinesCarryOnlyTheNotice() {
        let lines = UserNoticeLayering.userLines(notice: "未改变当前选择；请试打后点「开始使用」。")
        XCTAssertEqual(lines, ["未改变当前选择；请试打后点「开始使用」。"])
    }

    func testEmptyNoticeYieldsNoUserLines() {
        XCTAssertEqual(UserNoticeLayering.userLines(notice: nil), [])
        XCTAssertEqual(UserNoticeLayering.userLines(notice: ""), [])
    }

    func testAllNoticeCopyAvoidsInternalTerminology() {
        let samples = [
            "已安装并验证，未应用；来源修订与各步骤回执已归档。",
            "已准备所选键盘；其他输入方式、词库与学习数据保持不变。",
            "未能检查未完成的删除，已保留原有内容。",
            "有一项未完成的删除无法自动处理，已原样保留。",
        ]
        var violations: [String] = []
        for text in samples where !text.isEmpty {
            if let term = UserTerminology.leaksInternalTerminology(text) {
                violations.append("\(term): \(text)")
            }
        }
        XCTAssertEqual(violations, [], "an ordinary notice leaks internal terminology: \(violations)")
    }
}
