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
        var page = KeyboardPagePresets.symbolRowsPage(ascii: false).copy(name: "我的符号")
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
        XCTAssertFalse(
            LayoutAction(.layoutPageSwitch, value: "bogus").isUsableJump(among: Set(LayoutInput.Builtin.allCases)))
        XCTAssertTrue(LayoutAction.pageSwitch(.numeric).isUsableJump(among: []))
    }

    // MARK: - Editing

    func testNewJumpKeyIsNamedAfterItsPageUntilRenamed() {
        let literal = LayoutKey(label: "·", action: .init(.literal, value: "·"))
        let first = LayoutAction.PageJump.all[0]
        let jump = literal.editingAction(.layoutPageSwitch(first), allowsTitleMode: true)
        XCTAssertEqual(jump.label, "123")
        XCTAssertEqual(jump.titleMode, .automatic)
        XCTAssertEqual(jump.action.layoutPageJump, first)

        // The title follows the page while the author has not written one.
        let toSymbols = jump.editingAction(
            .layoutPageSwitch(.init(layout: .phone9, page: .symbols)!), allowsTitleMode: true)
        XCTAssertEqual(toSymbols.label, "符号")
        XCTAssertEqual(toSymbols.action.layoutPageJump?.layout, .phone9)

        // A title the author wrote stays.
        let renamed = toSymbols.editingLabel("我的符号", allowsTitleMode: true)
        XCTAssertEqual(renamed.titleMode, .custom)
        let kept = renamed.editingAction(.layoutPageSwitch(first), allowsTitleMode: true)
        XCTAssertEqual(kept.label, "我的符号")
        XCTAssertEqual(kept.titleMode, .custom)
        XCTAssertEqual(kept.action.layoutPageJump, first)
    }

    func testEditorOffersAJumpOnlyWhereAPageKeyMayHaveOne() {
        func kinds(jump: Bool, stored: LayoutAction.Kind = .literal) -> [LayoutAction.Kind] {
            LayoutAction.Kind.editorChoices(
                allowsCode: false, allowsFunctionActions: true, allowsJump: jump, stored: stored)
        }
        XCTAssertTrue(kinds(jump: true).contains(.layoutPageSwitch))
        XCTAssertFalse(kinds(jump: false).contains(.layoutPageSwitch))
        // A stored jump stays visible as the current choice where it is not offered.
        XCTAssertTrue(kinds(jump: false, stored: .layoutPageSwitch).contains(.layoutPageSwitch))
        XCTAssertFalse(
            LayoutAction.Kind.editorChoices(
                allowsCode: false, allowsFunctionActions: false, allowsJump: true, stored: .literal
            ).contains(.layoutPageSwitch))

        XCTAssertTrue(KeyboardPageKeyPath.row(0, key: 0).allowsJumpKey)
        XCTAssertTrue(KeyboardPageKeyPath.chrome(.leading, key: 0).allowsJumpKey)
        XCTAssertTrue(KeyboardPageKeyPath.chrome(.trailing, key: 0).allowsJumpKey)
        XCTAssertFalse(KeyboardPageKeyPath.chrome(.bottom, key: 0).allowsJumpKey)
    }

    // MARK: - Dispatch decision

    func testPlanSwitchesThenOpensOrOnlyOpensOrDoesNothing() {
        let toNine = LayoutAction.layoutPageSwitch(.init(layout: .phone9, page: .symbols)!)
        let all = Set(LayoutInput.Builtin.allCases)
        XCTAssertEqual(
            LayoutPageJumpPlan.plan(for: toNine, running: .qwerty26, reachable: all),
            .switchLayout(.phone9, thenOpen: .symbols))
        // The running layout needs no switch, even when the set does not list it.
        XCTAssertEqual(
            LayoutPageJumpPlan.plan(for: toNine, running: .phone9, reachable: []), .openPage(.symbols))
        // A layout the running input method cannot use: nothing happens.
        XCTAssertEqual(
            LayoutPageJumpPlan.plan(for: toNine, running: .qwerty26, reachable: [.qwerty26]), .ignore)
        // Not a jump, or a jump with a value this version does not know.
        XCTAssertEqual(
            LayoutPageJumpPlan.plan(for: .pageSwitch(.numeric), running: .qwerty26, reachable: all), .ignore)
        XCTAssertEqual(
            LayoutPageJumpPlan.plan(
                for: LayoutAction(.layoutPageSwitch, value: "phone9:letters"), running: .qwerty26, reachable: all),
            .ignore)
    }

    // MARK: A jump is a visit

    private typealias Place = LayoutPageJumpVisit.Place
    private let own = Place(layout: .qwerty26, schemaID: "own")
    private let nine = Place(layout: .phone9, schemaID: "nine")
    private let other = Place(layout: .merged14, schemaID: "other")

    func testReturnGoesBackToTheLayoutTheUserJumpedFrom() {
        let visit = LayoutPageJumpVisit.after(jumpingFrom: own, landedOn: nine, continuing: nil)
        XCTAssertEqual(visit.restoreTarget(running: nine), own)
    }

    func testAJumpFromTheVisitedLayoutKeepsTheUsersOwnLayout() {
        let first = LayoutPageJumpVisit.after(jumpingFrom: own, landedOn: nine, continuing: nil)
        let second = LayoutPageJumpVisit.after(jumpingFrom: nine, landedOn: other, continuing: first)
        XCTAssertEqual(second.restoreTarget(running: other), own)
    }

    func testAStaleVisitDoesNotOverrideALayoutChosenSince() {
        let stale = LayoutPageJumpVisit.after(jumpingFrom: own, landedOn: nine, continuing: nil)
        let fresh = LayoutPageJumpVisit.after(jumpingFrom: other, landedOn: nine, continuing: stale)
        XCTAssertEqual(fresh.restoreTarget(running: nine), other)
        XCTAssertNil(stale.restoreTarget(running: other))
    }

    func testNothingToRestoreWhenAlreadyOnTheOwnLayout() {
        let visit = LayoutPageJumpVisit.after(jumpingFrom: own, landedOn: own, continuing: nil)
        XCTAssertNil(visit.restoreTarget(running: own))
    }
}
