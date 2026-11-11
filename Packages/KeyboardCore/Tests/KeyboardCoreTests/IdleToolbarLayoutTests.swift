import XCTest

@testable import KeyboardCore

/// The idle toolbar's choice, stored form, width limit and assembly. Mirrors the Android
/// `ToolbarLayoutTest` and `ToolbarActionsTest` cases.
final class IdleToolbarLayoutTests: XCTestCase {
    private typealias Item = IdleToolbarItem

    func testDefaultKeepsTodaysSetAndOrder() {
        XCTAssertEqual(IdleToolbarLayout.default.shown, [.emoji, .oneHand, .settings])
        XCTAssertTrue(IdleToolbarLayout.default.isDefault)
        XCTAssertEqual(IdleToolbarLayout.parse(nil), .default)
        XCTAssertEqual(IdleToolbarLayout.parse("  "), .default)
    }

    func testWireRoundTripKeepsOrderAndOffItems() {
        let layout = IdleToolbarLayout.default
            .moving(fromOffsets: IndexSet(integer: 2), toOffset: 0)
            .withShown(.emoji, false)
        XCTAssertEqual(layout.toWire(), "settings,-emoji,one_hand")
        XCTAssertEqual(IdleToolbarLayout.parse(layout.toWire()), layout)
        XCTAssertFalse(layout.isDefault)
    }

    func testParseSkipsUnknownAndRepeatedNamesAndRestoresMissingOnes() {
        let layout = IdleToolbarLayout.parse("settings,bogus,-settings,,emoji")
        XCTAssertEqual(layout.toWire(), "settings,emoji,one_hand")
        XCTAssertEqual(IdleToolbarLayout.parse("nothing,else"), .default)
        XCTAssertEqual(IdleToolbarLayout.parse("-emoji").toWire(), "-emoji,one_hand,settings")
    }

    /// A value stored before the one-handed button existed gains it on, after the user's entries.
    func testStoredValueFromBeforeTheOneHandedButtonGainsIt() {
        XCTAssertEqual(IdleToolbarLayout.parse("emoji,settings").toWire(), "emoji,settings,one_hand")
        XCTAssertEqual(IdleToolbarLayout.parse("settings,-emoji").toWire(), "settings,-emoji,one_hand")
    }

    func testRemovedItemsInStoredValueDropOut() {
        XCTAssertEqual(IdleToolbarLayout.parse("clipboard,emoji,one_hand,settings,tools"), .default)
        XCTAssertEqual(IdleToolbarLayout.parse("-clipboard,tools,-emoji").toWire(), "-emoji,one_hand,settings")
        XCTAssertEqual(IdleToolbarLayout.parse("settings,tools,emoji").toWire(), "settings,emoji,one_hand")
        XCTAssertEqual(IdleToolbarLayout.parse("-tools,pinned:x"), .default)
        XCTAssertEqual(IdleToolbarLayout.parse("clipboard"), .default)
    }

    func testEverythingCanBeOff() {
        let wire = Item.allCases.map { "-" + $0.rawValue }.joined(separator: ",")
        let layout = IdleToolbarLayout.parse(wire)
        XCTAssertTrue(layout.shown.isEmpty)
        XCTAssertEqual(layout.toWire(), wire)
        XCTAssertTrue(IdleToolbarAssembly.slots(layout: layout, hidden: false, oneHandAvailable: true).isEmpty)
    }

    func testMovingAmongAllEntriesIncludingOffOnes() {
        let off = IdleToolbarLayout.default.withShown(.emoji, false)
        XCTAssertEqual(
            off.moving(fromOffsets: IndexSet(integer: 0), toOffset: 3).toWire(), "one_hand,settings,-emoji")
        XCTAssertEqual(
            off.moving(fromOffsets: IndexSet(integer: 2), toOffset: 0).toWire(), "settings,-emoji,one_hand")
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
        let layout = IdleToolbarLayout.parse("settings,emoji,-one_hand")
        let chosen = IdleToolbarAssembly.slots(layout: layout, hidden: false, oneHandAvailable: true)
        XCTAssertEqual(chosen, [.settings, .emoji])
        XCTAssertEqual(IdleToolbarAssembly.fitting(chosen, width: 60), [.settings])
        XCTAssertEqual(IdleToolbarAssembly.fitting(chosen, width: 100, fixedSlots: 1), [.settings])
        XCTAssertEqual(IdleToolbarAssembly.fitting(chosen, width: 375), chosen)
    }

    func testAssemblyRespectsUserOrderAndOffItems() {
        let layout = IdleToolbarLayout.parse("settings,-emoji,-one_hand")
        XCTAssertEqual(IdleToolbarAssembly.slots(layout: layout, hidden: false, oneHandAvailable: true), [.settings])
        XCTAssertTrue(IdleToolbarAssembly.slots(layout: .default, hidden: true, oneHandAvailable: true).isEmpty)
    }

    /// Where the surface has no one-handed mode (iPad, landscape) the button is left out, and the
    /// entries after it close up.
    func testOneHandedButtonShowsOnlyWhereOneHandedModeExists() {
        XCTAssertEqual(
            IdleToolbarAssembly.slots(layout: .default, hidden: false, oneHandAvailable: true),
            [.emoji, .oneHand, .settings])
        XCTAssertEqual(
            IdleToolbarAssembly.slots(layout: .default, hidden: false, oneHandAvailable: false), [.emoji, .settings])
    }
}
