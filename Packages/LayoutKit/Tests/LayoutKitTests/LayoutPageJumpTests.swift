import XCTest

@testable import LayoutKit

/// A key that opens a non-letter page of another keyboard layout: its wire form and validation.
/// The wire form is shared with the Android version, so layout files move between the two.
final class LayoutPageJumpTests: XCTestCase {
    private let toNineKeyDigits = LayoutAction.PageJump(layout: .phone9, page: .numeric)!

    func testTargetIsWrittenAsLayoutColonPageUnderItsOwnKind() throws {
        let action = LayoutAction.layoutPageSwitch(toNineKeyDigits)
        let data = try JSONEncoder.layoutKitPretty().encode(action)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "layoutPageSwitch")
        XCTAssertEqual(object["value"] as? String, "phone9:numeric")
        XCTAssertEqual(Set(object.keys), ["type", "value"])
        XCTAssertEqual(try JSONDecoder().decode(LayoutAction.self, from: data), action)
        XCTAssertEqual(action.layoutPageJump, toNineKeyDigits)
        XCTAssertNil(action.pageSwitchTarget)
    }

    func testEveryLayoutsDigitAndSymbolPagesAreTargetsAndNoLetterPageIs() throws {
        XCTAssertEqual(LayoutAction.PageJump.all.count, LayoutInput.Builtin.allCases.count * 2)
        for target in LayoutAction.PageJump.all {
            XCTAssertEqual(LayoutAction.PageJump(wire: target.wire), target)
            try LayoutAction.layoutPageSwitch(target).validate()
        }
        XCTAssertTrue(LayoutAction.PageJump.all.allSatisfy { $0.page != .letters })
        XCTAssertNil(LayoutAction.PageJump(layout: .phone9, page: .letters))
        XCTAssertEqual(
            LayoutAction.PageJump.all.map(\.wire),
            [
                "qwerty26:numeric", "qwerty26:symbols", "merged14:numeric", "merged14:symbols",
                "merged18:numeric", "merged18:symbols", "phone9:numeric", "phone9:symbols",
            ])
    }

    func testUnknownOrMalformedTargetIsRejected() {
        let bad: [String?] = [
            nil, "", "numeric", "phone9", "phone9:letters", "phone10:numeric", "phone9:emoji",
            "phone9:numeric:extra", "PHONE9:numeric", " phone9:numeric", "phone9:Numeric", ":", "phone9:",
        ]
        for value in bad {
            XCTAssertNil(LayoutAction.PageJump(wire: value), "\(String(describing: value))")
            XCTAssertThrowsError(try LayoutAction(.layoutPageSwitch, value: value).validate()) { error in
                XCTAssertEqual(
                    error as? LayoutError,
                    .invalid("跳转键只能选择 26 键、14 键、18 键或 9 键的数字页或符号页，请重新选择。"))
            }
        }
    }

    func testPageSwitchNeverAcceptsAQualifiedValue() {
        // An older reader of `pageSwitch` must not be handed a value it would misread.
        XCTAssertThrowsError(try LayoutAction(.pageSwitch, value: "phone9:numeric").validate())
        XCTAssertNil(LayoutAction.pageSwitch(.numeric).layoutPageJump)
    }

    func testUnknownKindIsRefused() {
        let json = Data(#"{"type":"layoutPageSwitchFromTheFuture","value":"phone9:numeric"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutAction.self, from: json))
    }

    func testPageWithJumpKeysInRowsAndRailsRoundTripsAndFailsOnAnUnknownTarget() throws {
        let jump = LayoutKey(label: "123", action: .layoutPageSwitch(toNineKeyDigits))
        let symbolsJump = LayoutKey(
            label: "符号", action: .layoutPageSwitch(.init(layout: .merged14, page: .symbols)!))
        var page = KeyboardPagePresets.symbolsChinese.copy(name: "我的符号")
        var chrome = try XCTUnwrap(page.chrome)
        chrome.leading = [symbolsJump]
        page.chrome = chrome
        page.rows = page.rows.dropLast() + [LayoutRow(keys: (page.rows.last?.keys ?? []) + [jump])]
        try page.validate()
        let data = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardPageDefinition.self, from: data), page)

        let bad = LayoutKey(label: "123", action: LayoutAction(.layoutPageSwitch, value: "phone9:letters"))
        page.rows = page.rows + [LayoutRow(keys: [bad])]
        XCTAssertThrowsError(try page.validate())
    }

    func testJumpIsDrawnOnlyForLayoutsTheRunningInputMethodCanUse() {
        let jump = LayoutAction.layoutPageSwitch(toNineKeyDigits)
        XCTAssertTrue(jump.isUsableJump(among: [.phone9, .qwerty26]))
        XCTAssertFalse(jump.isUsableJump(among: [.qwerty26]))
        XCTAssertFalse(LayoutAction(.layoutPageSwitch, value: "bogus").isUsableJump(among: Set(LayoutInput.Builtin.allCases)))
        XCTAssertTrue(LayoutAction.pageSwitch(.numeric).isUsableJump(among: []))
    }
}
