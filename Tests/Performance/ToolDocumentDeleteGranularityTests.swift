import UIKit
import XCTest

/// Real UIKit behavior for the one operation the tool gateway uses to replace a
/// caret-preceding tail: the proxy removes those characters with
/// deleteBackward. This answers only one question - how much text one call
/// removes for composed characters - so the gateway does not rely on an
/// assumption borrowed from a test double.
final class ToolDocumentDeleteGranularityTests: XCTestCase {
    private func field(with text: String) -> UITextField {
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 240, height: 40))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 40))
        window.addSubview(field)
        window.makeKeyAndVisible()
        field.becomeFirstResponder()
        field.text = text
        return field
    }

    func testDeleteBackwardRemovesOneEmoji() {
        let field = field(with: "a\u{1F600}")
        field.deleteBackward()
        XCTAssertEqual(field.text, "a", "one deleteBackward removes the whole emoji")
    }

    func testDeleteBackwardRemovesOneCombiningCharacter() {
        let field = field(with: "ae\u{301}")
        field.deleteBackward()
        XCTAssertEqual(field.text, "a", "one deleteBackward removes the combining sequence")
    }

    func testDeleteBackwardRemovesOneZwjSequence() {
        let field = field(with: "a\u{1F469}\u{200D}\u{1F466}")
        field.deleteBackward()
        XCTAssertEqual(field.text, "a", "one deleteBackward removes the whole ZWJ emoji")
    }
}
