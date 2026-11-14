import LayoutKit
import XCTest

final class KeyboardSplitModeTests: XCTestCase {
    func testTheModeOverridesALayoutsOwnSplit() {
        let off = LayoutSplitConfiguration(activation: .off, rowBreaks: [4])
        XCTAssertNil(KeyboardSplitMode.off.applied(to: LayoutSplitConfiguration()))
        XCTAssertEqual(KeyboardSplitMode.layout.applied(to: off), off)
        XCTAssertNil(KeyboardSplitMode.layout.applied(to: nil))
        // On: a layout without a split gets the automatic one; one its author set not to split keeps
        // that, and the 9-key shell is never split by this setting.
        XCTAssertEqual(KeyboardSplitMode.on.applied(to: nil), LayoutSplitConfiguration())
        XCTAssertEqual(KeyboardSplitMode.on.applied(to: off), off)
        XCTAssertNil(KeyboardSplitMode.on.applied(to: nil, isPhoneKeypad: true))
        XCTAssertEqual(KeyboardSplitMode.resolve("bogus"), .layout)
    }
}
