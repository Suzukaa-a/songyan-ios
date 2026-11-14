import LayoutKit
import XCTest

final class KeyboardSplitModeTests: XCTestCase {
    func testTheModeOverridesALayoutsOwnSplit() {
        let off = LayoutSplitConfiguration(activation: .off, rowBreaks: [4])
        XCTAssertNil(KeyboardSplitMode.off.applied(to: LayoutSplitConfiguration()))
        XCTAssertEqual(KeyboardSplitMode.layout.applied(to: off), off)
        XCTAssertNil(KeyboardSplitMode.layout.applied(to: nil))
        // On: a layout without a split gets the automatic one; one switched off keeps its cuts.
        XCTAssertEqual(KeyboardSplitMode.on.applied(to: nil), LayoutSplitConfiguration())
        XCTAssertEqual(KeyboardSplitMode.on.applied(to: off)?.activation, .automatic)
        XCTAssertEqual(KeyboardSplitMode.on.applied(to: off)?.rowBreaks, [4])
        XCTAssertEqual(KeyboardSplitMode.resolve("bogus"), .layout)
    }
}
