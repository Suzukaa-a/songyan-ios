import XCTest

@testable import LayoutKit

/// Files from another version or platform: fields this build does not know are dropped, values it
/// knows but cannot use are still refused, and the shared names are the same on both platforms.
final class InteropFileTests: XCTestCase {
    private func withExtraFields(_ data: Data) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["futureField"] = ["a": 1]
        var rows = try XCTUnwrap(root["rows"] as? [[String: Any]])
        rows[0]["rowNote"] = "x"
        var keys = try XCTUnwrap(rows[0]["keys"] as? [[String: Any]])
        keys[0]["keyNote"] = [1, 2]
        rows[0]["keys"] = keys
        root["rows"] = rows
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testALayoutWithUnknownFieldsDecodesAndDropsThem() throws {
        let layout = BuiltinLayouts.qwerty26
        let decoded = try LayoutDefinition.decode(withExtraFields(layout.encoded()))
        XCTAssertEqual(decoded, layout)
        XCTAssertFalse(String(decoding: try decoded.encoded(), as: UTF8.self).contains("futureField"))
    }

    func testAZeroWidthIsStillRefused() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: BuiltinLayouts.qwerty26.encoded()) as? [String: Any])
        var rows = try XCTUnwrap(root["rows"] as? [[String: Any]])
        var keys = try XCTUnwrap(rows[0]["keys"] as? [[String: Any]])
        keys[0]["width"] = 0
        rows[0]["keys"] = keys
        root["rows"] = rows
        XCTAssertThrowsError(try LayoutDefinition.decode(JSONSerialization.data(withJSONObject: root)))
    }

    func testAPageWithUnknownFieldsDecodes() throws {
        let page = KeyboardPagePresets.englishQwerty
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        root["futureField"] = true
        let decoded = try JSONDecoder().decode(
            KeyboardPageDefinition.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(decoded, page)
    }

    func testTheNumericKeypadPageIsNamedAsOnAndroid() {
        XCTAssertEqual(KeyboardPagePresets.numericKeypad.name, "数字九宫格")
    }
}
