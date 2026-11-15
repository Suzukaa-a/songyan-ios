import LayoutKit
import XCTest

@testable import CandidateKit

final class KeyboardCandidateBandTests: XCTestCase {
    private func band(
        definition: Bool = false, requires: Bool = true, letters: Bool = false, composing: Bool = false,
        wide: Bool = false
    ) -> Bool {
        KeyboardCandidateBand.required(
            definitionPage: definition, definitionRequires: requires, lettersPage: letters,
            keepsForComposition: composing, wideDismiss: wide)
    }

    func testWideSurfacesKeepTheBandOnEveryPage() {
        XCTAssertFalse(band(), "a phone's idle 123 page drops the band")
        XCTAssertTrue(band(composing: true), "123 keeps the band for a live composition")
        XCTAssertTrue(band(letters: true), "ABC keeps its word suggestions")
        XCTAssertTrue(band(wide: true), "a wide surface keeps the band on 123 for the dismiss entry")
        XCTAssertTrue(band(definition: true), "a layout's letters follow the layout")
        XCTAssertFalse(
            band(definition: true, requires: false, wide: true), "a layout without a candidate area stays without one")
    }
}

final class KeyboardFooterShortcutPlanTests: XCTestCase {
    /// The two bundled traditional boards declare every control key themselves, so the bar adds
    /// none of its own entries: both platforms draw the same footer.
    func testBundledTraditionalBoardsDrawTheirWholeFooter() {
        for board in [BuiltinLayouts.zhuyin41, BuiltinLayouts.cangjie26] {
            let supplement = KeyboardFooterShortcutPlan.supplements(physicalLayoutID: board.id)
            let plan = KeyboardFooterShortcutPlan(controlRow: board.rows.last, supplementShortcuts: supplement)
            XCTAssertFalse(supplement, "\(board.id) draws its whole footer itself")
            XCTAssertFalse(plan.addsNumericShortcut, "\(board.id) keeps its declared 123 key")
            XCTAssertFalse(plan.addsSymbolShortcut, "\(board.id) adds no symbol shortcut")
            XCTAssertFalse(plan.addsLayoutSwitch, "\(board.id) keeps its declared 中/英 key")
            XCTAssertFalse(
                plan.addsGlobe(definitionHasGlobe: true, showsGlobe: true), "\(board.id) keeps its declared globe key")
            XCTAssertTrue(
                plan.addsGlobe(definitionHasGlobe: false, showsGlobe: true),
                "\(board.id) still gets the globe the system needs when the layout has none")
            XCTAssertEqual(board.rows.last?.keys.count, 5, "\(board.id) declares 5 control keys")
        }
        XCTAssertEqual(
            BuiltinLayouts.zhuyin41.rows.last, BuiltinLayouts.cangjie26.rows.last,
            "zhuyin41 and cangjie26 share one control row")
    }

    func testARowWithItsOwn123KeyIsDrawnAsStored() {
        let authored = KeyboardFooterShortcutPlan(
            controlRow: LayoutRow(keys: [
                LayoutKey(label: "123", action: LayoutAction.pageSwitch(.numeric)),
                LayoutKey(label: "中/英", action: LayoutAction.languageSwitch()),
                LayoutKey(label: "空格", width: 4, action: LayoutAction(.space)),
                LayoutKey(label: "⏎", action: LayoutAction(.enter)),
            ]))
        XCTAssertFalse(authored.supplementShortcuts, "a row with its own 123 key is drawn as stored")
        XCTAssertFalse(authored.addsNumericShortcut, "a declared 123 key is not duplicated")
        XCTAssertFalse(authored.addsSymbolShortcut, "no symbol shortcut is added to a row the author completed")
        XCTAssertFalse(authored.addsLayoutSwitch, "a declared languageSwitch key is not duplicated")
        XCTAssertTrue(
            authored.addsGlobe(definitionHasGlobe: false, showsGlobe: true),
            "the globe the system needs is still added when the layout has none")
        XCTAssertFalse(
            authored.addsGlobe(definitionHasGlobe: true, showsGlobe: true), "a declared globe key is not duplicated")
    }

    func testAnOlderRowKeepsItsShortcutsWithoutDuplicates() {
        let legacy = KeyboardFooterShortcutPlan(
            controlRow: LayoutRow(keys: [
                LayoutKey(label: "🌐", action: LayoutAction(.globe)),
                LayoutKey(label: "中/英", action: LayoutAction.languageSwitch()),
                LayoutKey(label: "空格", width: 4, action: LayoutAction(.space)),
                LayoutKey(label: "⏎", action: LayoutAction(.enter)),
            ]))
        XCTAssertTrue(legacy.supplementShortcuts, "a row without 123 keeps the bar's shortcut supplement")
        XCTAssertTrue(
            legacy.addsNumericShortcut && legacy.addsSymbolShortcut, "it still gets 123 and the symbol page")
        XCTAssertFalse(legacy.addsLayoutSwitch, "a declared languageSwitch key is not duplicated")

        let modeOnly = KeyboardFooterShortcutPlan(
            controlRow: LayoutRow(keys: [
                LayoutKey(label: "布局", action: LayoutAction(.modeSwitch, value: "nextLayout"))
            ]))
        XCTAssertFalse(modeOnly.addsLayoutSwitch, "a declared modeSwitch key is still recognized")
    }

    func testTheDefaultAndUnknownLayoutsKeepTodaysShortcuts() {
        let qwerty = KeyboardFooterShortcutPlan(controlRow: BuiltinLayouts.qwerty26.rows.last)
        XCTAssertTrue(
            qwerty.addsNumericShortcut && qwerty.addsSymbolShortcut,
            "the 26-key default still gets the undeclared 123 and symbol shortcuts")
        XCTAssertFalse(qwerty.addsLayoutSwitch, "the 26-key default's declared layout key is not duplicated")
        XCTAssertFalse(
            qwerty.addsGlobe(definitionHasGlobe: true, showsGlobe: true),
            "the 26-key default's declared globe is not duplicated")

        XCTAssertTrue(KeyboardFooterShortcutPlan.supplements(physicalLayoutID: nil), "a schema-only row keeps it")
        XCTAssertTrue(
            KeyboardFooterShortcutPlan.supplements(physicalLayoutID: "qwerty26"), "the bundled 26-key default keeps it")
        XCTAssertTrue(
            KeyboardFooterShortcutPlan.supplements(physicalLayoutID: "mine"), "an unknown user layout keeps it")

        let bare = KeyboardFooterShortcutPlan(controlRow: nil)
        XCTAssertTrue(
            bare.addsNumericShortcut && bare.addsSymbolShortcut && bare.addsLayoutSwitch,
            "a row-less bar still gets 123, symbol and layout shortcuts")
        XCTAssertTrue(
            bare.addsGlobe(definitionHasGlobe: false, showsGlobe: true)
                && !bare.addsGlobe(definitionHasGlobe: true, showsGlobe: true)
                && !bare.addsGlobe(definitionHasGlobe: false, showsGlobe: false),
            "the row-less globe follows definitionHasGlobe and showsGlobe")
    }
}
