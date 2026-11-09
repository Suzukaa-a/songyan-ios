import XCTest

@testable import KeyboardCore

/// The idle toolbar's choice, stored form, width limit and assembly. Mirrors the Android
/// `ToolbarLayoutTest` and `ToolbarActionsTest` cases.
final class IdleToolbarLayoutTests: XCTestCase {
    private typealias Item = IdleToolbarItem

    func testDefaultKeepsTodaysSetAndOrder() {
        XCTAssertEqual(IdleToolbarLayout.default.shown, [.emoji, .settings, .tools])
        XCTAssertTrue(IdleToolbarLayout.default.isDefault)
        XCTAssertEqual(IdleToolbarLayout.parse(nil), .default)
        XCTAssertEqual(IdleToolbarLayout.parse("  "), .default)
    }

    func testWireRoundTripKeepsOrderAndOffItems() {
        let layout = IdleToolbarLayout.default
            .moving(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            .withShown(.emoji, false)
        XCTAssertEqual(layout.toWire(), "tools,-emoji,settings")
        XCTAssertEqual(IdleToolbarLayout.parse(layout.toWire()), layout)
        XCTAssertFalse(layout.isDefault)
    }

    func testParseSkipsUnknownAndRepeatedNamesAndRestoresMissingOnes() {
        let layout = IdleToolbarLayout.parse("settings,bogus,-settings,,emoji")
        XCTAssertEqual(layout.toWire(), "settings,emoji,tools")
        XCTAssertEqual(IdleToolbarLayout.parse("nothing,else"), .default)
        XCTAssertEqual(IdleToolbarLayout.parse("-emoji").toWire(), "-emoji,settings,tools")
    }

    func testRemovedClipboardItemInStoredValueDropsOut() {
        XCTAssertEqual(IdleToolbarLayout.parse("clipboard,emoji,settings,tools"), .default)
        XCTAssertEqual(IdleToolbarLayout.parse("-clipboard,tools,-emoji").toWire(), "tools,-emoji,settings")
        XCTAssertEqual(IdleToolbarLayout.parse("clipboard"), .default)
    }

    func testEverythingCanBeOff() {
        let wire = Item.allCases.map { "-" + $0.rawValue }.joined(separator: ",")
        let layout = IdleToolbarLayout.parse(wire)
        XCTAssertTrue(layout.shown.isEmpty)
        XCTAssertEqual(layout.toWire(), wire)
        XCTAssertTrue(
            IdleToolbarAssembly.slots(layout: layout, hidden: false, toolsAvailable: true, pinnedWidths: [44]).isEmpty)
    }

    func testMovingAmongAllEntriesIncludingOffOnes() {
        let off = IdleToolbarLayout.default.withShown(.emoji, false)
        XCTAssertEqual(
            off.moving(fromOffsets: IndexSet(integer: 1), toOffset: 3).toWire(), "-emoji,tools,settings")
        XCTAssertEqual(
            off.moving(fromOffsets: IndexSet(integer: 2), toOffset: 0).toWire(), "tools,-emoji,settings")
        XCTAssertEqual(off.moving(fromOffsets: IndexSet(integer: 0), toOffset: 1), off)
    }

    func testLimitFollowsWidth() {
        XCTAssertEqual(IdleToolbarCapacity.limit(width: 375), 8)
        XCTAssertEqual(IdleToolbarCapacity.limit(width: 430), 9)
        XCTAssertEqual(IdleToolbarCapacity.limit(width: 375, fixedSlots: 1), 7)
        XCTAssertEqual(IdleToolbarCapacity.limit(width: 100), 2)
        XCTAssertEqual(IdleToolbarCapacity.limit(width: 30, fixedSlots: 1), 0)
    }

    func testOverflowDropsFromTheEndAndFixedSlotsStay() {
        let slots = [IdleToolbarCapacity.Slot](repeating: .init(minWidth: 44, droppable: true), count: 4)
        XCTAssertEqual(IdleToolbarCapacity.keep(width: 400, slots: slots), [true, true, true, true])
        XCTAssertEqual(IdleToolbarCapacity.keep(width: 100, slots: slots), [true, true, false, false])
        let withFixed = slots + [.init(minWidth: 44, droppable: false)]
        XCTAssertEqual(IdleToolbarCapacity.keep(width: 100, slots: withFixed), [true, false, false, false, true])
        XCTAssertEqual(IdleToolbarCapacity.keep(width: 10, slots: withFixed), [false, false, false, false, true])
    }

    func testFittingKeepsFrontOfUsersOrder() {
        let layout = IdleToolbarLayout.default.moving(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let chosen = IdleToolbarAssembly.slots(layout: layout, hidden: false, toolsAvailable: true)
        XCTAssertEqual(chosen, [.tools, .emoji, .settings])
        XCTAssertEqual(IdleToolbarAssembly.fitting(chosen, width: 100), [.tools, .emoji])
        XCTAssertEqual(IdleToolbarAssembly.fitting(chosen, width: 100, fixedSlots: 1), [.tools])
        XCTAssertEqual(IdleToolbarAssembly.fitting(chosen, width: 375), chosen)
    }

    func testAssemblyRespectsUserOrderAndFiltersUnavailableItems() {
        let layout = IdleToolbarLayout.parse("settings,-emoji,tools")
        XCTAssertEqual(
            IdleToolbarAssembly.slots(layout: layout, hidden: false, toolsAvailable: true, pinnedWidths: [50, 60]),
            [.settings, .pinned(0), .pinned(1), .tools])
        XCTAssertEqual(
            IdleToolbarAssembly.slots(layout: layout, hidden: false, toolsAvailable: false, pinnedWidths: [50]),
            [.settings])
    }

    func testProtectedFieldGivesNoTools() {
        XCTAssertEqual(
            IdleToolbarAssembly.slots(layout: .default, hidden: false, toolsAvailable: false, pinnedWidths: [44]),
            [.emoji, .settings])
        XCTAssertTrue(IdleToolbarAssembly.slots(layout: .default, hidden: true, toolsAvailable: true).isEmpty)
    }

    func testLongPinnedToolNeedsMoreRoom() {
        let slots: [IdleToolbarSlot] = [.pinned(0), .tools]
        XCTAssertEqual(IdleToolbarAssembly.fitting(slots, pinnedWidths: [96], width: 130), [.pinned(0)])
        XCTAssertEqual(IdleToolbarAssembly.fitting(slots, pinnedWidths: [10], width: 130), slots)
    }
}
