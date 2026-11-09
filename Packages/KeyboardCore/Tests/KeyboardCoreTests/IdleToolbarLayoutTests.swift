import XCTest

@testable import KeyboardCore

/// The idle toolbar's choice, stored form, width limit and assembly. Mirrors the Android
/// `ToolbarLayoutTest` and `ToolbarActionsTest` cases.
final class IdleToolbarLayoutTests: XCTestCase {
    private typealias Item = IdleToolbarItem

    func testDefaultKeepsTodaysSetAndOrder() {
        XCTAssertEqual(IdleToolbarLayout.default.shown, [.emoji, .settings])
        XCTAssertTrue(IdleToolbarLayout.default.isDefault)
        XCTAssertEqual(IdleToolbarLayout.parse(nil), .default)
        XCTAssertEqual(IdleToolbarLayout.parse("  "), .default)
    }

    func testWireRoundTripKeepsOrderAndOffItems() {
        let layout = IdleToolbarLayout.default
            .moving(fromOffsets: IndexSet(integer: 1), toOffset: 0)
            .withShown(.emoji, false)
        XCTAssertEqual(layout.toWire(), "settings,-emoji")
        XCTAssertEqual(IdleToolbarLayout.parse(layout.toWire()), layout)
        XCTAssertFalse(layout.isDefault)
    }

    func testParseSkipsUnknownAndRepeatedNamesAndRestoresMissingOnes() {
        let layout = IdleToolbarLayout.parse("settings,bogus,-settings,,emoji")
        XCTAssertEqual(layout.toWire(), "settings,emoji")
        XCTAssertEqual(IdleToolbarLayout.parse("nothing,else"), .default)
        XCTAssertEqual(IdleToolbarLayout.parse("-emoji").toWire(), "-emoji,settings")
    }

    func testRemovedItemsInStoredValueDropOut() {
        XCTAssertEqual(IdleToolbarLayout.parse("clipboard,emoji,settings,tools"), .default)
        XCTAssertEqual(IdleToolbarLayout.parse("-clipboard,tools,-emoji").toWire(), "-emoji,settings")
        XCTAssertEqual(IdleToolbarLayout.parse("settings,tools,emoji").toWire(), "settings,emoji")
        XCTAssertEqual(IdleToolbarLayout.parse("-tools,pinned:x"), .default)
        XCTAssertEqual(IdleToolbarLayout.parse("clipboard"), .default)
    }

    func testEverythingCanBeOff() {
        let wire = Item.allCases.map { "-" + $0.rawValue }.joined(separator: ",")
        let layout = IdleToolbarLayout.parse(wire)
        XCTAssertTrue(layout.shown.isEmpty)
        XCTAssertEqual(layout.toWire(), wire)
        XCTAssertTrue(IdleToolbarAssembly.slots(layout: layout, hidden: false).isEmpty)
    }

    func testMovingAmongAllEntriesIncludingOffOnes() {
        let off = IdleToolbarLayout.default.withShown(.emoji, false)
        XCTAssertEqual(off.moving(fromOffsets: IndexSet(integer: 0), toOffset: 2).toWire(), "settings,-emoji")
        XCTAssertEqual(off.moving(fromOffsets: IndexSet(integer: 1), toOffset: 0).toWire(), "settings,-emoji")
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
        let layout = IdleToolbarLayout.default.moving(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        let chosen = IdleToolbarAssembly.slots(layout: layout, hidden: false)
        XCTAssertEqual(chosen, [.settings, .emoji])
        XCTAssertEqual(IdleToolbarAssembly.fitting(chosen, width: 60), [.settings])
        XCTAssertEqual(IdleToolbarAssembly.fitting(chosen, width: 100, fixedSlots: 1), [.settings])
        XCTAssertEqual(IdleToolbarAssembly.fitting(chosen, width: 375), chosen)
    }

    func testAssemblyRespectsUserOrderAndOffItems() {
        let layout = IdleToolbarLayout.parse("settings,-emoji")
        XCTAssertEqual(IdleToolbarAssembly.slots(layout: layout, hidden: false), [.settings])
        XCTAssertTrue(IdleToolbarAssembly.slots(layout: .default, hidden: true).isEmpty)
    }
}
